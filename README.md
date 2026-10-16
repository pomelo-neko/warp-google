# WARP for Google · 可指定出口地区 / 强制 IPv4

基于 [VPS值得买](https://vpszdm.com/warp) 的 `warp-google.sh` v1.0.0 二次开发。

原版做的事：把 Google 流量透明地塞进 Cloudflare WARP（`redsocks` + `iptables REDIRECT`），并把 Google 的 IPv6 段加黑洞路由。
本版在此基础上加了四件事：**能指定出口地区**、**能强制走 IPv4**、**能自动守护**、**能刷新 Google 网段**。

---

## 一、先回答两个核心问题

### Q1：换个 IP 之后 WARP 只给堪萨斯和洛杉矶，是跟我的 IP 有关吗？

**有关，而且这是主因。**

WARP 的出口 IP **不是**由你填的接入点（Endpoint）决定的，而是由 **Cloudflare 把你这台机器归到哪个边缘机房（colo）** 决定的：

- Cloudflare 全网是 Anycast。你从 VPS 发出的 WireGuard UDP 包，会被 BGP + Cloudflare 自己的 GeoIP 库牵引到「离你这个源 IP 最近/最匹配」的那个 colo。
- 隧道在那个 colo 终结，你的出口 IP 就是那个 colo / 那个地区的 Cloudflare IP。
- `162.159.192.x`、`162.159.193.x`、`188.114.9x.x` 这些接入点本身**也是 Anycast 的**，同一个 /24 里的地址从你的网络出去基本都落到同一个 colo。所以「换个接入点 IP」对地区的影响，远小于「换个源 IP」。

对照你的情况：

| | 老 IP `114.x` | 新 IP `142.x` |
|---|---|---|
| Cloudflare 眼里的归属 | 亚太 | 北美（`142.0.0.0/8` 是 ARIN 注册段） |
| 就近分配结果 | HK / NRT / SIN / LAX 等一堆地区随机 | 固定落在美国机房 |
| 你看到的 | 「能随机到很多地区」 | 「只有堪萨斯和洛杉矶」 |

「堪萨斯」这个城市很典型：美国 anycast 段在各种 GeoIP 库里最常见的默认落脚点就是 Kansas City（美国地理中心），它通常只是定位库的默认值，不代表真有 Cloudflare 机房在堪萨斯。

### Q2：只有「很容易送中的 IPv6 地址」被路由了，能改成用 IPv4 吗？

**能，而且这版默认就是 IPv4。** 原版在这件事上漏了两个口子，这版都堵上了：

1. **原版只 REDIRECT 了 TCP。** 现代浏览器访问 Google 走 QUIC（UDP/443），这些 UDP 包**不会**进 redsocks，而是直连出去 —— 用的是你 VPS 的真实 IP，Google 看到的就是你 142.x 的真实归属地，这正是「送中」最隐蔽的原因。
2. **诊断命令没强制 IPv4。** 原版 `warp ip` 用的是 `curl -x socks5://... ip.sb`，curl 会优先解析 AAAA，所以你看到的是 WARP 的 **IPv6** 出口 —— 而 WARP 的 IPv6 出口段在不少 GeoIP 库里定位很飘，Google 侧容易判成 CN/HK。

这版的做法：

- 接入点写死 **IPv4 字面量**（不再依赖 `engage.cloudflareclient.com` 的 DNS，避免解析到 AAAA / 被 fake-ip 或污染 DNS 劫持）
- Google IPv6 段全部 **黑洞路由**（内核直接返回 ENETUNREACH，应用瞬间回落 IPv4），再配 `/etc/gai.conf` 的 IPv4 优先级
- **阻断发往 Google 的 QUIC（UDP/443）**，用 `REJECT --reject-with icmp-port-unreachable`，浏览器立刻回落 TCP，全部进 WARP
- 所有出口探测都用 `curl -4`，并且 `warp status` 会**同时**打印 IPv4 和 IPv6 两个出口，你一眼就能看出是哪一族在拖后腿

---

## 二、怎么「指定地区」

### 方法 A：扫描接入点（`warp scan`）

逐个试所有 Cloudflare WARP 接入点，把每个接入点实际落地的国家 / colo / 握手耗时 / 出口 IP 列出来：

```bash
warp scan            # 8 个常用接入点，约 1~2 分钟
warp scan --deep     # 17 个接入点 × 4 个端口，约 5~8 分钟
warp region list     # 看上次扫到了哪些地区
warp region set JP   # 锁定到日本（该地区里握手最快的那个接入点）
```

**要诚实说明：** 因为出口是 Anycast 就近决定的，如果你的 IP 只被牵引到美国，那扫完大概率所有接入点都是 US。这时候 `warp scan` 的价值是**告诉你事实**（而不是让你继续盲目换），并且把可用的接入点按延迟排好，让守护进程能在漂移时自动换回。

### 方法 B：NAT64 强制换落地（`warp nat64`）

这是在你**保持现有 IP** 的前提下，唯一能真正强行换国家的办法。原理：

把接入点写成 **NAT64 前缀里的 IPv6 地址**，例如美国：

```
[2602:fc59:b0:64::a29f:c702]:2408
 └─ NAT64 前缀 ──┘ └ 162.159.199.2 的十六进制
```

你的 UDP 包会先经 IPv6 跑到**位于那个国家的 NAT64 网关**，再由网关转成 IPv4 去连 Cloudflare。Cloudflare 看到请求来自那个国家，就会分配那个国家的出口。

```bash
warp nat64 list      # 列出内置前缀
warp nat64 set us    # 落到美国
warp nat64 set nl    # 落到荷兰
warp nat64 off       # 取消，恢复自动任播
```

内置前缀（均为**第三方免费公共服务**，非 Cloudflare 官方）：

| 代号 | 地区 | 前缀 |
|---|---|---|
| `nl` | 荷兰 | `2a02:898:146:64::` |
| `us` | 美国-A | `2602:fc59:b0:64::` |
| `us2` | 美国-B | `2602:fc59:11:64::` |
| `ams` | 荷兰·阿姆斯特丹 | `2a00:1098:2b::` |
| `uk` | 英国·伦敦 | `2a00:1098:2c:1::` |
| `de` | 德国·纽伦堡 | `2a01:4f8:c2c:123f:64::` |
| `fi` | 芬兰·赫尔辛基 | `2a01:4f9:c010:3f02:64::` |

**前置条件与代价：**

- 你的 VPS 必须**有可用的 IPv6**（脚本会检测并提示）。没有 IPv6 的话这条路走不通。
- 流量绕道第三方网关，**延迟会明显变高**。
- 这些是免费公共服务，**稳定性和服务条款请自行确认**，脚本不对其可用性负责。想加自己的前缀，直接改 `/etc/warp-google/config` 里的 `ENDPOINT`（或 `warp endpoint set '<前缀><ipv4hex>:2408'`）。

### 方法 C：换 IP / 加落地机（最彻底）

如果你就是要亚太地区，最稳的仍然是**让源 IP 落在亚太**：找服务商换 IP 段、换一台机器，或者在目标地区放一台便宜小鸡做中继。原因是 Anycast 牵引看的是源 IP，这一条是改不掉的。

---

## 三、守护进程：不用再「隔几天换一次」

你原来的痛点是「隔几天就要换一次」。WARP 的连接会掉、地区会漂、iptables 规则可能被面板或别的软件清空 —— 这版加了一个 systemd timer 守护：

- 掉线 → 自动重连
- `redsocks` 挂了 → 自动重启
- iptables / QUIC 规则被清空 → 自动重建
- IPv6 黑洞路由丢了 → 自动补回
- 设了 `PREFER_REGION` 且出口地区漂移 → 自动从扫描结果里挑该地区延迟最低的接入点换回去

```bash
systemctl status warp-google-watchdog.timer   # 默认每 10 分钟跑一次
tail -f /var/log/warp-google.log              # 看它干了什么
```

---

## 四、安装与使用

### 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pomelo-neko/warp-google/main/warp-google.sh)
```

不带参数打开交互菜单；也可以直接 `install`：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pomelo-neko/warp-google/main/warp-google.sh) install
```

支持 Debian 10+ / Ubuntu 18+ / CentOS 7+ / Rocky / AlmaLinux / Fedora，需 root。

### 管理命令 `warp`

```
warp status                       状态 + 当前出口 IPv4/IPv6 + 归属地
warp test                         直连 / 经 WARP / AI Studio 连通性
warp ip                           只看出口 IP 与地区
warp restart                      重启透明代理与规则

warp scan [--deep]                扫描接入点，列出各自落地的地区
warp region list                  上次扫到了哪些地区
warp region set JP                锁定出口地区（换成你要的国家码）
warp region off                   取消地区锁定
warp endpoint set 162.159.192.1:2408
warp endpoint reset
warp nat64 list / set us / off

warp ipv4 on|off                  强制 IPv4 开关
warp refresh-google               从官方 goog.json 刷新 Google 网段
warp start | stop                 启停
warp uninstall                    完整卸载
```

### 配置文件 `/etc/warp-google/config`

```bash
ENDPOINT=""                # 自定义接入点 IP:PORT，留空=自动任播
IPV4_ONLY=1                # 强制 IPv4
BLACKHOLE_GOOGLE_V6=1      # Google IPv6 黑洞
BLOCK_GOOGLE_QUIC=1        # 阻断 QUIC 绕过
PREFER_REGION=""           # 期望出口国家码，如 JP
AUTO_REPIN=1               # 漂移时自动换回
SCAN_PORTS="2408"          # 扫描端口
SCAN_EXTRA=""              # 追加扫描的接入点
```

改完执行 `warp restart`。

### 目录结构

```
/usr/local/bin/warp-google          运行时引擎（start/stop/scan/region/...）
/usr/local/bin/warp                 管理命令
/usr/local/bin/warp-google.sh       本安装器副本（warp uninstall 用）
/etc/warp-google/config             配置
/etc/warp-google/google4.txt        Google IPv4 段（39 条，可 refresh-google 更新）
/etc/warp-google/google6.txt        Google IPv6 段（15 条）
/etc/warp-google/scan.tsv           扫描结果
/etc/redsocks.conf                  redsocks 配置
/var/log/warp-google.log            运行日志
```

---

## 五、相对原版修掉的问题

1. **`grep -qiE 'connected'` 会把 `Disconnected` 也判成已连接** —— 原版的连接状态检测实际上永远是「已连接」。这版按 `disconnected → unable to connect → no network → connecting → connected` 的顺序精确判定。
2. **UDP/QUIC 绕过透明代理** —— 原版只 REDIRECT TCP，浏览器 QUIC 走 UDP 直连出站。已增加 REJECT 规则强制回落 TCP。
3. **诊断只看 IPv6 出口** —— 已改为 `-4` / `-6` 分开探测并同时展示。
4. **IPv6 黑洞段不全** —— 原版 10 条，已按官方 `goog.json` 补齐到 15 条（新增 `2605:ef80::/32`、`2606:40::/32`、`2606:73c0::/32`、`2607:1c0:241:40::/60`、`2607:1c0:300::/40`）。
5. **Google IPv4 段不全** —— 原版列表漏了 `192.178.0.0/15` 等新段。默认列表已更新，并支持 `warp refresh-google` 一键同步官方全量列表。
6. **IPv6 黑洞路由不持久** —— 原版只在安装时加一次；重启后由 systemd 服务补，服务挂了就没了。现在守护进程会周期性补回。
7. **没有重连与自愈** —— 已加守护定时器。
8. **无法指定接入点 / 地区** —— 已加。

---

## 六、风险与免责

- 本脚本会修改 `iptables` / `ip -6 route` / `/etc/gai.conf` / `/etc/redsocks.conf`，并在系统里装 `cloudflare-warp` 与 `redsocks`。请在你能承受折腾的机器上使用；`warp uninstall` 可完整回滚。
- NAT64 方案依赖第三方公共服务，存在被限速、被停用、以及流量可见性等风险，**请自行阅读对方服务条款后再决定是否使用**。
- 本脚本不会绕过任何法律或服务条款。请遵守你所在地区的规定以及 Google / Cloudflare 的服务条款。
- 脚本按「现状」提供，不保证任何地区的可用性或稳定性。

## 七、致谢

- 原脚本作者：VPS值得买（[vpszdm.com](https://vpszdm.com/warp)）
- NAT64 前缀来源：[BPB-Worker-Panel](https://github.com/bia-pain-bache/BPB-Worker-Panel/blob/main/docs/NAT64Prefixes.md)、[nat64.net](https://nat64.net/)
- Google 网段来源：<https://www.gstatic.com/ipranges/goog.json>

## License

MIT
