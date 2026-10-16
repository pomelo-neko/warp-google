
#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

# ═══════════════════════════════════════════════════════════════════════
#  WARP for Google —— 可指定出口地区 / 强制 IPv4   一键脚本
#  Version  : 2.0.0
#  Based on : VPS值得买 (https://vpszdm.com/warp-google.sh) v1.0.0
#  Repo     : https://github.com/pomelo-neko/warp-google
#
#  相比原版的改动：
#   1. 可指定 WARP 接入点 (Endpoint)，支持扫描并锁定出口地区
#   2. 支持 NAT64 前缀，把落地强行改到别的国家/地区
#   3. 默认强制 IPv4：接入点用 IPv4 字面量 + Google IPv6 黑洞 + 阻断 QUIC
#   4. 新增守护进程：掉线 / 地区漂移 / iptables 被清空时自动恢复
#   5. Google 网段可一键从官方 goog.json 动态刷新
# ═══════════════════════════════════════════════════════════════════════

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;36m'
CYAN=$'\033[0;96m'
BOLD=$'\033[1m'
PLAIN=$'\033[0m'

sh_ver="2.0.0"
REPO_URL="https://github.com/pomelo-neko/warp-google"
ENGINE=/usr/local/bin/warp-google
WRAPPER=/usr/local/bin/warp
INSTALLER=/usr/local/bin/warp-google.sh
CONF_DIR=/etc/warp-google

info()  { printf '%s  %s\n' "${BLUE}[INFO]${PLAIN}" "$*"; }
ok()    { printf '%s  %s\n' "${GREEN}[  OK]${PLAIN}" "$*"; }
warn()  { printf '%s  %s\n' "${YELLOW}[WARN]${PLAIN}" "$*"; }
error() { printf '%s  %s\n' "${RED}[FAIL]${PLAIN}" "$*"; }
die()   { error "$*"; exit 1; }
hr()    { printf '%s──────────────────────────────────────────────────────%s\n' "$BLUE" "$PLAIN"; }

banner() {
    printf '%s\n' "$CYAN"
    printf '%s\n' '  ╔══════════════════════════════════════════════════════╗'
    printf '%s\n' '  ║   WARP for Google  ·  可指定地区 / 强制 IPv4         ║'
    printf '  ║   v%-49s║\n' "$sh_ver"
    printf '%s\n' '  ║   Debian 10+ · Ubuntu 18+ · CentOS 7+                ║'
    printf '%s\n' '  ║   基于 VPS值得买 原版脚本二次开发                    ║'
    printf '  ║   %-50s║\n' "$REPO_URL"
    printf '%s\n' '  ╚══════════════════════════════════════════════════════╝'
    printf '%s\n' "$PLAIN"
}

# ─────────────────────────── 运行环境 ───────────────────────────
[[ $EUID -ne 0 ]] && die "请使用 root 用户运行此脚本"

if ! command -v curl >/dev/null 2>&1; then
    warn "未检测到 curl，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq curl
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q curl
    fi
    command -v curl >/dev/null 2>&1 || die "curl 安装失败，请手动安装后重试"
    ok "curl 安装完成"
fi

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    VER=$VERSION_ID
    CODENAME=${VERSION_CODENAME:-}
elif [[ -f /etc/redhat-release ]]; then
    OS="centos"
    VER=$(grep -oE '[0-9]+' /etc/redhat-release | head -1)
else
    die "不支持的操作系统"
fi

ARCH=$(uname -m)
DPKG_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")

case "$OS" in
    ubuntu|debian)                      PKG_MGR=apt ;;
    centos|rhel|rocky|almalinux|fedora) PKG_MGR=yum ;;
    *) PKG_MGR=unknown ;;
esac

pkg_install() {
    case "$PKG_MGR" in
        apt) apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq "$@" ;;
        yum) if command -v dnf >/dev/null 2>&1; then dnf install -y "$@" ; else yum install -y "$@"; fi ;;
        *)   return 1 ;;
    esac
}

check_dependencies() {
    hr
    info "检查系统依赖..."
    local deps="ca-certificates curl wget gnupg"
    case "$PKG_MGR" in
        apt) deps="$deps lsb-release iproute2" ;;
        yum) deps="$deps iproute" ;;
    esac
    local need=""
    local d
    for d in $deps; do
        command -v "$d" >/dev/null 2>&1 || need="$need $d"
    done
    if [ -n "$need" ]; then
        warn "缺少依赖:$need，正在安装..."
        pkg_install $need >/dev/null 2>&1 && ok "依赖安装完成" || warn "部分依赖安装失败，可能影响运行"
    else
        ok "所有依赖已就绪"
    fi
}

check_network() {
    hr
    info "检查网络连接..."
    local h
    for h in https://1.1.1.1 https://www.cloudflare.com https://github.com; do
        if curl -s --connect-timeout 5 --max-time 8 -o /dev/null "$h" 2>/dev/null; then
            ok "网络连接正常 ($h)"
            return 0
        fi
    done
    error "网络连接失败，请检查网络配置"
    return 1
}

# ═══════════════════════════════════════════════════════════════════════
#  写入运行时引擎 /usr/local/bin/warp-google
# ═══════════════════════════════════════════════════════════════════════
write_engine() {
    mkdir -p "$CONF_DIR"
    cat > "$ENGINE" <<'WARP_ENGINE_EOF'
#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════
#  warp-google 运行时引擎   v2.0.0
#  配置: /etc/warp-google/config      日志: /var/log/warp-google.log
#  用法: warp-google {start|stop|restart|status|probe|ip|scan|region|...}
# ══════════════════════════════════════════════════════════════════════

CONF_DIR=/etc/warp-google
CONF_FILE=$CONF_DIR/config
SCAN_TSV=$CONF_DIR/scan.tsv
STATE_FILE=$CONF_DIR/state
GOOGLE4=$CONF_DIR/google4.txt
GOOGLE6=$CONF_DIR/google6.txt
LOG_FILE=/var/log/warp-google.log
CHAIN_NAT=WARP_GOOGLE
CHAIN_FLT=WARP_GOOGLE_FLT

# ── 默认配置（可被 /etc/warp-google/config 覆盖）─────────────────────
WARP_PROXY_PORT=40000      # warp-cli SOCKS5 端口
REDSOCKS_PORT=12345        # redsocks 本地监听端口
ENDPOINT=""                # 自定义接入点 IP:PORT；留空=Cloudflare 自动任播
IPV4_ONLY=1                # 1=强制 Google 流量走 IPv4（含 IPv6 黑洞 + 阻断 QUIC）
BLACKHOLE_GOOGLE_V6=1      # 1=给 Google IPv6 段加黑洞路由，逼应用回落 IPv4
BLOCK_GOOGLE_QUIC=1        # 1=丢弃发往 Google 的 UDP/443，防止 QUIC 绕过透明代理
PREFER_REGION=""           # 期望出口国家/地区两位码，例如 JP / SG / US / NL
AUTO_REPIN=1               # 1=出口地区漂移时自动换回最优接入点
SCAN_PORTS="2408"          # 扫描用的接入点端口，空格分隔
SCAN_EXTRA=""              # 追加到扫描列表的接入点，"IP:PORT IP:PORT"

mkdir -p "$CONF_DIR"
[ -f "$CONF_FILE" ] && . "$CONF_FILE"

# ── 输出 ─────────────────────────────────────────────────────────────
_cc() { [ -t 1 ] && printf '\033[%sm' "$1" || true; }
info() { printf '%s[INFO]%s  %s\n' "$(_cc '0;36')" "$(_cc 0)" "$*"; }
ok()   { printf '%s[  OK]%s  %s\n' "$(_cc '0;32')" "$(_cc 0)" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$(_cc '0;33')" "$(_cc 0)" "$*"; }
err()  { printf '%s[FAIL]%s  %s\n' "$(_cc '0;31')" "$(_cc 0)" "$*"; }
die()  { err "$*"; exit 1; }

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
}
log_rotate() {
    local sz
    [ -f "$LOG_FILE" ] || return 0
    sz=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 1048576 ]; then
        tail -n 800 "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null && mv "$LOG_FILE.tmp" "$LOG_FILE"
    fi
}

# ── 配置读写 ─────────────────────────────────────────────────────────
cfg_set() {
    local k=$1 v=$2
    [ -f "$CONF_FILE" ] || : > "$CONF_FILE"
    if grep -q "^$k=" "$CONF_FILE" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$CONF_FILE"
    else
        printf '%s=%s\n' "$k" "$v" >> "$CONF_FILE"
    fi
    eval "$k=\$v"
}

# ── warp-cli 兼容封装（新旧版本命令名不同）───────────────────────────
wcli() {
    warp-cli --accept-tos "$@" >/dev/null 2>&1 && return 0
    warp-cli "$@" >/dev/null 2>&1
}
wcliout() {
    local out
    if out=$(warp-cli --accept-tos "$@" 2>/dev/null); then
        printf '%s' "$out"; return 0
    fi
    warp-cli "$@" 2>/dev/null
}
# 注意：必须先判断 disconnected，否则 "Disconnected" 会被 connected 命中
warp_state() {
    local s
    s=$(wcliout status 2>/dev/null | tr 'A-Z' 'a-z')
    case "$s" in
        *disconnected*)        printf 'disconnected' ;;
        *"unable to connect"*) printf 'failed' ;;
        *"no network"*)        printf 'no-network' ;;
        *connecting*)          printf 'connecting' ;;
        *connected*)           printf 'connected' ;;
        *)                     printf 'unknown' ;;
    esac
}

endpoint_set() {
    local ep=$1
    [ -n "$ep" ] || return 1
    wcli tunnel endpoint set "$ep" && return 0
    wcli set-custom-endpoint "$ep" && return 0
    return 1
}
endpoint_reset() {
    wcli tunnel endpoint reset && return 0
    wcli set-custom-endpoint "" && return 0
    return 1
}
endpoint_show() {
    local out
    out=$(wcliout tunnel dump 2>/dev/null)
    if [ -n "$out" ]; then
        printf '%s\n' "$out" | grep -iE 'endpoint|protocol' | head -4
    else
        printf '%s\n' "（当前 warp-cli 不支持查询接入点，请用 /etc/warp-google/config 里的 ENDPOINT）"
    fi
}

# ── 出口探测 ─────────────────────────────────────────────────────────
# probe_trace <4|6>  ->  "IP|国家码|colo"    失败返回 1
probe_trace() {
    local fam=$1 out ip cc colo
    if [ "$fam" = "6" ]; then
        out=$(curl -6 -k -s --max-time 12 -x "socks5://127.0.0.1:$WARP_PROXY_PORT" \
              "https://[2606:4700:4700::1111]/cdn-cgi/trace" 2>/dev/null)
        [ -n "$out" ] || out=$(curl -6 -k -s --max-time 12 -x "socks5h://127.0.0.1:$WARP_PROXY_PORT" \
              "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
    else
        out=$(curl -4 -s --max-time 12 -x "socks5://127.0.0.1:$WARP_PROXY_PORT" \
              "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
        [ -n "$out" ] || out=$(curl -4 -k -s --max-time 12 -x "socks5://127.0.0.1:$WARP_PROXY_PORT" \
              "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null)
        [ -n "$out" ] || out=$(curl -4 -k -s --max-time 12 -x "socks5h://127.0.0.1:$WARP_PROXY_PORT" \
              "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null)
    fi
    [ -n "$out" ] || return 1
    ip=$(printf '%s\n' "$out"   | sed -n 's/^ip=//p'   | head -1)
    cc=$(printf '%s\n' "$out"   | sed -n 's/^loc=//p'  | head -1)
    colo=$(printf '%s\n' "$out" | sed -n 's/^colo=//p' | head -1)
    [ -n "$ip" ] || return 1
    printf '%s|%s|%s\n' "$ip" "$cc" "$colo"
    return 0
}

# geo_of <ip>  ->  "国家|城市|运营商"
geo_of() {
    local ip=$1 j f1 f2 f3
    [ -n "$ip" ] || return 1
    j=$(curl -4 -s --max-time 6 "http://ip-api.com/json/$ip?lang=zh-CN&fields=status,country,city,isp" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"status":"success"'; then
        f1=$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        f2=$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
        f3=$(printf '%s' "$j" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')
        printf '%s|%s|%s\n' "$f1" "$f2" "$f3"
        return 0
    fi
    j=$(curl -4 -s --max-time 6 "https://ipinfo.io/$ip/json" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"country"'; then
        f1=$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')
        f2=$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')
        f3=$(printf '%s' "$j" | sed -n 's/.*"org":"\([^"]*\)".*/\1/p')
        printf '%s|%s|%s\n' "$f1" "$f2" "$f3"
        return 0
    fi
    printf '未知|未知|未知\n'
    return 1
}

# 显示当前 WARP 出口（IPv4 + IPv6 都显示，便于对比哪一族被污染）
show_exit() {
    local tr ip cc colo geo tr6 ip6 cc6
    tr=$(probe_trace 4)
    if [ -n "$tr" ]; then
        ip=$(printf '%s' "$tr" | cut -d'|' -f1)
        cc=$(printf '%s' "$tr" | cut -d'|' -f2)
        colo=$(printf '%s' "$tr" | cut -d'|' -f3)
        geo=$(geo_of "$ip")
        printf '  %-16s %s\n'   "WARP IPv4:" "$ip"
        printf '  %-16s %s / %s  (Cloudflare colo: %s)\n' "出口地区:" \
            "$(printf '%s' "$geo" | cut -d'|' -f1)" "$cc" "$colo"
        printf '  %-16s %s\n'   "机房城市:" "$(printf '%s' "$geo" | cut -d'|' -f2)"
        printf '  %-16s %s\n'   "运营商:"   "$(printf '%s' "$geo" | cut -d'|' -f3)"
    else
        warn "无法通过 WARP 获取 IPv4 出口（WARP 未连接或 SOCKS5 不可用）"
    fi
    tr6=$(probe_trace 6)
    if [ -n "$tr6" ]; then
        ip6=$(printf '%s' "$tr6" | cut -d'|' -f1)
        cc6=$(printf '%s' "$tr6" | cut -d'|' -f2)
        printf '  %-16s %s  (%s)\n' "WARP IPv6:" "$ip6" "$cc6"
    else
        printf '  %-16s %s\n' "WARP IPv6:" "不可用（已屏蔽或客户端未分配 IPv6 出口）"
    fi
}

state_write() {
    printf 'LAST_CHECK=%s\nLAST_IP=%s\nLAST_CC=%s\nLAST_COLO=%s\n' \
        "$(date '+%F %T')" "$1" "$2" "$3" > "$STATE_FILE" 2>/dev/null
}

# ── redsocks ─────────────────────────────────────────────────────────
redsocks_bin() {
    command -v redsocks 2>/dev/null || printf '%s' /usr/sbin/redsocks
}
ensure_redsocks() {
    pgrep -x redsocks >/dev/null 2>&1 && return 0
    local bin
    bin=$(redsocks_bin)
    [ -x "$bin" ] || { err "未找到 redsocks（$bin）"; return 1; }
    [ -f /etc/redsocks.conf ] || { err "缺少 /etc/redsocks.conf"; return 1; }
    "$bin" -c /etc/redsocks.conf
    sleep 1
    pgrep -x redsocks >/dev/null 2>&1
}

# ── iptables：把 Google IPv4 流量劫持进 redsocks ─────────────────────
count_nets() {
    [ -f "$1" ] || { printf '0'; return; }
    grep -vE '^[[:space:]]*(#|$)' "$1" | wc -l | tr -d ' '
}

apply_iptables() {
    [ -f "$GOOGLE4" ] || { err "缺少 Google IPv4 网段文件: $GOOGLE4"; return 1; }
    iptables -t nat -N "$CHAIN_NAT" 2>/dev/null || iptables -t nat -F "$CHAIN_NAT"
    local net
    while read -r net; do
        case "$net" in ''|'#'*) continue ;; esac
        iptables -t nat -A "$CHAIN_NAT" -d "$net" -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"
    done < "$GOOGLE4"
    iptables -t nat -C OUTPUT -j "$CHAIN_NAT" 2>/dev/null || iptables -t nat -A OUTPUT -j "$CHAIN_NAT"
    ok "已下发 $(count_nets "$GOOGLE4") 条 Google IPv4 透明代理规则"
}

clear_iptables() {
    iptables -t nat -D OUTPUT -j "$CHAIN_NAT" 2>/dev/null
    iptables -t nat -F "$CHAIN_NAT" 2>/dev/null
    iptables -t nat -X "$CHAIN_NAT" 2>/dev/null
    return 0
}

# ── Google IPv6 黑洞：逼应用回落到 IPv4，避免走易被判 CN 的 v6 ──────
apply_v6_blackhole() {
    [ -f "$GOOGLE6" ] || return 0
    local net
    while read -r net; do
        case "$net" in ''|'#'*) continue ;; esac
        ip -6 route add blackhole "$net" 2>/dev/null \
            || ip -6 route replace blackhole "$net" 2>/dev/null || true
    done < "$GOOGLE6"
    if ! grep -q 'precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null; then
        printf 'precedence ::ffff:0:0/96  100\n' >> /etc/gai.conf
    fi
}

clear_v6_blackhole() {
    [ -f "$GOOGLE6" ] || return 0
    local net
    while read -r net; do
        case "$net" in ''|'#'*) continue ;; esac
        ip -6 route del blackhole "$net" 2>/dev/null || true
    done < "$GOOGLE6"
    return 0
}

# ── 阻断发往 Google 的 QUIC(UDP/443)，否则 UDP 会绕过 redsocks 直连 ──
apply_quic_block() {
    [ "$BLOCK_GOOGLE_QUIC" = "1" ] || return 0
    [ -f "$GOOGLE4" ] || return 0
    iptables -t filter -N "$CHAIN_FLT" 2>/dev/null || iptables -t filter -F "$CHAIN_FLT"
    local net
    while read -r net; do
        case "$net" in ''|'#'*) continue ;; esac
        iptables -t filter -A "$CHAIN_FLT" -d "$net" -p udp --dport 443 \
            -j REJECT --reject-with icmp-port-unreachable
    done < "$GOOGLE4"
    iptables -t filter -C OUTPUT -j "$CHAIN_FLT" 2>/dev/null || iptables -t filter -A OUTPUT -j "$CHAIN_FLT"
}

clear_quic_block() {
    iptables -t filter -D OUTPUT -j "$CHAIN_FLT" 2>/dev/null
    iptables -t filter -F "$CHAIN_FLT" 2>/dev/null
    iptables -t filter -X "$CHAIN_FLT" 2>/dev/null
    return 0
}

# ── 启停 ─────────────────────────────────────────────────────────────
do_start() {
    mkdir -p "$CONF_DIR"
    command -v warp-cli >/dev/null 2>&1 || { err "warp-cli 未安装"; return 1; }

    if [ -n "$ENDPOINT" ]; then
        info "锁定接入点: $ENDPOINT"
        endpoint_set "$ENDPOINT" || warn "当前 warp-cli 不支持自定义接入点，退回自动任播"
    fi

    local st i
    st=$(warp_state)
    if [ "$st" != "connected" ]; then
        info "连接 WARP ..."
        wcli connect
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 1
            st=$(warp_state)
            [ "$st" = "connected" ] && break
        done
    fi
    if [ "$st" = "connected" ]; then ok "WARP 已连接"; else warn "WARP 状态异常: $st"; fi

    ensure_redsocks || warn "redsocks 启动失败，透明代理可能不生效"
    apply_iptables
    [ "$BLACKHOLE_GOOGLE_V6" = "1" ] && apply_v6_blackhole
    [ "$BLOCK_GOOGLE_QUIC" = "1" ] && apply_quic_block
    log "start endpoint=${ENDPOINT:-auto} ipv4_only=$IPV4_ONLY region=$PREFER_REGION"
    return 0
}

do_stop() {
    pkill -x redsocks 2>/dev/null
    clear_iptables
    clear_quic_block
    [ "$BLACKHOLE_GOOGLE_V6" = "1" ] && clear_v6_blackhole
    log "stop"
    ok "WARP Google 透明代理已停止"
    return 0
}

do_status() {
    printf '%s\n' "=== WARP 客户端 ==="
    printf '  状态      : %s\n' "$(warp_state)"
    if [ -n "$ENDPOINT" ]; then
        printf '  接入点    : %s  (已锁定)\n' "$ENDPOINT"
    else
        printf '  接入点    : Cloudflare 自动任播 (engage.cloudflareclient.com)\n'
    fi
    printf '  期望地区  : %s\n' "${PREFER_REGION:-（未设置）}"
    printf '  强制 IPv4 : %s\n' "$IPV4_ONLY"
    printf '\n%s\n' "=== 出口信息 ==="
    show_exit
    printf '\n%s\n' "=== 透明代理 ==="
    if pgrep -x redsocks >/dev/null 2>&1; then
        printf '  redsocks         : 运行中\n'
    else
        printf '  redsocks         : 未运行\n'
    fi
    printf '  Google v4 规则   : %s 条\n' "$(iptables -t nat -S "$CHAIN_NAT" 2>/dev/null | grep -c REDIRECT)"
    printf '  QUIC 阻断规则    : %s 条\n' "$(iptables -t filter -S "$CHAIN_FLT" 2>/dev/null | grep -c REJECT)"
    printf '  Google v6 黑洞   : %s 条\n' "$(ip -6 route show type blackhole 2>/dev/null | grep -c '/')"
    return 0
}

# ── 接入点管理 ───────────────────────────────────────────────────────
cmd_endpoint() {
    local sub=$1
    shift 2>/dev/null
    case "$sub" in
        show|"")
            printf '当前接入点: %s\n' "${ENDPOINT:-（Cloudflare 自动任播）}"
            endpoint_show
            ;;
        set)
            local ep=$1
            [ -n "$ep" ] || { err "用法: warp-google endpoint set IP:PORT"; return 1; }
            endpoint_set "$ep" || { err "设置接入点失败（warp-cli 可能不支持）"; return 1; }
            cfg_set ENDPOINT "$ep"
            wcli disconnect; sleep 1; wcli connect; sleep 5
            ok "接入点已锁定为 $ep，状态: $(warp_state)"
            ;;
        reset|off)
            endpoint_reset
            cfg_set ENDPOINT ""
            wcli disconnect; sleep 1; wcli connect; sleep 5
            ok "已恢复 Cloudflare 自动任播"
            ;;
        *) err "用法: warp-google endpoint {show|set IP:PORT|reset}" ;;
    esac
}

# ── 扫描：找出「用哪个接入点会落到哪个地区」─────────────────────────
DEFAULT_BASE="162.159.192.1 162.159.193.1 162.159.195.1 162.159.204.1 188.114.96.1 188.114.97.1 188.114.98.1 188.114.99.1"
DEEP_BASE="162.159.192.1 162.159.192.2 162.159.192.3 162.159.193.1 162.159.193.2 162.159.193.3 162.159.195.1 162.159.195.2 162.159.204.1 188.114.96.1 188.114.96.2 188.114.97.1 188.114.97.2 188.114.98.1 188.114.98.2 188.114.99.1 188.114.99.2"

cmd_scan() {
    local bases="$DEFAULT_BASE"
    local ports="$SCAN_PORTS"
    local extra="$SCAN_EXTRA"
    while [ $# -gt 0 ]; do
        case "$1" in
            --deep)  bases="$DEEP_BASE"; ports="2408 500 1701 4500"; shift ;;
            --base)  bases=$2; shift 2 ;;
            --ports) ports=$2; shift 2 ;;
            --extra) extra=$2; shift 2 ;;
            *) shift ;;
        esac
    done

    command -v warp-cli >/dev/null 2>&1 || die "warp-cli 未安装"

    if ! endpoint_set "162.159.192.1:2408"; then
        err "当前 warp-cli 版本不支持自定义接入点（set-custom-endpoint / tunnel endpoint set）"
        err "请升级 warp-cli，或改用 nat64 方式更换落地"
        return 1
    fi

    local b p e list=""
    for b in $bases; do for p in $ports; do list="$list $b:$p"; done; done
    for e in $extra; do list="$list $e"; done

    local total=0
    for e in $list; do total=$((total + 1)); done
    info "共 $total 个候选接入点，开始逐个探测（每个约 5~12 秒，请耐心等待）"
    : > "$SCAN_TSV"

    local ep t0 t1 cost st i tr ip cc colo good=0
    for ep in $list; do
        printf '  → %-24s' "$ep"
        endpoint_set "$ep" >/dev/null 2>&1
        wcli disconnect; sleep 1
        t0=$(date +%s)
        wcli connect
        st=""
        for i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 1
            st=$(warp_state)
            [ "$st" = "connected" ] && break
            [ "$st" = "failed" ] && break
        done
        t1=$(date +%s)
        cost=$((t1 - t0))
        if [ "$st" != "connected" ]; then
            printf ' × 连不上 (%ss)\n' "$cost"
            printf '%s\tFAIL\t-\t%s\t-\n' "$ep" "$cost" >> "$SCAN_TSV"
            continue
        fi
        sleep 2
        tr=$(probe_trace 4)
        if [ -z "$tr" ]; then
            printf ' × 拿不到出口信息\n'
            printf '%s\tNO-TRACE\t-\t%s\t-\n' "$ep" "$cost" >> "$SCAN_TSV"
            continue
        fi
        ip=$(printf '%s' "$tr" | cut -d'|' -f1)
        cc=$(printf '%s' "$tr" | cut -d'|' -f2)
        colo=$(printf '%s' "$tr" | cut -d'|' -f3)
        printf ' √ %-3s %-5s %2ss  %s\n' "$cc" "$colo" "$cost" "$ip"
        printf '%s\t%s\t%s\t%s\t%s\n' "$ep" "$cc" "$colo" "$cost" "$ip" >> "$SCAN_TSV"
        good=$((good + 1))
    done

    printf '\n%s\n' "════════ 扫描完成：$good/$total 个接入点可用 ════════"
    printf '%s\n' "可用出口地区统计:"
    awk -F'\t' '$2!="FAIL" && $2!="NO-TRACE" {print $2}' "$SCAN_TSV" | sort | uniq -c | sort -rn \
        | awk '{printf "  %-4s × %s 个接入点\n", $2, $1}'
    printf '\n%s\n' "接入点明细（地区 / colo / 握手耗时 / 出口IP）:"
    awk -F'\t' '$2!="FAIL" && $2!="NO-TRACE" {printf "  %-24s %-4s %-6s %3ss  %s\n",$1,$2,$3,$4,$5}' "$SCAN_TSV" \
        | sort -k2
    printf '\n提示: warp-google region set <地区码>   锁定你想要的地区（例如 region set JP）\n'
    return 0
}

# ── 地区锁定 ─────────────────────────────────────────────────────────
cmd_region() {
    local sub=$1
    shift 2>/dev/null
    case "$sub" in
        show|"")
            printf '期望地区: %s\n' "${PREFER_REGION:-（未设置）}"
            show_exit
            ;;
        list)
            if [ ! -s "$SCAN_TSV" ]; then
                warn "还没有扫描结果，先运行: warp-google scan"
                return 1
            fi
            awk -F'\t' '$2!="FAIL" && $2!="NO-TRACE" {print $2}' "$SCAN_TSV" | sort -u | tr '\n' ' '
            printf '\n'
            ;;
        set)
            local want=$1
            [ -n "$want" ] || { err "用法: warp-google region set <国家码，如 JP/SG/US/HK/TW>"; return 1; }
            want=$(printf '%s' "$want" | tr 'a-z' 'A-Z')
            if [ ! -s "$SCAN_TSV" ]; then
                err "还没有扫描结果，先运行: warp-google scan"
                return 1
            fi
            local best
            best=$(awk -F'\t' -v w="$want" '$2==w {print $4"\t"$1}' "$SCAN_TSV" | sort -n | head -1 | cut -f2)
            [ -n "$best" ] || { err "扫描结果里没有地区 $want，可先运行 warp-google region list 查看"; return 1; }
            info "锁定接入点 $best（目标地区 $want）"
            endpoint_set "$best" || { err "设置接入点失败"; return 1; }
            cfg_set ENDPOINT "$best"
            cfg_set PREFER_REGION "$want"
            wcli disconnect; sleep 1; wcli connect; sleep 6
            local cur
            cur=$(probe_trace 4 | cut -d'|' -f2)
            if [ "$cur" = "$want" ]; then
                ok "已锁定，当前出口地区: $cur"
            else
                warn "当前出口地区是 ${cur:-未知}，与期望的 $want 不一致"
                warn "Cloudflare 出口由接入网络的 Anycast 就近策略决定，换接入点不一定能改地区；"
                warn "若反复不成功，请试 warp-google nat64 list / nat64 set <代号>"
            fi
            ;;
        off)
            cfg_set PREFER_REGION ""
            ok "已关闭地区锁定（接入点保持不变）"
            ;;
        *) err "用法: warp-google region {show|list|set CC|off}" ;;
    esac
}

# ── NAT64：借第三方 NAT64 网关强行换落地国家 ────────────────────────
nat64_table() {
    cat <<'NAT64_TABLE_EOF'
nl|荷兰|2a02:898:146:64::
us|美国-A|2602:fc59:b0:64::
us2|美国-B|2602:fc59:11:64::
ams|荷兰-阿姆斯特丹|2a00:1098:2b::
uk|英国-伦敦|2a00:1098:2c:1::
de|德国-纽伦堡|2a01:4f8:c2c:123f:64::
fi|芬兰-赫尔辛基|2a01:4f9:c010:3f02:64::
NAT64_TABLE_EOF
}
ipv4_hex() {
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    printf '%02x%02x:%02x%02x' "$a" "$b" "$c" "$d"
}
nat64_endpoint() {
    local prefix=$1 v4=$2 port=$3
    [ -n "$port" ] || port=2408
    printf '[%s%s]:%s' "$prefix" "$(ipv4_hex "$v4")" "$port"
}
cmd_nat64() {
    local sub=$1
    shift 2>/dev/null
    case "$sub" in
        list|"")
            printf '%s\n' "可用 NAT64 落地前缀（第三方免费公共服务，稳定性/条款自负）:"
            nat64_table | while IFS='|' read -r code name prefix; do
                printf '  %-5s %-18s %s\n' "$code" "$name" "$prefix"
            done
            printf '\n用法: warp-google nat64 set <代号> [接入点IPv4]    例: nat64 set us\n'
            printf '注意: 需要本机有可用 IPv6；延迟会变高；请自行确认对方服务条款。\n'
            ;;
        set)
            local code=$1
            local base=$2
            [ -n "$base" ] || base=162.159.192.1
            [ -n "$code" ] || { err "用法: warp-google nat64 set <代号>"; return 1; }
            local row name prefix ep
            row=$(nat64_table | grep "^$code|")
            [ -n "$row" ] || { err "未知代号: $code（先运行 warp-google nat64 list）"; return 1; }
            name=$(printf '%s' "$row" | cut -d'|' -f2)
            prefix=$(printf '%s' "$row" | cut -d'|' -f3)
            ep=$(nat64_endpoint "$prefix" "$base" 2408)
            if ! ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
                warn "本机似乎没有可用 IPv6，NAT64 方案无法工作"
            fi
            info "NAT64 落地 $name → $ep"
            endpoint_set "$ep" || { err "设置接入点失败（warp-cli 可能不支持 IPv6 接入点）"; return 1; }
            cfg_set ENDPOINT "$ep"
            cfg_set PREFER_REGION ""
            wcli disconnect; sleep 1; wcli connect; sleep 6
            printf '  状态: %s\n' "$(warp_state)"
            show_exit
            ;;
        off)
            endpoint_reset
            cfg_set ENDPOINT ""
            wcli disconnect; sleep 1; wcli connect; sleep 5
            ok "已取消自定义接入点，恢复 Cloudflare 自动任播"
            ;;
        *) err "用法: warp-google nat64 {list|set 代号|off}" ;;
    esac
}

# ── 强制 IPv4 开关 ───────────────────────────────────────────────────
cmd_ipv4() {
    local v=$1
    case "$v" in
        on|1)
            cfg_set IPV4_ONLY 1
            cfg_set BLACKHOLE_GOOGLE_V6 1
            cfg_set BLOCK_GOOGLE_QUIC 1
            apply_v6_blackhole
            apply_quic_block
            ok "已开启强制 IPv4：Google IPv6 黑洞 + 阻断 QUIC 绕过"
            ;;
        off|0)
            cfg_set IPV4_ONLY 0
            cfg_set BLACKHOLE_GOOGLE_V6 0
            cfg_set BLOCK_GOOGLE_QUIC 0
            clear_v6_blackhole
            clear_quic_block
            warn "已关闭强制 IPv4：Google 可能经 IPv6 出站，容易被判定地区异常"
            ;;
        *)
            printf 'IPV4_ONLY=%s  BLACKHOLE_GOOGLE_V6=%s  BLOCK_GOOGLE_QUIC=%s\n' \
                "$IPV4_ONLY" "$BLACKHOLE_GOOGLE_V6" "$BLOCK_GOOGLE_QUIC"
            ;;
    esac
}

# ── 刷新 Google 网段（官方 goog.json）────────────────────────────────
cmd_refresh_google() {
    info "拉取 https://www.gstatic.com/ipranges/goog.json ..."
    local tmp
    tmp=$(mktemp 2>/dev/null || printf '%s' /tmp/goog.json)
    if curl -4 -s --max-time 25 -o "$tmp" https://www.gstatic.com/ipranges/goog.json && [ -s "$tmp" ]; then
        grep -o '"ipv4Prefix": *"[^"]*"' "$tmp" | sed 's/.*"\([0-9a-fA-F.:/]*\)"/\1/' | sort -u > "$GOOGLE4.new"
        grep -o '"ipv6Prefix": *"[^"]*"' "$tmp" | sed 's/.*"\([0-9a-fA-F.:/]*\)"/\1/' | sort -u > "$GOOGLE6.new"
        if [ -s "$GOOGLE4.new" ] && [ -s "$GOOGLE6.new" ]; then
            mv "$GOOGLE4.new" "$GOOGLE4"
            mv "$GOOGLE6.new" "$GOOGLE6"
            ok "已更新: $(count_nets "$GOOGLE4") 条 IPv4 / $(count_nets "$GOOGLE6") 条 IPv6"
            warn "规则已变，执行 warp-google restart 生效"
        else
            rm -f "$GOOGLE4.new" "$GOOGLE6.new"
            err "解析 goog.json 失败，保留原列表"
        fi
    else
        err "下载 goog.json 失败，保留原列表"
    fi
    rm -f "$tmp"
}

# ── 守护：自动恢复 ───────────────────────────────────────────────────
repin_region() {
    local want=$1 cands ep cur
    [ -s "$SCAN_TSV" ] || { log "watchdog: 无扫描结果，无法自动换回"; return 1; }
    cands=$(awk -F'\t' -v w="$want" '$2==w {print $4"\t"$1}' "$SCAN_TSV" | sort -n | cut -f2)
    [ -n "$cands" ] || { log "watchdog: 扫描结果里没有地区 $want"; return 1; }
    for ep in $cands; do
        [ "$ep" = "$ENDPOINT" ] && continue
        log "watchdog: 尝试切换 $ep"
        endpoint_set "$ep" || continue
        wcli disconnect; sleep 1; wcli connect; sleep 6
        cur=$(probe_trace 4 | cut -d'|' -f2)
        if [ "$cur" = "$want" ]; then
            cfg_set ENDPOINT "$ep"
            log "watchdog: 已换回 $want ($ep)"
            return 0
        fi
    done
    log "watchdog: 未能换回 $want"
    return 1
}

cmd_watchdog() {
    log_rotate
    local st
    st=$(warp_state)
    if [ "$st" != "connected" ]; then
        log "watchdog: 状态=$st，重连"
        wcli connect
        sleep 6
        st=$(warp_state)
        [ "$st" = "connected" ] || log "watchdog: 重连后仍为 $st"
    fi
    if ! pgrep -x redsocks >/dev/null 2>&1; then
        log "watchdog: redsocks 掉了，重启"
        ensure_redsocks >/dev/null 2>&1
    fi
    if ! iptables -t nat -C OUTPUT -j "$CHAIN_NAT" >/dev/null 2>&1; then
        log "watchdog: NAT 规则丢失，重建"
        apply_iptables >/dev/null 2>&1
    fi
    if [ "$BLOCK_GOOGLE_QUIC" = "1" ] && ! iptables -t filter -C OUTPUT -j "$CHAIN_FLT" >/dev/null 2>&1; then
        log "watchdog: QUIC 规则丢失，重建"
        apply_quic_block >/dev/null 2>&1
    fi
    [ "$BLACKHOLE_GOOGLE_V6" = "1" ] && apply_v6_blackhole >/dev/null 2>&1

    local tr ip cc colo
    tr=$(probe_trace 4)
    if [ -z "$tr" ]; then
        log "watchdog: 探测出口失败"
        return 0
    fi
    ip=$(printf '%s' "$tr" | cut -d'|' -f1)
    cc=$(printf '%s' "$tr" | cut -d'|' -f2)
    colo=$(printf '%s' "$tr" | cut -d'|' -f3)
    state_write "$ip" "$cc" "$colo"
    if [ -n "$PREFER_REGION" ] && [ "$cc" != "$PREFER_REGION" ]; then
        log "watchdog: 出口漂移 $cc != $PREFER_REGION (colo=$colo)"
        [ "$AUTO_REPIN" = "1" ] && repin_region "$PREFER_REGION"
    fi
    return 0
}

# ── 分发 ─────────────────────────────────────────────────────────────
case "$1" in
    start)          do_start ;;
    stop)           do_stop ;;
    restart)        do_stop; sleep 1; do_start ;;
    status)         do_status ;;
    probe)          show_exit ;;
    scan)           shift; cmd_scan "$@" ;;
    region)         shift; cmd_region "$@" ;;
    nat64)          shift; cmd_nat64 "$@" ;;
    ipv4)           shift; cmd_ipv4 "$@" ;;
    endpoint)       shift; cmd_endpoint "$@" ;;
    refresh-google) cmd_refresh_google ;;
    watchdog)       cmd_watchdog ;;
    *)
        cat <<'USAGE_EOF'
warp-google —— WARP Google 透明代理运行时 (v2.0.0)

  start / stop / restart          启停透明代理
  status                          完整状态 + 当前出口 IP / 地区
  probe                           只看出口 IP / 地区
  scan [--deep] [--base "IP.."] [--ports "2408 500"] [--extra "IP:PORT"]
                                  扫描接入点，列出每个接入点的出口地区
  region [show|list|set CC|off]   查看 / 锁定出口地区（CC 为国家码，如 JP SG US）
  nat64  [list|set 代号|off]      用 NAT64 前缀强行更换落地国家
  endpoint [show|set IP:PORT|reset]
                                  手动指定 / 清除接入点
  ipv4   [on|off]                 强制 IPv4 开关
  refresh-google                  从官方 goog.json 刷新 Google 网段
  watchdog                        守护自检（由 systemd timer 调用）
USAGE_EOF
        ;;
esac

WARP_ENGINE_EOF
    chmod +x "$ENGINE"
}

# ═══════════════════════════════════════════════════════════════════════
#  Google 网段（默认精简列表，覆盖搜索 / YouTube / Gmail / AI Studio 等；
#  可用 warp refresh-google 换成官方 goog.json 全量列表）
# ═══════════════════════════════════════════════════════════════════════
write_google_lists() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/google4.txt" <<'G4_EOF'
8.8.4.0/24
8.8.8.0/24
64.15.112.0/20
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
70.32.128.0/19
72.14.192.0/18
74.114.24.0/21
74.125.0.0/16
104.132.0.0/14
107.167.160.0/19
107.178.192.0/18
108.59.80.0/20
108.170.192.0/18
108.177.0.0/17
136.22.160.0/20
136.22.176.0/21
136.22.184.0/23
136.22.186.0/24
136.23.39.0/24
136.23.48.0/20
136.23.64.0/18
142.250.0.0/15
162.120.128.0/17
172.110.32.0/21
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
192.178.0.0/15
199.192.112.0/22
199.223.232.0/21
207.223.160.0/20
208.65.152.0/22
208.117.224.0/19
209.85.128.0/17
216.58.192.0/19
216.73.80.0/20
216.239.32.0/19
G4_EOF
    cat > "$CONF_DIR/google6.txt" <<'G6_EOF'
2001:4860::/32
2404:6800::/32
2404:f340::/32
2600:1900::/29
2605:ef80::/32
2606:40::/32
2606:73c0::/32
2607:1c0:241:40::/60
2607:1c0:300::/40
2607:f8b0::/32
2620:11a:a000::/40
2620:120:e000::/40
2800:3f0::/32
2a00:1450::/32
2c0f:fb50::/32
G6_EOF
    ok "Google 网段已写入 $CONF_DIR"
}

write_conf() {
    mkdir -p "$CONF_DIR"
    if [ ! -f "$CONF_DIR/config" ]; then
        cat > "$CONF_DIR/config" <<'CONF_EOF'
# ══════════════ warp-google 配置（改完执行 warp restart 生效）══════════════
# WARP 的 SOCKS5 代理端口
WARP_PROXY_PORT=40000
# redsocks 本地监听端口
REDSOCKS_PORT=12345
# 自定义接入点 IP:PORT。留空 = Cloudflare 自动任播。
# 例: ENDPOINT="162.159.192.1:2408"
ENDPOINT=""
# 1 = 强制 Google 流量走 IPv4（Google IPv6 黑洞 + 阻断 QUIC）
IPV4_ONLY=1
BLACKHOLE_GOOGLE_V6=1
BLOCK_GOOGLE_QUIC=1
# 期望出口国家/地区两位码（JP/SG/US/HK...）。留空 = 不锁定。
PREFER_REGION=""
# 1 = 出口地区漂移时守护进程自动换回其它可用接入点
AUTO_REPIN=1
# 扫描用端口
SCAN_PORTS="2408"
# 追加到扫描列表的自定义接入点
SCAN_EXTRA=""
CONF_EOF
        ok "默认配置已写入 $CONF_DIR/config"
    else
        ok "已存在配置 $CONF_DIR/config（保留不动）"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  安装 Cloudflare WARP 客户端
# ═══════════════════════════════════════════════════════════════════════
install_warp() {
    hr
    info "安装 Cloudflare WARP 官方客户端..."
    if command -v warp-cli >/dev/null 2>&1; then
        ok "warp-cli 已安装，跳过"
        return 0
    fi
    case "$OS" in
        ubuntu|debian)
            pkg_install gnupg curl wget lsb-release >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
                | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            printf 'deb [arch=%s signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ %s main\n' \
                "$DPKG_ARCH" "$CODENAME" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -qq
            apt-get install -y cloudflare-warp
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/cloudflare-warp.repo <<'REPO_EOF'
[cloudflare-warp]
name=Cloudflare WARP
baseurl=https://pkg.cloudflareclient.com/rpm
enabled=1
gpgcheck=1
gpgkey=https://pkg.cloudflareclient.com/pubkey.gpg
REPO_EOF
            if command -v dnf >/dev/null 2>&1; then dnf install -y cloudflare-warp; else yum install -y cloudflare-warp; fi
            ;;
        *) die "不支持的操作系统: $OS" ;;
    esac
    command -v warp-cli >/dev/null 2>&1 || die "WARP 安装失败，请检查网络或手动安装"
    ok "warp-cli 安装完成"
}

configure_warp() {
    hr
    info "注册并配置 WARP（proxy 模式）..."
    mkdir -p /var/lib/cloudflare-warp
    if [ ! -f /var/lib/cloudflare-warp/accepted-tos.json ]; then
        printf '%s' '{"accepted":true}' > /var/lib/cloudflare-warp/accepted-tos.json
        systemctl restart warp-svc >/dev/null 2>&1 || true
        sleep 2
    fi
    warp-cli --accept-tos registration new >/dev/null 2>&1 \
        || warp-cli --accept-tos register >/dev/null 2>&1 || true
    warp-cli --accept-tos mode proxy >/dev/null 2>&1 \
        || warp-cli mode proxy >/dev/null 2>&1 || true
    warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1 \
        || warp-cli proxy port 40000 >/dev/null 2>&1 || true
    info "连接 WARP ..."
    warp-cli --accept-tos connect >/dev/null 2>&1 || warp-cli connect >/dev/null 2>&1 || true
    sleep 4
    ok "WARP 状态: $(warp-cli --accept-tos status 2>/dev/null || warp-cli status 2>/dev/null | head -1)"
}

# ═══════════════════════════════════════════════════════════════════════
#  透明代理依赖：redsocks
# ═══════════════════════════════════════════════════════════════════════
setup_redsocks() {
    hr
    info "安装 redsocks 透明代理..."
    cat > /etc/redsocks.conf <<'REDSOCKS_EOF'
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
REDSOCKS_EOF

    if command -v redsocks >/dev/null 2>&1; then
        ok "redsocks 已安装，跳过"
    else
        printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
        chmod +x /usr/sbin/policy-rc.d
        pkg_install redsocks iptables >/dev/null 2>&1 || warn "redsocks 安装可能失败"
        rm -f /usr/sbin/policy-rc.d
        command -v redsocks >/dev/null 2>&1 && ok "redsocks 安装完成" || warn "未找到 redsocks，透明代理可能不生效"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  systemd：主服务 + 守护定时器
# ═══════════════════════════════════════════════════════════════════════
write_systemd() {
    hr
    info "写入 systemd 服务..."
    local interval="10min"
    if [ -f "$CONF_DIR/config" ]; then
        local iv
        iv=$(grep -E '^WATCHDOG_INTERVAL_MIN=' "$CONF_DIR/config" | cut -d= -f2)
        [ -n "$iv" ] && interval="$${iv}min"
    fi

    cat > /etc/systemd/system/warp-google.service <<'SVC_EOF'
[Unit]
Description=WARP Google Transparent Proxy
After=network-online.target warp-svc.service
Wants=network-online.target warp-svc.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/warp-google start
ExecStop=/usr/local/bin/warp-google stop
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
SVC_EOF

    cat > /etc/systemd/system/warp-google-watchdog.service <<'WD_EOF'
[Unit]
Description=WARP Google watchdog (auto recover)
After=warp-google.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/warp-google watchdog
WD_EOF

    cat > /etc/systemd/system/warp-google-watchdog.timer <<TIMER_EOF
[Unit]
Description=Run WARP Google watchdog periodically

[Timer]
OnBootSec=3min
OnUnitActiveSec=$interval
AccuracySec=30s

[Install]
WantedBy=timers.target
TIMER_EOF

    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable warp-google >/dev/null 2>&1
    systemctl enable --now warp-google-watchdog.timer >/dev/null 2>&1
    ok "systemd 服务已注册（守护间隔 $interval）"
}

# ═══════════════════════════════════════════════════════════════════════
#  管理命令 /usr/local/bin/warp
# ═══════════════════════════════════════════════════════════════════════
write_wrapper() {
    cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/usr/bin/env bash
ENGINE=/usr/local/bin/warp-google
INSTALLER=/usr/local/bin/warp-google.sh
RAW_URL="https://raw.githubusercontent.com/pomelo-neko/warp-google/main/warp-google.sh"

case "$1" in
    status|start|stop|restart|probe|scan|region|nat64|endpoint|ipv4|watchdog|refresh-google)
        [ -x "$ENGINE" ] || { echo "warp-google 未安装，请先执行安装脚本"; exit 1; }
        exec "$ENGINE" "$@"
        ;;
    ip)
        [ -x "$ENGINE" ] || { echo "warp-google 未安装"; exit 1; }
        exec "$ENGINE" probe
        ;;
    test)
        echo "== 直连 Google =="
        curl -4 -s -o /dev/null -w "  直连状态码: %{http_code}\n" --max-time 10 https://www.google.com
        echo "== 经 WARP =="
        curl -4 -s -o /dev/null -w "  WARP 状态码: %{http_code}\n" --max-time 12 \
            -x socks5://127.0.0.1:40000 https://www.google.com
        echo "== 出口信息 =="
        "$ENGINE" probe
        ;;
    install)
        if [ -f "$INSTALLER" ]; then exec bash "$INSTALLER" install; fi
        printf '请执行: bash <(curl -fsSL %s) install\n' "$RAW_URL"
        ;;
    uninstall)
        if [ -f "$INSTALLER" ]; then exec bash "$INSTALLER" uninstall; fi
        printf '请执行: bash <(curl -fsSL %s) uninstall\n' "$RAW_URL"
        ;;
    menu)
        if [ -f "$INSTALLER" ]; then exec bash "$INSTALLER" menu; fi
        printf '请执行: bash <(curl -fsSL %s)\n' "$RAW_URL"
        ;;
    *)
        cat <<'HELP_EOF'

  warp —— WARP for Google 管理命令

  常用
    warp status                  查看状态 + 当前出口 IP / 地区
    warp test                    测试直连 / WARP / 出口信息
    warp ip                      只看出口 IP 与地区
    warp restart                 重启透明代理与规则

  地区 / 接入点
    warp scan [--deep]           扫描所有接入点，列出各自落地的地区
    warp region list             查看上一次扫描到哪些地区
    warp region set JP           锁定出口到日本（换地区码即可）
    warp region off              取消地区锁定
    warp endpoint set 162.159.192.1:2408
    warp endpoint reset
    warp nat64 list              用第三方 NAT64 网关换落地国家
    warp nat64 set us

  其它
    warp ipv4 on|off             强制 IPv4 开关
    warp refresh-google          更新 Google 网段（官方 goog.json）
    warp start | stop            启停透明代理
    warp uninstall               完整卸载
    warp menu                    打开菜单

HELP_EOF
        ;;
esac
WRAPPER_EOF
    chmod +x "$WRAPPER"
    ok "管理命令已创建: warp {status|test|ip|scan|region|nat64|endpoint|ipv4|...}"
}

# ═══════════════════════════════════════════════════════════════════════
#  自安装副本
# ═══════════════════════════════════════════════════════════════════════
RAW_URL="https://raw.githubusercontent.com/pomelo-neko/warp-google/main/warp-google.sh"

install_self() {
    local src="${BASH_SOURCE[0]}"
    if [ -n "$src" ] && [ -r "$src" ]; then
        if cp -f "$src" /tmp/.warp-google.sh 2>/dev/null && [ -s /tmp/.warp-google.sh ]; then
            mv -f /tmp/.warp-google.sh "$INSTALLER"
            chmod +x "$INSTALLER"
            ok "安装器已备份到 $INSTALLER（可用 warp uninstall 卸载）"
            return 0
        fi
    fi
    if curl -fsSL "$RAW_URL" -o "$INSTALLER" 2>/dev/null; then
        chmod +x "$INSTALLER"
        ok "安装器已下载到 $INSTALLER"
    else
        warn "安装器自备份失败（不影响使用，卸载时请重新下载脚本）"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  IP 信息 / 连通性测试
# ═══════════════════════════════════════════════════════════════════════
ip_geo() {
    local ip=$1 j
    [ -n "$ip" ] || { printf '未知'; return; }
    j=$(curl -4 -s --max-time 6 "http://ip-api.com/json/$ip?lang=zh-CN&fields=status,country,city,isp" 2>/dev/null)
    if printf '%s' "$j" | grep -q '"status":"success"'; then
        printf '%s - %s (%s)' \
            "$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')" \
            "$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')" \
            "$(printf '%s' "$j" | sed -n 's/.*"isp":"\([^"]*\)".*/\1/p')"
        return
    fi
    j=$(curl -4 -s --max-time 6 "https://ipinfo.io/$ip/json" 2>/dev/null)
    printf '%s - %s' \
        "$(printf '%s' "$j" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p')" \
        "$(printf '%s' "$j" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p')"
}

show_current_ip() {
    hr
    info "获取本机直连 IP 信息..."
    local ip4 ip6
    ip4=$(curl -4 -s --max-time 6 https://api.ip.sb/ip 2>/dev/null || curl -4 -s --max-time 6 https://ipv4.icanhazip.com 2>/dev/null)
    ip4=$(printf '%s' "$ip4" | tr -d ' \n')
    ip6=$(curl -6 -s --max-time 6 https://api.ip.sb/ip 2>/dev/null || curl -6 -s --max-time 6 https://ipv6.icanhazip.com 2>/dev/null)
    ip6=$(printf '%s' "$ip6" | tr -d ' \n')
    printf '  %-14s %s\n' "直连 IPv4:" "${ip4:-无}"
    [ -n "$ip4" ] && printf '  %-14s %s\n' "" "$(ip_geo "$ip4")"
    printf '  %-14s %s\n' "直连 IPv6:" "${ip6:-无}"
    printf '  %-14s %s\n' "" "$(ip_geo "$ip6")"
}

do_test() {
    hr
    info "测试 Google 连通性..."
    local d w a
    d=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 10 https://www.google.com 2>/dev/null)
    w=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 12 -x socks5://127.0.0.1:40000 https://www.google.com 2>/dev/null)
    a=$(curl -4 -s -o /dev/null -w '%{http_code}' --max-time 12 -x socks5://127.0.0.1:40000 https://aistudio.google.com 2>/dev/null)
    printf '  %-22s %s\n' "直连 google.com:" "${d:-失败}"
    printf '  %-22s %s\n' "经 WARP google.com:" "${w:-失败}"
    printf '  %-22s %s\n' "经 WARP AI Studio:" "${a:-失败}"
    if [ -x "$ENGINE" ]; then
        printf '\n'
        "$ENGINE" probe
    fi
}

show_status() {
    hr
    printf '  %-16s %s\n' "操作系统:" "$OS $VER"
    printf '  %-16s %s\n' "系统架构:" "$ARCH"
    if command -v warp-cli >/dev/null 2>&1; then
        printf '  %-16s %s\n' "warp-cli:" "已安装"
    else
        printf '  %-16s %s\n' "warp-cli:" "未安装"
    fi
    if [ -x "$ENGINE" ]; then
        printf '\n'
        "$ENGINE" status
    else
        warn "运行时引擎未安装，请先执行安装"
    fi
    hr
}

# ═══════════════════════════════════════════════════════════════════════
#  安装 / 卸载
# ═══════════════════════════════════════════════════════════════════════
do_install() {
    clear
    banner
    info "开始安装 WARP for Google v$sh_ver"
    check_dependencies
    check_network
    show_current_ip
    write_google_lists
    write_conf
    write_engine
    install_self
    install_warp
    configure_warp
    setup_redsocks
    write_wrapper
    write_systemd

    hr
    info "启动透明代理与规则..."
    "$ENGINE" start

    do_test

    printf '\n'
    printf '%s\n' "$GREEN  ╔══════════════════════════════════════════════════════════════╗$PLAIN"
    printf '%s\n' "$GREEN  ║             ✅  安装完成，Google 流量已走 WARP               ║$PLAIN"
    printf '%s\n' "$GREEN  ╚══════════════════════════════════════════════════════════════╝$PLAIN"
    printf '\n'
    printf '  接下来你可以：\n'
    printf '    %swarp scan%s            扫描所有接入点，看你机器实际能落到哪些地区\n' "$CYAN" "$PLAIN"
    printf '    %swarp region set JP%s    锁定出口地区（把 JP 换成你想要的国家码）\n' "$CYAN" "$PLAIN"
    printf '    %swarp nat64 list%s       用第三方 NAT64 网关强行换落地国家\n' "$CYAN" "$PLAIN"
    printf '    %swarp status%s           查看当前出口 IP / 地区\n' "$CYAN" "$PLAIN"
    printf '    %ssystemctl status warp-google-watchdog.timer%s\n' "$CYAN" "$PLAIN"
    printf '                            守护进程会定期自检，掉线/规则丢失自动恢复\n'
    printf '\n'
    printf '  管理命令: %swarp%s      配置文件: %s\n' "$CYAN" "$PLAIN" "$CONF_DIR/config"
    printf '\n'
}

do_uninstall() {
    hr
    info "正在完整卸载..."
    systemctl disable --now warp-google-watchdog.timer >/dev/null 2>&1
    systemctl disable --now warp-google >/dev/null 2>&1
    [ -x "$ENGINE" ] && "$ENGINE" stop >/dev/null 2>&1
    rm -f /etc/systemd/system/warp-google.service \
          /etc/systemd/system/warp-google-watchdog.service \
          /etc/systemd/system/warp-google-watchdog.timer
    systemctl daemon-reload >/dev/null 2>&1

    pkill -x redsocks 2>/dev/null
    iptables -t nat -D OUTPUT -j WARP_GOOGLE 2>/dev/null
    iptables -t nat -F WARP_GOOGLE 2>/dev/null
    iptables -t nat -X WARP_GOOGLE 2>/dev/null
    iptables -t filter -D OUTPUT -j WARP_GOOGLE_FLT 2>/dev/null
    iptables -t filter -F WARP_GOOGLE_FLT 2>/dev/null
    iptables -t filter -X WARP_GOOGLE_FLT 2>/dev/null

    if [ -f "$CONF_DIR/google6.txt" ]; then
        while read -r net; do
            case "$net" in ''|'#'*) continue ;; esac
            ip -6 route del blackhole "$net" 2>/dev/null || true
        done < "$CONF_DIR/google6.txt"
    fi

    warp-cli --accept-tos disconnect >/dev/null 2>&1 || warp-cli disconnect >/dev/null 2>&1 || true
    rm -f "$ENGINE" "$WRAPPER" "$INSTALLER" /etc/redsocks.conf
    rm -f /usr/sbin/policy-rc.d

    case "$PKG_MGR" in
        apt)
            apt-get remove -y cloudflare-warp redsocks >/dev/null 2>&1
            rm -f /etc/apt/sources.list.d/cloudflare-client.list
            ;;
        yum)
            yum remove -y cloudflare-warp redsocks >/dev/null 2>&1 \
                || dnf remove -y cloudflare-warp redsocks >/dev/null 2>&1
            rm -f /etc/yum.repos.d/cloudflare-warp.repo
            ;;
    esac

    if [ -t 0 ]; then
        read -rp "  是否同时删除配置目录 $CONF_DIR 与日志? [y/N]: " del_conf
        if [[ "$del_conf" =~ ^[Yy]$ ]]; then
            rm -rf "$CONF_DIR" /var/log/warp-google.log
        fi
    fi
    hr
    ok "WARP for Google 已完整卸载"
}

# ═══════════════════════════════════════════════════════════════════════
#  菜单
# ═══════════════════════════════════════════════════════════════════════
show_menu() {
    clear
    banner
    show_status
    printf '  %s请选择操作：%s\n' "$BOLD" "$PLAIN"
    printf '\n'
    printf '  %s1.%s  安装 / 重装 WARP + Google 解锁\n' "$GREEN" "$PLAIN"
    printf '  %s2.%s  扫描接入点，看你的机器能落到哪些地区   %s← 想换地区先做这个%s\n' "$GREEN" "$PLAIN" "$YELLOW" "$PLAIN"
    printf '  %s3.%s  锁定出口地区 / 手动指定接入点\n' "$GREEN" "$PLAIN"
    printf '  %s4.%s  强制 IPv4 开关 / NAT64 换落地国家\n' "$GREEN" "$PLAIN"
    printf '  %s5.%s  查看 IP 信息（直连 / WARP 出口）\n' "$GREEN" "$PLAIN"
    printf '  %s6.%s  测试 Google / AI Studio 连通性\n' "$GREEN" "$PLAIN"
    printf '  %s7.%s  更新 Google 网段（官方 goog.json）\n' "$GREEN" "$PLAIN"
    printf '  %s8.%s  重启透明代理\n' "$GREEN" "$PLAIN"
    printf '  %s9.%s  完整卸载\n' "$GREEN" "$PLAIN"
    printf '\n'
    printf '  %s0.%s  退出\n' "$GREEN" "$PLAIN"
    printf '\n'
    hr
    read -rp "  请输入选项 [0-9]: " choice
    printf '\n'
    case "$choice" in
        1) do_install ;;
        2) if [ -x "$ENGINE" ]; then "$ENGINE" scan; else warn "请先安装"; fi ;;
        3)
            printf '  1) 锁定地区   2) 手动指定接入点   3) 取消锁定\n'
            read -rp "  选择: " sub
            case "$sub" in
                1) read -rp "  目标国家码（如 JP/SG/US）: " cc; [ -x "$ENGINE" ] && "$ENGINE" region set "$cc" ;;
                2) read -rp "  接入点 IP:PORT: " ep; [ -x "$ENGINE" ] && "$ENGINE" endpoint set "$ep" ;;
                3) [ -x "$ENGINE" ] && "$ENGINE" region off ;;
            esac
            ;;
        4)
            printf '  1) 强制 IPv4 开   2) 强制 IPv4 关   3) NAT64 换落地\n'
            read -rp "  选择: " sub
            case "$sub" in
                1) [ -x "$ENGINE" ] && "$ENGINE" ipv4 on ;;
                2) [ -x "$ENGINE" ] && "$ENGINE" ipv4 off ;;
                3)
                    if [ -x "$ENGINE" ]; then
                        "$ENGINE" nat64 list
                        read -rp "  输入代号: " code
                        "$ENGINE" nat64 set "$code"
                    fi
                    ;;
            esac
            ;;
        5) show_current_ip; [ -x "$ENGINE" ] && "$ENGINE" probe ;;
        6) do_test ;;
        7) [ -x "$ENGINE" ] && "$ENGINE" refresh-google && "$ENGINE" restart ;;
        8) [ -x "$ENGINE" ] && "$ENGINE" restart ;;
        9)
            read -rp "  确认完整卸载? [y/N]: " cu
            if [[ "$cu" =~ ^[Yy]$ ]]; then do_uninstall; else warn "已取消"; fi
            ;;
        0) printf '%s  再见！%s\n\n' "$GREEN" "$PLAIN"; exit 0 ;;
        *) error "无效选项，请输入 0-9" ;;
    esac
    printf '\n'
    read -n1 -rp "  按任意键继续..." _
    printf '\n'
    show_menu
}

# ═══════════════════════════════════════════════════════════════════════
#  入口
# ═══════════════════════════════════════════════════════════════════════
case "$1" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    show_status ;;
    test)      do_test ;;
    menu|"")   show_menu ;;
    ip|probe|start|stop|restart|scan|region|nat64|endpoint|ipv4|watchdog|refresh-google)
        if [ -x "$ENGINE" ]; then
            exec "$ENGINE" "$@"
        fi
        die "运行时未安装，请先执行: bash $0 install"
        ;;
    *)
        printf '%s\n' "用法: $0 {install|uninstall|menu|status|test|scan|region|nat64|endpoint|ipv4|ip|restart|...}"
        printf '%s\n' "不带参数运行会打开交互菜单。"
        printf '%s\n' "项目地址: $REPO_URL"
        exit 1
        ;;
esac
