# WARP for Google · 可指定出口地区 / 强制 IPv4

基于 [VPS值得买](https://vpszdm.com/warp) 的 `warp-google.sh` v1.0.0 二次开发。

原版做的事：把 Google 流量透明地塞进 Cloudflare WARP（`redsocks` + `iptables REDIRECT`），并把 Google 的 IPv6 段加黑洞路由。
本版在此基础上加了四件事：**能指定出口地区**、**能强制走 IPv4**、**能自动守护**、**能刷新 Google 网段**。

---

## 零、出问题了先看这里（v2.0.1）

### Google 打不开了 / 怎么改都没用

按顺序执行：

```bash
warp leak       # ① 最关键：Google 到底有没有走 WARP？是哪个环节在漏？
warp doctor     # ② 逐层体检：组件 / 连接 / SOCKS5 / 规则 / 结论
warp recover    # ③ 一键恢复：重置接入点 → 重连 → 刷新规则
```

`warp leak` 会做三件事，直接回答「为什么改什么都没用」：

1. **临时绕过劫持**访问 google.com，看**直连**时 Google 把你判成哪个地区
2. **经 WARP** 访问 google.com，看 WARP 出口被 Google 判成哪个地区（送中会 302 到 `google.cn` / `google.com.hk`）
3. **清空 iptables 计数器 → 发两个 Google 请求 → 看劫持规则有没有被命中**。这一步是决定性的：如果命中 0 个包，说明 **Google 流量根本没走 WARP**，Google 看到的是你 VPS 自己的 IP —— 那你换接入点、换地区当然全是白费力气。

### 如果 `warp leak` 显示「WARP 出口本身被送中」

那就**不是配置问题了**，别再调参数了。

Cloudflare WARP 的出口 IP 是**共享池**，全世界大量用户在共用同一批网段，Google 对这些段的判定会随用量和时间变化。这种情况换接入点、换地区、换协议**全都没用** —— 因为出口段是同一个池子。

**这时候只剩这几条路**（按性价比排序）：

| 方案 | 成本 | 说明 |
|---|---|---|
| **目标地区的小鸡做落地** | 几元/月 | 最稳。买一台日本/新加坡/美国的便宜小鸡，对它做二级转发。IP 独享、可控、随时能换 |
| **住宅 / 原生 IP 代理** | 按流量 | 最干净。很多商家直接标 Google 可用性 |
| **换 VPS 商家（不是只换 IP）** | 换机器 | 同一商家换 IP 通常还在同一个段里 —— 你已经验证过没用了；换商家换段才有意义 |
| **Cloudflare Zero Trust (Teams)** | 免费额度 | 能固定 Gateway 位置，理论上影响出口选择；实际效果取决于网络路径，值得一试 |
| **继续赌 WARP** | 0 | 等 Cloudflare 换段或 Google 改判定。不可控，只能靠 `warp scan` 碰运气 |

> 说句实在话：**WARP 从来不是为「稳定解锁某地区服务」设计的** —— 它的出口是共享的、随机的、容易被滥用标记的。如果你的目标就是稳定用上 AI Studio，花几块钱买台目标地区的小鸡做落地，比在这里继续调参数省心得多。
>
> 这个脚本能保证的是：把 Google 流量**确定性地**送进 WARP（`warp leak` 的 [3] 来验证），并且明确告诉你 Google 究竟看到了什么 —— 让你能快速判断"该换方案了"，而不是盲猜。

### 扫描显示「所有接入点都不可用」是怎么回事

有两种完全不同的原因，`warp doctor` 能区分：

1. **你的 VPS 到 WARP 接入点的 UDP 真的不通** —— 这时候接入点切换确实全失败。可以看 `warp doctor` 里 [3] SOCKS5 那一段：如果连**默认任播**都出不去，就是网络层的问题，不是接入点的问题。
2. **旧版脚本的 bug**（v2.0.0，已修）—— 见下。

### v2.0.1 修了什么

v2.0.0 的 `warp scan` 是**靠反复改写 warp-cli 的接入点**来探测的，它有两个坑，叠在一起就是你遇到的现象：

| 问题 | 后果 |
|---|---|
| 扫描结束后**不还原原接入点** | warp-cli 停在最后一个（可能不通的）接入点上，而 iptables 劫持规则还在 → redsocks 把 Google 请求转给一个连不上的 SOCKS5 → **Google 直接打不开，其它网站正常** |
| 只等 **10 秒**，且把 `unknown` 当失败 | 稍慢的接入点被误判成「不可用」；而 `warp-cli` 有些版本把状态打到 **stderr**，只收 stdout 会得到空串，于是**明明连着也被判成 unknown → 可用接入点全被标成失败** |

v2.0.1 的修法：

- **扫描前保存接入点，用 `trap` 保证无论正常结束、报错还是 Ctrl-C 都会还原**，并在还原后自动重新装回劫持规则
- 扫描期间**先撤掉劫持规则**：WARP 断了也只是走直连，网页不会卡死
- 连接等待改为 `wait_connected`：`connecting` / `unknown` 继续等，只有明确失败才提前退出，超时默认 **25 秒**（可配 `CONNECT_TIMEOUT`）
- 状态读取改成 **stdout + stderr 都收**，并去掉 ANSI 颜色码
- **换接入点一律「先验证后生效」**：连不上就自动回滚到原值，`endpoint set` / `region set` / `nat64 set` 都走这条路

### 「失败即放行」：最坏情况也不会整个打不开

这是 v2.0.1 最重要的一条设计原则：

> **WARP 不通的时候，脚本绝不劫持 Google 流量。**

因为一旦劫持，redsocks 就会把请求转给一个连不上的 SOCKS5，结果是 Google 彻底打不开；
而不劫持最多是「走直连、地区不理想」，网页至少能打开。

`warp start` 和守护进程每次都会先确认「WARP 已连接 **且** SOCKS5 真的能出网（实际拉一次 cdn-cgi/trace）」，确认不了就撤掉规则并保持直连。

配置项 `REQUIRE_WARP=1`（默认开启）控制这个行为。**不建议关掉。**

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
warp scan            # 8 个常用接入点
warp scan --deep     # 17 个接入点 × 4 个端口
warp region list     # 看上次扫到了哪些地区
warp region set JP   # 锁定到日本（该地区里握手最快的那个接入点）
```

> ⚠️ **扫描会短暂影响 Google 访问。** 它需要反复重连接入点，期间脚本会临时撤掉劫持规则（所以网页只是走直连，不会打不开），并在结束时自动还原你原来的接入点。Ctrl-C 中断也会还原。

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

warp leak                         送中 / 泄漏检测：Google 到底走没走 WARP
warp doctor                       逐层体检，定位到底卡在哪一层
warp recover                      一键恢复（重置接入点 + 重连 + 刷新规则）
```

### 配置文件 `/etc/warp-google/config`

```bash
ENDPOINT=""                # 自定义接入点 IP:PORT，留空=自动任播
IPV4_ONLY=1                # 强制 IPv4
BLACKHOLE_GOOGLE_V6=1      # Google IPv6 黑洞
BLOCK_GOOGLE_QUIC=1        # 阻断 QUIC 绕过
PREFER_REGION=""           # 期望出口国家码，如 JP
AUTO_REPIN=1               # 漂移时自动换回
REQUIRE_WARP=1             # WARP 不通时不劫持，保证网页至少能直连打开（强烈建议保持 1）
CONNECT_TIMEOUT=25         # 等待 WARP 连上的超时秒数
HIJACK_ALL=0               # 1=接管所有 80/443 出站，不再依赖 Google IP 列表
GOOGLE_DOMAINS="google.com aistudio.google.com ..."   # 域名解析兜底用的域名
SCAN_PORTS="2408"          # 扫描端口
SCAN_EXTRA=""              # 追加扫描的接入点
```

**关于 `HIJACK_ALL`**：默认的按网段劫持已经覆盖了官方 `goog.json` 全量 + 域名解析兜底，正常情况下够用。
只有当你用 `warp leak` 确认「Google 流量有漏网」（[3] 命中 0 包）时，才把它设为 1 —— 代价是**所有** 80/443 出站都会改走 WARP，其它服务的出口 IP 也会变。

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

### v2.0.1 追加修复

9. **`warp scan` 结束后不还原接入点** —— 会把 warp-cli 停在最后一个可能不通的接入点上，而劫持规则还在，导致 **Google 完全打不开**。现在用 `trap` 保证无条件还原（含 Ctrl-C）。
10. **扫描等待太短 + 状态判断不可靠** —— 原来只等 10 秒且把 `unknown` 当失败；有些 `warp-cli` 版本把状态输出到 stderr，只收 stdout 会得到空串，于是**可用接入点全被误判为不可用**。现在 stdout+stderr 都收、去掉 ANSI、超时 25 秒、`connecting/unknown` 继续等。
11. **WARP 挂了会连带 Google 一起挂** —— 新增「失败即放行」：WARP 不通或 SOCKS5 出不了网时，**不劫持 Google 流量**，保持直连；守护进程也会在检测到不健康时主动撤掉规则。
12. **换接入点没有回滚** —— 现在 `endpoint set` / `region set` / `nat64 set` 都是「先验证能不能连通、能不能出网，不行就自动回滚到原值」。
13. **缺少自助排障手段** —— 新增 `warp doctor`（逐层体检）和 `warp recover`（一键恢复）。

### v2.1.0 追加

14. **默认 Google 网段不完整** —— v2.0.0 的精简列表漏掉了 `34.0.0.0/9`、`35.x` 等 Google Cloud 段（原版脚本里是有的），如果某个 Google 服务恰好解析到这些段，流量就会**漏到直连 → 送中**。现在**安装时自动拉取官方 `goog.json` 全量列表**（失败才回退到内置精简列表），并额外把 `GOOGLE_DOMAINS` 里域名实际解析出的 IP 也并进劫持列表。
15. **无法验证「Google 到底走没走 WARP」** —— 新增 `warp leak`：直连/经 WARP 双路径送中检测 + **清空 iptables 计数器后发请求看是否命中劫持规则**（决定性证据）。
16. **漏网时没有兜底手段** —— 新增 `HIJACK_ALL=1` 全量接管模式：不看 IP 列表，直接接管所有 80/443 出站，从根本上杜绝 Google 漏网。
17. **`warp doctor` 增加 Google 送中快检**，体检末尾会提示跑 `warp leak` 做完整分析。

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
