#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

#=================================================
#   System  : Debian 10+, Ubuntu 18+, CentOS 7+
#   Desc    : WARP 一键安装 + Google 流量解锁
#   Version : 1.0.0
#   Author  : VPS值得买
#   测评网站    : https://vpszdm.com
#=================================================

# ────────────────────────── 颜色定义 ──────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;36m'
CYAN=$'\033[0;96m'
BOLD=$'\033[1m'
PLAIN=$'\033[0m'

sh_ver="1.0.0"

# ────────────────────────── 通用工具函数 ──────────────────────────
info()    { echo -e "${BLUE}[INFO]${PLAIN}  $*"; }
ok()      { echo -e "${GREEN}[  OK]${PLAIN}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${PLAIN}  $*"; }
error()   { echo -e "${RED}[FAIL]${PLAIN}  $*"; }
die()     { error "$*"; exit 1; }

hr() {
    echo -e "${BLUE}──────────────────────────────────────────────────────${PLAIN}"
}

banner() {
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║                                                      ║"
    echo "  ║     WARP 一键安装 + Google 流量解锁  v${sh_ver}      ║"
    echo "  ║     适用于 Debian 10+ · Ubuntu 18+ · CentOS 7+      ║"
    echo "  ║                                                      ║"
    echo "  ║     作者: VPS值得买   http://t.me/bwh81              ║"
    echo "  ║     项目地址：https://vpszdm.com/warp                 ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${PLAIN}"
}

# ────────────────────────── Root 权限检查 ──────────────────────────
[[ $EUID -ne 0 ]] && die "请使用 root 用户运行此脚本"

# ────────────────────────── curl 自举安装 ──────────────────────────
if ! command -v curl &>/dev/null; then
    warn "未检测到 curl，正在自动安装..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq && apt-get install -y curl -qq
    elif command -v yum &>/dev/null; then
        yum install -y curl -q
    fi
    command -v curl &>/dev/null || die "curl 安装失败，请手动安装后重试"
    ok "curl 安装完成"
fi

# ────────────────────────── 系统信息检测 ──────────────────────────
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    CODENAME=${VERSION_CODENAME:-""}
elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
    VER=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
else
    die "不支持的操作系统"
fi

ARCH=$(uname -m)
DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

# ────────────────────────── 依赖检查与安装 ──────────────────────────
check_dependencies() {
    hr
    info "检查系统依赖..."

    if [[ "$OS" =~ centos|rhel|fedora ]]; then
        PKG_INSTALL="yum install -y -q"
        DEPS="ca-certificates wget curl gnupg"
    elif [[ "$OS" =~ debian|ubuntu ]]; then
        PKG_INSTALL="apt-get install -y -qq"
        DEPS="ca-certificates wget curl gnupg lsb-release"
    else
        warn "未知包管理器，跳过依赖检查"
        return 0
    fi

    # pkg_installed <pkgname>：优先用 dpkg/rpm 查包，找不到再 fallback 到 command -v
    pkg_installed() {
        local p="$1"
        if command -v dpkg &>/dev/null; then
            dpkg -s "$p" &>/dev/null && return 0
        elif command -v rpm &>/dev/null; then
            rpm -q "$p" &>/dev/null && return 0
        fi
        command -v "$p" &>/dev/null
    }

    local need_install=()
    for dep in $DEPS; do
        local installed=0
        if [[ "$dep" == "ca-certificates" ]]; then
            [[ -f /etc/ssl/certs/ca-certificates.crt || -f /etc/pki/tls/certs/ca-bundle.crt ]] && installed=1
        else
            pkg_installed "$dep" && installed=1
        fi
        [[ $installed -eq 0 ]] && need_install+=("$dep")
    done

    if [[ ${#need_install[@]} -gt 0 ]]; then
        warn "缺少依赖: ${need_install[*]}，正在安装..."
        if [[ "$OS" =~ debian|ubuntu ]]; then
            apt-get update -qq
            $PKG_INSTALL "${need_install[@]}"
        else
            $PKG_INSTALL "${need_install[@]}"
        fi
        [[ $? -eq 0 ]] && ok "依赖安装完成" || warn "部分依赖安装失败，可能影响运行"
    else
        ok "所有依赖已就绪"
    fi
}

# ────────────────────────── 网络连通性检查 ──────────────────────────
check_network() {
    hr
    info "检查网络连接..."

    local test_hosts=(
        "https://cloudflare.com"
        "https://pkg.cloudflareclient.com"
        "https://github.com"
        "https://1.1.1.1"
    )

    for host in "${test_hosts[@]}"; do
        if curl -s --connect-timeout 5 --max-time 8 "$host" > /dev/null 2>&1; then
            ok "网络连接正常（${host}）"
            return 0
        fi
    done

    error "网络连接失败，请检查网络配置"
    return 1
}

# ────────────────────────── 显示当前 IP 信息 ──────────────────────────
show_current_ip() {
    hr
    info "获取当前 IP 信息..."
    local ip country city
    ip=$(curl -4 -s --max-time 5 ip.sb 2>/dev/null || echo "未知")
    local ip_json
    ip_json=$(curl -s --max-time 5 "http://ip-api.com/json/${ip}?lang=zh-CN" 2>/dev/null)
    country=$(echo "$ip_json" | grep -oP '"country":"\K[^"]+' 2>/dev/null || echo "未知")
    city=$(echo    "$ip_json" | grep -oP '"city":"\K[^"]+'    2>/dev/null || echo "未知")
    printf "  ${CYAN}%-18s${PLAIN} %s\n" "当前 IP:"  "${ip}"
    printf "  ${CYAN}%-18s${PLAIN} %s\n" "IP 归属地:" "${country} - ${city}"
}

# ────────────────────────── 安装 Cloudflare WARP ──────────────────────────
install_warp() {
    hr
    info "安装 Cloudflare WARP 官方客户端..."

    if command -v warp-cli &>/dev/null; then
        ok "warp-cli 已安装，跳过"
        return 0
    fi

    case $OS in
        ubuntu|debian)
            apt-get update -qq
            apt-get install -y -qq gnupg curl wget lsb-release
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb [arch=${DPKG_ARCH} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${CODENAME} main" \
                > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -qq
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo <<'EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
EOF
            if command -v dnf &>/dev/null; then
                dnf install -y cloudflare-warp
            else
                yum install -y cloudflare-warp
            fi
            ;;
        *)
            die "不支持的操作系统: ${OS}（支持：Ubuntu / Debian / CentOS / RHEL / Rocky / AlmaLinux / Fedora）"
            ;;
    esac

    command -v warp-cli &>/dev/null || die "WARP 安装失败，请检查网络或手动安装"
    ok "warp-cli 安装完成"
}

# ────────────────────────── 配置 WARP ──────────────────────────
configure_warp() {
    hr
    info "注册并配置 WARP..."

    # 预先写入 ToS 接受标记（新版 warp-cli 要求）
    # 等效于交互式 `warp-cli registration new` 时手动输入 y 接受条款
    local tos_dir="/var/lib/cloudflare-warp"
    mkdir -p "$tos_dir"
    if [[ ! -f "${tos_dir}/accepted-tos.json" ]]; then
        echo '{"accepted":true}' > "${tos_dir}/accepted-tos.json"
        ok "Cloudflare ToS 已预先接受"
        # 重启 warp-svc 让它读到新写入的 ToS 文件
        systemctl restart warp-svc 2>/dev/null || true
        sleep 2
    fi

    # 注册设备
    warp-cli --accept-tos registration new 2>/dev/null \
        || warp-cli --accept-tos register 2>/dev/null \
        || true

    # 代理模式（仅 SOCKS5，不接管全局流量）
    warp-cli --accept-tos mode proxy 2>/dev/null \
        || warp-cli mode proxy 2>/dev/null \
        || true

    # 代理端口 40000
    warp-cli --accept-tos proxy port 40000 2>/dev/null \
        || warp-cli proxy port 40000 2>/dev/null \
        || true

    # 连接
    info "正在连接 WARP..."
    warp-cli --accept-tos connect 2>/dev/null \
        || warp-cli connect 2>/dev/null \
        || true

    sleep 3

    local status
    status=$(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null || echo "未知")
    ok "WARP 状态: ${status}"
}

# ────────────────────────── 透明代理（Google 流量走 WARP）──────────────────────────
setup_transparent_proxy() {
    hr
    info "配置 Google 流量透明代理..."
    echo ""
    echo -e "${YELLOW}  本操作将：${PLAIN}"
    echo "    • 安装 redsocks 透明代理工具"
    echo "    • 添加 iptables 规则，将 Google IP 段导入 WARP"
    echo "    • 屏蔽 Google IPv6 地址（防止 IPv4/IPv6 归属不一致）"
    echo "    • 注册 systemd 服务，开机自动生效"
    echo ""
    read -rp "  确认继续? [y/N]: " confirm_proxy
    [[ ! "$confirm_proxy" =~ ^[Yy]$ ]] && { warn "已取消"; return; }

    # 安装 redsocks + iptables
    # 先写好配置文件，避免 apt 安装后 systemd 自动启动时找不到配置而报错
    mkdir -p /etc/
    cat > /etc/redsocks.conf <<'REOF'
base {
    log_debug = off;
    log_info  = on;
    log       = "syslog:daemon";
    daemon    = on;
    redirector = iptables;
}
redsocks {
    local_ip   = 127.0.0.1;
    local_port = 12345;
    ip         = 127.0.0.1;
    port       = 40000;
    type       = socks5;
}
REOF

    # 用 policy-rc.d 阻止 apt 安装后自动启动 redsocks（我们后面手动启动）
    echo '#!/bin/sh
exit 101' > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d

    case $OS in
        ubuntu|debian)
            apt-get install -y -qq redsocks iptables
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf &>/dev/null; then
                dnf install -y redsocks iptables 2>/dev/null
            else
                yum install -y redsocks iptables 2>/dev/null
            fi
            ;;
    esac

    # 恢复 policy-rc.d
    rm -f /usr/sbin/policy-rc.d

    # 屏蔽 Google 全部 IPv6 段，强制走 IPv4 再由 iptables 劫持进 WARP
    # 段列表来源：goog.json（Google 用户服务段，含搜索/Gmail/YouTube 等）
    local GOOGLE_V6_LIST=(
        "2001:4860::/32"
        "2404:6800::/32"
        "2404:f340::/32"
        "2600:1900::/28"
        "2607:f8b0::/32"
        "2620:11a:a000::/40"
        "2620:120:e000::/40"
        "2800:3f0::/32"
        "2a00:1450::/32"
        "2c0f:fb50::/32"
    )

    info "添加 Google IPv6 黑洞路由（共 ${#GOOGLE_V6_LIST[@]} 条）..."
    for v6 in "${GOOGLE_V6_LIST[@]}"; do
        ip -6 route add blackhole "$v6" 2>/dev/null || true
    done

    # 让系统 DNS 解析优先返回 IPv4，配合黑洞路由双重保障
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
    fi

    # 持久化 IPv6 黑洞路由：写入 /etc/network/if-up.d/ 或 networkd dispatcher
    # 使用通用的 systemd ExecStartPost 方式，追加到 warp-google.service 里统一管理
    ok "Google IPv6 黑洞路由已添加"

    # 主控脚本（负责 iptables 规则增删）
    cat > /usr/local/bin/warp-google <<'SCRIPT'
#!/usr/bin/env bash
# Google IPv4 段（来源：goog.json ASN 用户服务段）
GOOGLE_IPS="
8.8.4.0/24
8.8.8.0/24
34.0.0.0/9
35.184.0.0/13
35.192.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
72.14.192.0/18
74.125.0.0/16
104.132.0.0/14
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
"

# Google IPv6 段（全部加黑洞路由，强制走 IPv4）
GOOGLE_V6_IPS="
2001:4860::/32
2404:6800::/32
2404:f340::/32
2600:1900::/28
2607:f8b0::/32
2620:11a:a000::/40
2620:120:e000::/40
2800:3f0::/32
2a00:1450::/32
2c0f:fb50::/32
"

add_v6_blackhole() {
    for v6 in $GOOGLE_V6_IPS; do
        ip -6 route add blackhole "$v6" 2>/dev/null || true
    done
}

del_v6_blackhole() {
    for v6 in $GOOGLE_V6_IPS; do
        ip -6 route del blackhole "$v6" 2>/dev/null || true
    done
}

start() {
    # IPv4 透明代理
    pkill redsocks 2>/dev/null
    redsocks -c /etc/redsocks.conf
    iptables -t nat -N WARP_GOOGLE 2>/dev/null || iptables -t nat -F WARP_GOOGLE
    for ip in $GOOGLE_IPS; do
        iptables -t nat -A WARP_GOOGLE -d "$ip" -p tcp -j REDIRECT --to-ports 12345
    done
    iptables -t nat -C OUTPUT -j WARP_GOOGLE 2>/dev/null \
        || iptables -t nat -A OUTPUT -j WARP_GOOGLE

    # IPv6 黑洞：屏蔽 Google IPv6，强制走 IPv4 再进 WARP
    add_v6_blackhole

    echo "WARP Google 透明代理已启动（IPv4 劫持 + IPv6 黑洞）"
}

stop() {
    pkill redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null

    # 移除 IPv6 黑洞路由
    del_v6_blackhole

    echo "WARP Google 透明代理已停止"
}

status() {
    echo "=== WARP 客户端 ==="
    warp-cli status 2>/dev/null || echo "未运行"
    echo ""
    echo "=== Redsocks  ==="
    pgrep -x redsocks >/dev/null && echo "运行中" || echo "未运行"
    echo ""
    echo "=== iptables IPv4 规则（前 5 条）==="
    iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | head -5 || echo "无规则"
    echo ""
    echo "=== IPv6 黑洞路由条数 ==="
    ip -6 route show type blackhole 2>/dev/null | grep -c "/" || echo "0"
}

case "$1" in
    start)   start   ;;
    stop)    stop    ;;
    restart) stop; sleep 1; start ;;
    status)  status  ;;
    *) echo "用法: $0 {start|stop|restart|status}" ;;
esac
SCRIPT
    chmod +x /usr/local/bin/warp-google

    # 立即启动
    /usr/local/bin/warp-google start

    # systemd 服务
    cat > /etc/systemd/system/warp-google.service <<'EOF'
[Unit]
Description=WARP Google Transparent Proxy
After=network.target warp-svc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable warp-google 2>/dev/null

    echo ""
    echo -e "${GREEN}  ┌─────────────────────────────────────────────────┐${PLAIN}"
    echo -e "${GREEN}  │  ✅  透明代理配置完成                           │${PLAIN}"
    echo -e "${GREEN}  │     Google 流量现已自动走 WARP                  │${PLAIN}"
    echo -e "${GREEN}  └─────────────────────────────────────────────────┘${PLAIN}"
    echo ""
}

# ────────────────────────── 快捷管理命令 warp ──────────────────────────
create_management_cmd() {
    cat > /usr/local/bin/warp <<'EOF'
#!/usr/bin/env bash
case "$1" in
    status)
        echo "=== WARP 客户端 ==="
        warp-cli status 2>/dev/null
        echo ""
        /usr/local/bin/warp-google status 2>/dev/null
        ;;
    start)
        mkdir -p /var/lib/cloudflare-warp
        [[ ! -f /var/lib/cloudflare-warp/accepted-tos.json ]] && echo '{"accepted":true}' > /var/lib/cloudflare-warp/accepted-tos.json
        warp-cli --accept-tos connect 2>/dev/null || warp-cli connect 2>/dev/null
        /usr/local/bin/warp-google start
        ;;
    stop)
        /usr/local/bin/warp-google stop
        warp-cli disconnect 2>/dev/null
        ;;
    restart)
        $0 stop; sleep 2; $0 start
        ;;
    test)
        echo "测试 Google 连接..."
        curl -s --max-time 10 -o /dev/null -w "状态码: %{http_code}\n" https://www.google.com
        ;;
    ip)
        echo "直连 IP:"
        curl -4 -s --max-time 5 ip.sb; echo ""
        echo "WARP IP:"
        curl -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb; echo ""
        ;;
    uninstall)
        echo "正在卸载 WARP..."
        /usr/local/bin/warp-google stop 2>/dev/null
        warp-cli disconnect 2>/dev/null
        systemctl disable --now warp-google 2>/dev/null
        rm -f /etc/systemd/system/warp-google.service
        rm -f /usr/local/bin/warp-google
        rm -f /usr/local/bin/warp
        rm -f /etc/redsocks.conf
        for v6 in 2001:4860::/32 2404:6800::/32 2404:f340::/32 2600:1900::/28 \
                  2607:f8b0::/32 2620:11a:a000::/40 2620:120:e000::/40 \
                  2800:3f0::/32 2a00:1450::/32 2c0f:fb50::/32; do
            ip -6 route del blackhole "$v6" 2>/dev/null || true
        done
        iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
        iptables -t nat -F WARP_GOOGLE 2>/dev/null
        iptables -t nat -X WARP_GOOGLE 2>/dev/null
        case $(. /etc/os-release && echo "$ID") in
            ubuntu|debian)
                apt-get remove -y cloudflare-warp redsocks 2>/dev/null
                rm -f /etc/apt/sources.list.d/cloudflare-client.list
                ;;
            centos|rhel|rocky|almalinux|fedora)
                yum remove -y cloudflare-warp redsocks 2>/dev/null \
                    || dnf remove -y cloudflare-warp redsocks 2>/dev/null
                rm -f /etc/yum.repos.d/cloudflare-warp.repo
                ;;
        esac
        echo "WARP 已完全卸载"
        ;;
    *)
        echo ""
        echo "WARP 管理工具  （VPS值得买 · vpszdm.com）"
        echo ""
        echo "用法: warp <命令>"
        echo ""
        echo "  status    查看运行状态"
        echo "  start     启动 WARP"
        echo "  stop      停止 WARP"
        echo "  restart   重启 WARP"
        echo "  test      测试 Google 连通性"
        echo "  ip        查看直连 / WARP IP"
        echo "  uninstall 完整卸载"
        echo ""
        ;;
esac
EOF
    chmod +x /usr/local/bin/warp
    ok "管理命令 warp 已创建（使用: warp {status|start|stop|restart|test|ip|uninstall}）"
}

# ────────────────────────── 测试 Google 连通性 ──────────────────────────
test_google() {
    hr
    info "测试 Google 连通性..."
    sleep 2

    local code
    code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" https://www.google.com 2>/dev/null)
    if [[ "$code" == "200" ]]; then
        ok "Google 连接成功！（HTTP ${code}）"
    else
        warn "Google 测试返回: ${code}（可能需要等待 WARP 完全就绪）"
    fi

    local warp_ip
    warp_ip=$(curl -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb 2>/dev/null)
    if [[ -n "$warp_ip" ]]; then
        local warp_info
        warp_info=$(curl -s --max-time 5 "http://ip-api.com/json/${warp_ip}?lang=zh-CN" 2>/dev/null)
        local country city
        country=$(echo "$warp_info" | grep -oP '"country":"\K[^"]+' || echo "未知")
        city=$(echo    "$warp_info" | grep -oP '"city":"\K[^"]+'    || echo "未知")
        echo ""
        printf "  ${CYAN}%-18s${PLAIN} %s\n" "WARP IP:"    "${warp_ip}"
        printf "  ${CYAN}%-18s${PLAIN} %s\n" "WARP 归属地:" "${country} - ${city}"
    else
        warn "无法通过 WARP SOCKS5 获取 IP，请确认 WARP 已连接"
    fi
}

# ────────────────────────── 系统状态展示 ──────────────────────────
show_status() {
    hr
    local warp_installed warp_running redsocks_running rules_count

    if command -v warp-cli &>/dev/null; then
        warp_installed="${GREEN}✅ 已安装${PLAIN}"
        local st
        st=$(warp-cli status 2>/dev/null || echo "")
        # 兼容新旧版输出格式:
        #   新版: "Status update: Connected."
        #   旧版: "Connection Status: Connected"
        if echo "$st" | grep -qiE 'connected'; then
            warp_running="${GREEN}✅ 已连接${PLAIN}"
        else
            local st_short
            st_short=$(echo "$st" | grep -oiE '(Disconnected|Connecting|No Network|Unable to Connect)[^.]*' | head -1)
            [[ -z "$st_short" ]] && st_short="未连接"
            warp_running="${RED}❌ ${st_short}${PLAIN}"
        fi
    else
        warp_installed="${RED}❌ 未安装${PLAIN}"
        warp_running="${RED}❌ 未运行${PLAIN}"
    fi

    if pgrep -x redsocks >/dev/null; then
        redsocks_running="${GREEN}✅ 运行中${PLAIN}"
    else
        redsocks_running="${RED}❌ 未运行${PLAIN}"
    fi

    rules_count=$(iptables -t nat -L WARP_GOOGLE -n 2>/dev/null | grep -c REDIRECT || echo "0")
    v6_blackhole=$(ip -6 route show type blackhole 2>/dev/null | grep -c "/" || echo "0")

    printf "  ${CYAN}%-18s${PLAIN} %s\n"     "操作系统:"      "$OS $VER"
    printf "  ${CYAN}%-18s${PLAIN} %s\n"     "系统架构:"      "$ARCH"
    printf "  ${CYAN}%-18s${PLAIN}${warp_installed}\n"   "WARP 客户端:"
    printf "  ${CYAN}%-18s${PLAIN}${warp_running}\n"     "WARP 连接:"
    printf "  ${CYAN}%-18s${PLAIN}${redsocks_running}\n" "透明代理:"
    printf "  ${CYAN}%-18s${PLAIN} %s 条\n"  "Google IPv4规则:" "${rules_count}"
    printf "  ${CYAN}%-18s${PLAIN} %s 条\n"  "Google IPv6黑洞:" "${v6_blackhole}"

    if [[ -f /etc/redsocks.conf ]]; then
        printf "  ${CYAN}%-18s${PLAIN} ${GREEN}✅ 已配置${PLAIN}\n" "Redsocks 配置:"
    else
        printf "  ${CYAN}%-18s${PLAIN} ${YELLOW}⬜ 未配置${PLAIN}\n" "Redsocks 配置:"
    fi
    hr
}

# ────────────────────────── 完整安装流程 ──────────────────────────
do_install() {
    check_dependencies
    check_network
    show_current_ip
    install_warp
    configure_warp
    setup_transparent_proxy
    create_management_cmd
    test_google

    echo ""
    echo -e "${GREEN}  ╔══════════════════════════════════════════════════════╗${PLAIN}"
    echo -e "${GREEN}  ║      🎉  安装完成！Google 流量已解锁               ║${PLAIN}"
    echo -e "${GREEN}  ╚══════════════════════════════════════════════════════╝${PLAIN}"
    echo ""
    echo -e "  所有 Google 流量现已自动通过 WARP，无需额外配置。"
    echo ""
    echo -e "  管理命令: ${CYAN}warp {status|start|stop|restart|test|ip|uninstall}${PLAIN}"
    echo ""
}

# ────────────────────────── 卸载 ──────────────────────────
do_uninstall() {
    hr
    info "正在完整卸载 WARP..."

    /usr/local/bin/warp-google stop 2>/dev/null || true
    warp-cli disconnect 2>/dev/null || true
    systemctl disable --now warp-google 2>/dev/null || true
    rm -f /etc/systemd/system/warp-google.service
    rm -f /usr/local/bin/warp-google
    rm -f /usr/local/bin/warp
    rm -f /etc/redsocks.conf
    # 清除所有 Google IPv6 黑洞路由
    for v6 in 2001:4860::/32 2404:6800::/32 2404:f340::/32 2600:1900::/28 \
              2607:f8b0::/32 2620:11a:a000::/40 2620:120:e000::/40 \
              2800:3f0::/32 2a00:1450::/32 2c0f:fb50::/32; do
        ip -6 route del blackhole "$v6" 2>/dev/null || true
    done

    case $OS in
        ubuntu|debian)
            apt-get remove -y cloudflare-warp redsocks 2>/dev/null || true
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum remove -y cloudflare-warp redsocks 2>/dev/null \
                || dnf remove -y cloudflare-warp redsocks 2>/dev/null || true
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    echo ""
    echo -e "${GREEN}  ┌─────────────────────────────────────────────────┐${PLAIN}"
    echo -e "${GREEN}  │  ✅  WARP 已完全卸载                            │${PLAIN}"
    echo -e "${GREEN}  └─────────────────────────────────────────────────┘${PLAIN}"
    echo ""
}

# ────────────────────────── 主菜单 ──────────────────────────
show_menu() {
    clear
    banner
    show_status

    echo -e "  ${BOLD}请选择操作：${PLAIN}"
    echo ""
    echo -e "  ${GREEN}1.${PLAIN}  安装 WARP + 解锁 Google      ${YELLOW}← 推荐先选此项${PLAIN}"
    echo -e "  ${GREEN}2.${PLAIN}  卸载 WARP（完整清理）"
    echo -e "  ${GREEN}3.${PLAIN}  查看运行状态"
    echo -e "  ${GREEN}4.${PLAIN}  测试 Google 连通性"
    echo -e "  ${GREEN}5.${PLAIN}  查看 IP 信息（直连 / WARP）"
    echo ""
    echo -e "  ${GREEN}0.${PLAIN}  退出"
    echo ""
    hr
    read -rp "  请输入选项 [0-5]: " choice
    echo ""

    case $choice in
        1)
            do_install
            ;;
        2)
            read -rp "  确认卸载 WARP 及所有相关组件? [y/N]: " confirm_uninstall
            [[ "$confirm_uninstall" =~ ^[Yy]$ ]] && do_uninstall || warn "已取消"
            ;;
        3)
            show_status
            ;;
        4)
            test_google
            ;;
        5)
            hr
            info "IP 信息"
            echo ""
            echo -e "  ${YELLOW}【直连 IP】${PLAIN}"
            show_current_ip
            echo ""
            echo -e "  ${YELLOW}【WARP IP】${PLAIN}"
            local warp_ip
            warp_ip=$(curl -x socks5://127.0.0.1:40000 -s --max-time 8 ip.sb 2>/dev/null || echo "")
            if [[ -n "$warp_ip" ]]; then
                local wi
                wi=$(curl -s --max-time 5 "http://ip-api.com/json/${warp_ip}?lang=zh-CN" 2>/dev/null)
                printf "  ${CYAN}%-18s${PLAIN} %s\n" "WARP IP:"    "${warp_ip}"
                printf "  ${CYAN}%-18s${PLAIN} %s\n" "WARP 归属地:" \
                    "$(echo "$wi" | grep -oP '"country":"\K[^"]+' || echo '未知') - \
$(echo "$wi" | grep -oP '"city":"\K[^"]+' || echo '未知')"
            else
                warn "无法获取 WARP IP（WARP 可能未运行）"
            fi
            hr
            ;;
        0)
            echo -e "${GREEN}  感谢使用 VPS值得买 WARP 脚本，再见！${PLAIN}"
            echo ""
            exit 0
            ;;
        *)
            error "无效选项，请输入 0-5"
            ;;
    esac

    echo ""
    read -n1 -rp "  按任意键继续..." _
    echo ""
    show_menu
}

# ════════════════════════════════════════════
#   入口：预检查 → 主菜单
# ════════════════════════════════════════════
clear
banner

echo -e "${BLUE}  ◆ 执行环境预检查...${PLAIN}"
echo ""

check_dependencies
check_network

echo ""
ok "预检查完成！"
echo ""
sleep 1

show_menu