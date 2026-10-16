
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

sh_ver="2.2.0"
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
#  warp-google 运行时引擎   v2.2.0
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
REQUIRE_WARP=1             # 1=WARP 不通时不劫持 Google 流量，保证网页至少能直连打开
CONNECT_TIMEOUT=25         # 等待 WARP 连上的超时秒数
HIJACK_ALL=0               # 1=接管所有 80/443 出站（不再依赖 Google IP 列表，杜绝漏网）
# 用来兜底解析的 Google 域名：解析出来的 IP 会并进劫持列表
GOOGLE_DOMAINS="google.com www.google.com accounts.google.com aistudio.google.com gemini.google.com makersuite.google.com generativelanguage.googleapis.com aiplatform.googleapis.com www.googleapis.com oauth2.googleapis.com youtube.com www.youtube.com googlevideo.com ytimg.com gstatic.com www.gstatic.com googleusercontent.com lh3.googleusercontent.com mail.google.com drive.google.com"
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

# 状态原始输出：故意把 stderr 也收进来。
# 不同版本的 warp-cli 有的把状态打到 stderr，只收 stdout 会得到空串，
# 于是「明明连着」却被判成 unknown —— 扫描时就会把可用接入点全部标成失败。
warp_status_raw() {
    { warp-cli --accept-tos status 2>&1 || warp-cli status 2>&1 || true; } \
        | sed 's/\x1b\[[0-9;]*m//g'
}

# 注意：必须先判断 disconnected，否则 "Disconnected" 会被 connected 命中
warp_state() {
    local s
    s=$(warp_status_raw | sed 's/\x1b\[[0-9;]*m//g' | tr 'A-Z' 'a-z')
    case "$s" in
        *disconnected*)        printf 'disconnected' ;;
        *"unable to connect"*) printf 'failed' ;;
        *"no network"*)        printf 'no-network' ;;
        *connecting*)          printf 'connecting' ;;
        *connected*)           printf 'connected' ;;
        *)                     printf 'unknown' ;;
    esac
}

# 等待 WARP 连上：connecting / unknown 继续等，只有明确失败才提前退出。
# 旧实现只等 10 秒且把 unknown 当失败，慢一点的接入点会被误判。
wait_connected() {
    local timeout=$1 i st streak=0
    [ -n "$timeout" ] || timeout=${CONNECT_TIMEOUT:-25}
    for i in $(seq 1 "$timeout"); do
        st=$(warp_state)
        case "$st" in
            connected)         printf 'connected'; return 0 ;;
            failed|no-network) printf '%s' "$st";  return 1 ;;
            unknown)           streak=$((streak + 1)) ;;
            *)                 streak=0 ;;
        esac
        [ "$streak" -ge 8 ] && { printf 'unknown'; return 1; }
        sleep 1
    done
    printf '%s' "$(warp_state)"
    return 1
}

# WARP 的 SOCKS5 是否真的能出网（能出网才值得把 Google 流量劫持进来）
warp_socks_ok() {
    probe_trace 4 >/dev/null 2>&1
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

# 换接入点并当场验证：连不上 / 出不了网就自动回滚到原来的值。
# 这样「换接入点」这个动作再也不会把 WARP 搞死。
apply_endpoint_verified() {
    local ep=$1 prev=$2 st
    if ! endpoint_set "$ep"; then
        err "设置接入点失败（当前 warp-cli 不支持自定义接入点）"
        return 1
    fi
    wcli disconnect
    sleep 1
    wcli connect
    st=$(wait_connected "$CONNECT_TIMEOUT")
    if [ "$st" = "connected" ] && warp_socks_ok; then
        cfg_set ENDPOINT "$ep"
        ok "接入点 $ep 可用，已保存"
        return 0
    fi
    warn "接入点 $ep 不可用（状态: $st），自动回滚"
    if [ -n "$prev" ]; then
        endpoint_set "$prev" >/dev/null 2>&1
        cfg_set ENDPOINT "$prev"
    else
        endpoint_reset >/dev/null 2>&1
        cfg_set ENDPOINT ""
    fi
    wcli disconnect
    sleep 1
    wcli connect
    st=$(wait_connected "$CONNECT_TIMEOUT")
    warn "已回滚（状态: $st）"
    return 1
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

    # 全量接管模式：不看 Google 网段，任何 80/443 出站都进 WARP，
    # 从根本上杜绝"某个 Google IP 不在列表里 → 走直连 → 送中"的情况。
    if [ "$HIJACK_ALL" = "1" ]; then
        local ex
        for ex in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 \
                  172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 \
                  198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 \
                  240.0.0.0/4 255.255.255.255/32; do
            iptables -t nat -A "$CHAIN_NAT" -d "$ex" -j RETURN
        done
        iptables -t nat -A "$CHAIN_NAT" -p tcp -m multiport --dports 80,443 \
            -j REDIRECT --to-ports "$REDSOCKS_PORT"
        iptables -t nat -C OUTPUT -j "$CHAIN_NAT" 2>/dev/null || iptables -t nat -A OUTPUT -j "$CHAIN_NAT"
        ok "全量接管模式：所有 80/443 出站流量都走 WARP"
        return 0
    fi

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

    local st
    st=$(warp_state)
    if [ "$st" != "connected" ]; then
        info "连接 WARP ..."
        wcli connect
        st=$(wait_connected "$CONNECT_TIMEOUT")
    fi
    if [ "$st" = "connected" ]; then
        ok "WARP 已连接"
    else
        warn "WARP 未连接（状态: $st）"
    fi

    ensure_redsocks || warn "redsocks 启动失败，透明代理可能不生效"

    # ── 失败即放行 ───────────────────────────────────────────────
    # WARP 不通时绝对不能装劫持规则：redsocks 会把请求转给一个连不上的
    # SOCKS5，结果是 Google 直接打不开，而其它网站一切正常。
    # 宁可不接管（网页能打开，只是地区可能不理想），也不要全断。
    if [ "$REQUIRE_WARP" = "1" ]; then
        if [ "$st" != "connected" ]; then
            warn "WARP 未连接 —— 本次不劫持 Google 流量，保持直连（网页至少能打开）"
            warn "修好之后执行：warp recover"
            clear_iptables
            clear_quic_block
            [ "$BLACKHOLE_GOOGLE_V6" = "1" ] && apply_v6_blackhole
            log "start: WARP 不可用($st)，已放行直连，未安装劫持规则"
            return 0
        fi
        if ! warp_socks_ok; then
            warn "WARP 显示已连接，但 SOCKS5 代理出不了网 —— 同样不劫持，保持直连"
            warn "修好之后执行：warp recover"
            clear_iptables
            clear_quic_block
            log "start: SOCKS5 不通，已放行直连，未安装劫持规则"
            return 0
        fi
    fi

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
            apply_endpoint_verified "$ep" "$ENDPOINT" || return 1
            do_start >/dev/null 2>&1
            show_exit
            ;;
        reset|off)
            endpoint_reset
            cfg_set ENDPOINT ""
            wcli disconnect
            sleep 1
            wcli connect
            local rst
            rst=$(wait_connected "$CONNECT_TIMEOUT")
            ok "已恢复 Cloudflare 自动任播，状态: $rst"
            do_start >/dev/null 2>&1
            ok "透明代理规则已按新状态刷新"
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

    # ── 先保存现场，扫描结束后无条件恢复 ─────────────────────────
    # 扫描靠反复改写 warp-cli 的接入点来实现，中途被打断/失败时若不恢复，
    # warp-cli 会一直卡在最后一个（可能不通的）接入点上：劫持规则还在、
    # WARP 却连不上 —— 结果就是 Google 彻底打不开。
    local saved_ep="$ENDPOINT"
    local scan_restored=0

    restore_scene() {
        [ "$scan_restored" = "1" ] && return 0
        scan_restored=1
        printf '\n'
        info "恢复扫描前的接入点设置..."
        if [ -n "$saved_ep" ]; then
            endpoint_set "$saved_ep" >/dev/null 2>&1
        else
            endpoint_reset >/dev/null 2>&1
        fi
        wcli disconnect
        sleep 1
        wcli connect
        local rst
        rst=$(wait_connected "$CONNECT_TIMEOUT")
        if [ "$rst" = "connected" ]; then
            ok "已恢复接入点: ${saved_ep:-Cloudflare 自动任播}"
            do_start >/dev/null 2>&1
            ok "透明代理规则已重新生效"
        else
            warn "恢复后 WARP 状态仍为 $rst —— 保持直连，Google 不会打不开"
            warn "可执行 warp recover 重试"
        fi
    }
    trap 'restore_scene; trap - INT TERM; exit 130' INT TERM

    # 扫描期间先撤掉劫持规则：否则 WARP 一断，Google 会卡死而不是回落直连
    info "扫描期间会临时撤掉 Google 劫持规则并反复重连，网页会短暂走直连"
    clear_iptables
    clear_quic_block

    if ! endpoint_set "162.159.192.1:2408"; then
        err "当前 warp-cli 版本不支持自定义接入点（set-custom-endpoint / tunnel endpoint set）"
        err "请升级 warp-cli，或改用 nat64 方式更换落地"
        restore_scene
        trap - INT TERM
        return 1
    fi

    local b p e list=""
    for b in $bases; do for p in $ports; do list="$list $b:$p"; done; done
    for e in $extra; do list="$list $e"; done

    local total=0
    for e in $list; do total=$((total + 1)); done
    info "共 $total 个候选接入点，每个最多等 $CONNECT_TIMEOUT 秒，请耐心等待"
    : > "$SCAN_TSV"

    local ep t0 t1 cost st tr ip cc colo good=0
    for ep in $list; do
        printf '  → %-24s' "$ep"
        endpoint_set "$ep" >/dev/null 2>&1
        wcli disconnect
        sleep 1
        t0=$(date +%s)
        wcli connect
        st=$(wait_connected "$CONNECT_TIMEOUT")
        t1=$(date +%s)
        cost=$((t1 - t0))
        if [ "$st" != "connected" ]; then
            printf ' × 连不上 (%ss, %s)\n' "$cost" "$st"
            printf '%s\tFAIL-%s\t-\t%s\t-\n' "$ep" "$st" "$cost" >> "$SCAN_TSV"
            continue
        fi
        sleep 2
        tr=$(probe_trace 4)
        if [ -z "$tr" ]; then
            printf ' ! 连上了但拿不到出口信息 (%ss)\n' "$cost"
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
    awk -F'\t' '$2 !~ /^(FAIL|NO-TRACE)/ {print $2}' "$SCAN_TSV" | sort | uniq -c | sort -rn \
        | awk '{printf "  %-4s × %s 个接入点\n", $2, $1}'
    printf '\n%s\n' "接入点明细（地区 / colo / 握手耗时 / 出口IP）:"
    awk -F'\t' '$2 !~ /^(FAIL|NO-TRACE)/ {printf "  %-24s %-4s %-6s %3ss  %s\n",$1,$2,$3,$4,$5}' "$SCAN_TSV" \
        | sort -k2
    if [ "$good" = "0" ]; then
        printf '\n'
        warn "一个都没连上。常见原因：VPS 到 Cloudflare WARP 接入点的 UDP 被阻断，"
        warn "或当前 warp-cli 版本对自定义接入点支持有问题（可执行 warp doctor 看细节）。"
        warn "请务必确认已恢复自动接入点：warp endpoint reset && warp recover"
    fi

    restore_scene
    trap - INT TERM
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
            if ! apply_endpoint_verified "$best" "$ENDPOINT"; then
                err "接入点 $best 不可用，配置未改动"
                return 1
            fi
            cfg_set PREFER_REGION "$want"
            do_start >/dev/null 2>&1
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
            cfg_set PREFER_REGION ""
            if ! apply_endpoint_verified "$ep" "$ENDPOINT"; then
                err "NAT64 接入点不可用（可能本机没有 IPv6，或 warp-cli 不支持 IPv6 接入点）"
                err "已自动回滚到原接入点"
                return 1
            fi
            do_start >/dev/null 2>&1
            show_exit
            ;;
        off)
            endpoint_reset
            cfg_set ENDPOINT ""
            wcli disconnect
            sleep 1
            wcli connect
            ok "已取消自定义接入点，状态: $(wait_connected "$CONNECT_TIMEOUT")"
            do_start >/dev/null 2>&1
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
    local tmp
    tmp=$(mktemp 2>/dev/null || printf '%s' /tmp/goog.json)
    info "拉取官方网段 https://www.gstatic.com/ipranges/goog.json ..."
    if curl -4 -s --max-time 25 -o "$tmp" https://www.gstatic.com/ipranges/goog.json && [ -s "$tmp" ]; then
        grep -o '"ipv4Prefix": *"[^"]*"' "$tmp" | sed 's/.*"\([0-9a-fA-F.:/]*\)"/\1/' | sort -u > "$GOOGLE4.new"
        grep -o '"ipv6Prefix": *"[^"]*"' "$tmp" | sed 's/.*"\([0-9a-fA-F.:/]*\)"/\1/' | sort -u > "$GOOGLE6.new"
        if [ -s "$GOOGLE4.new" ] && [ -s "$GOOGLE6.new" ]; then
            mv "$GOOGLE4.new" "$GOOGLE4"
            mv "$GOOGLE6.new" "$GOOGLE6"
            ok "官方全量网段: $(count_nets "$GOOGLE4") 条 IPv4 / $(count_nets "$GOOGLE6") 条 IPv6"
        else
            rm -f "$GOOGLE4.new" "$GOOGLE6.new"
            err "解析 goog.json 失败，保留原列表"
        fi
    else
        err "下载 goog.json 失败（可能是网络问题），继续用现有列表"
    fi
    rm -f "$tmp"

    # ── 兜底：把 Google 域名实际解析出来的 IP 也并进劫持列表 ──────
    # 这一步能覆盖"goog.json 里没有、但 Google 域名确实会解析到"的 IP，
    # 是防止 Google 流量漏到直连（→ 送中）的最后一道保险。
    local d gip ips before after added=0
    : > "$GOOGLE4.dom"
    for d in $GOOGLE_DOMAINS; do
        ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}')
        [ -n "$ips" ] || ips=$(host -t A "$d" 2>/dev/null | sed -n 's/.*has address //p')
        for gip in $ips; do
            case "$gip" in
                ''|0.*|10.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[0-2][0-9].*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|224.*|2[3-5][0-9].*) continue ;;
            esac
            printf '%s/32\n' "$gip" >> "$GOOGLE4.dom"
        done
    done
    if [ -s "$GOOGLE4.dom" ]; then
        sort -u "$GOOGLE4.dom" > "$GOOGLE4.dom.u"
        before=$(count_nets "$GOOGLE4")
        cat "$GOOGLE4" "$GOOGLE4.dom.u" | grep -vE '^[[:space:]]*(#|$)' | sort -u > "$GOOGLE4.m"
        mv "$GOOGLE4.m" "$GOOGLE4"
        after=$(count_nets "$GOOGLE4")
        added=$((after - before))
        ok "并入域名解析 IP：新增 $added 条，当前共 $after 条 IPv4 规则"
    else
        warn "域名解析没取到 IP（DNS 不可用？），已跳过这一步"
    fi
    rm -f "$GOOGLE4.dom" "$GOOGLE4.dom.u"

    warn "列表已更新，执行 warp-google restart 生效"
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
    local st healthy=1
    st=$(warp_state)
    if [ "$st" != "connected" ]; then
        log "watchdog: 状态=$st，重连"
        wcli connect
        st=$(wait_connected "$CONNECT_TIMEOUT")
        [ "$st" = "connected" ] || log "watchdog: 重连后仍为 $st"
    fi

    # ── 失败即放行 ───────────────────────────────────────────────
    # WARP 不健康时必须撤掉劫持，否则 Google 会被转进一个连不上的 SOCKS5
    [ "$st" = "connected" ] || healthy=0
    if [ "$healthy" = "1" ]; then
        warp_socks_ok || healthy=0
    fi
    if [ "$REQUIRE_WARP" = "1" ] && [ "$healthy" = "0" ]; then
        if iptables -t nat -C OUTPUT -j "$CHAIN_NAT" >/dev/null 2>&1; then
            log "watchdog: WARP 不健康($st)，撤掉 Google 劫持规则改为直连"
            clear_iptables
            clear_quic_block
        fi
        return 0
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

    # 送中复查：Google 的判定会随时间变化（邻居持续上报会把整段拖下水），
    # 一旦翻红就记日志提醒重新 hunt
    local cns
    cns=$(google_cn_state "-x socks5://127.0.0.1:$WARP_PROXY_PORT" | cut -d'|' -f1)
    if [ "$cns" = "cn" ]; then
        log "watchdog: 出口 $ip ($cc/$colo) 已被 Google 判定为中国大陆 —— 执行 warp hunt 换一个"
    fi
    return 0
}

# ── 送中 / 泄漏检测 ──────────────────────────────────────────────────
# 判断 Google 是否把当前路径判定为中国大陆：
#   送中时 google.com 会 302 到 www.google.cn 或 www.google.com.hk
google_cn_state() {
    local proxy=$1 hdr code loc
    hdr=$(curl -4 -s -o /dev/null -D - --max-time 12 $proxy https://www.google.com/ 2>/dev/null)
    [ -n "$hdr" ] || { printf 'unreachable|连不上 Google'; return; }
    code=$(printf '%s' "$hdr" | head -1 | awk '{print $2}')
    loc=$(printf '%s' "$hdr" | sed -n 's/^[Ll]ocation: *//p' | tr -d '\r' | head -1)
    case "$loc" in
        *google.cn*|*google.com.hk*)
            printf 'cn|送中！被跳到 %s' "$loc"; return ;;
    esac
    case "$code" in
        200|204) printf 'ok|正常（HTTP %s）' "$code" ;;
        30[0-9]) printf 'redirect|重定向到 %s' "$loc" ;;
        '')      printf 'unreachable|无响应' ;;
        *)       printf 'http%s|HTTP %s' "$code" "$code" ;;
    esac
}

aistudio_code() {
    local proxy=$1
    curl -4 -s -o /dev/null -w '%{http_code}' --max-time 15 $proxy https://aistudio.google.com/ 2>/dev/null
}

f2() { printf '%s' "$1" | cut -d'|' -f2; }

cmd_leak() {
    printf '%s\n' "════════ Google 送中 / 泄漏检测 ════════"
    local d w wstate gip ip4 ip6 hit

    printf '\n[1] 直连路径（临时绕过劫持，看 VPS 自己的 IP 在 Google 眼里属于哪里）\n'
    gip=$(getent ahostsv4 www.google.com 2>/dev/null | awk '{print $1}' | head -1)
    if [ -n "$gip" ] && iptables -t nat -I "$CHAIN_NAT" 1 -d "$gip" -p tcp -j RETURN 2>/dev/null; then
        d=$(google_cn_state "")
        printf '  google.com      : %s\n' "$(f2 "$d")"
        printf '  aistudio 状态码 : %s\n' "$(aistudio_code "")"
        ip4=$(curl -4 -s --max-time 8 https://api.ip.sb/ip 2>/dev/null | tr -d ' \n')
        printf '  出口 IPv4       : %s\n' "${ip4:-未知}"
        iptables -t nat -D "$CHAIN_NAT" -d "$gip" -p tcp -j RETURN 2>/dev/null
    else
        warn "无法临时绕过劫持链做直连测试（缺少 iptables 权限或没解析到 IP）"
    fi

    printf '\n[2] WARP 路径（劫持生效后 Google 实际看到的）\n'
    if [ "$(warp_state)" = "connected" ] && probe_trace 4 >/dev/null 2>&1; then
        w=$(google_cn_state "-x socks5://127.0.0.1:$WARP_PROXY_PORT")
        printf '  google.com      : %s\n' "$(f2 "$w")"
        printf '  aistudio 状态码 : %s\n' "$(aistudio_code "-x socks5://127.0.0.1:$WARP_PROXY_PORT")"
        printf '  WARP 出口 IPv4  : %s\n' "$(probe_trace 4 | cut -d'|' -f1)"
        ip6=$(probe_trace 6 | cut -d'|' -f1)
        printf '  WARP 出口 IPv6  : %s\n' "${ip6:-不可用（被 IPv4-only 屏蔽，正常）}"
    else
        warn "WARP 未连接或 SOCKS5 不通，跳过"
    fi

    printf '\n[3] 实际路径验证（最关键）：Google 到底有没有走 WARP\n'
    iptables -t nat -Z "$CHAIN_NAT" >/dev/null 2>&1
    curl -4 -s -o /dev/null --max-time 12 https://www.google.com/ 2>/dev/null
    curl -4 -s -o /dev/null --max-time 12 https://aistudio.google.com/ 2>/dev/null
    sleep 1
    hit=$(iptables -t nat -L "$CHAIN_NAT" -v -n 2>/dev/null | awk '/REDIRECT|redir ports/ {s += $1} END {print s + 0}')
    printf '  命中劫持规则的包数: %s\n' "$hit"
    if [ "${hit:-0}" -gt 0 ]; then
        ok "Google 流量确实被劫持进 WARP 了，没有漏到直连"
    else
        warn "Google 流量一个包都没命中劫持规则 —— 它走了直连，"
        warn "也就是说 Google 看到的是你 VPS 自己的 IP，改接入点/地区当然怎么改都没用。"
        warn "修复: warp refresh-google && warp restart"
        warn "若列表已全量仍漏，在 /etc/warp-google/config 里设 HIJACK_ALL=1 后 warp restart（全量接管 80/443）"
    fi

    printf '\n[4] 当前拦截方式\n'
    printf '  劫持规则        : %s 条 (HIJACK_ALL=%s)\n' "$(iptables -t nat -S "$CHAIN_NAT" 2>/dev/null | grep -c REDIRECT)" "$HIJACK_ALL"
    printf '  QUIC 阻断       : %s 条\n' "$(iptables -t filter -S "$CHAIN_FLT" 2>/dev/null | grep -c REJECT)"
    printf '  Google v6 黑洞  : %s 条\n' "$(ip -6 route show type blackhole 2>/dev/null | grep -c '/')"

    printf '\n[5] 结论\n'
    wstate=$(printf '%s' "$w" | cut -d'|' -f1)
    if [ "$wstate" = "cn" ]; then
        warn "WARP 出口本身就被 Google 判定为中国大陆 —— 换接入点、换地区都不会有用。"
        warn "出路只有换出口：目标地区的小鸡做落地、或住宅/原生 IP 代理，别再折腾 WARP 了。"
    elif [ "$wstate" = "ok" ] && [ "${hit:-0}" -gt 0 ]; then
        ok "WARP 出口正常，且 Google 流量确实走了 WARP —— IP 这一层是干净的。"
        warn "如果 AI Studio 仍然打不开，问题多半不在 IP 层：先用无痕窗口 + 清 cookie 再试，"
        warn "仍然不行就检查 Google 账号本身的地区设置（账号国家会单独限制部分服务）。"
    elif [ "${hit:-0}" -eq 0 ]; then
        warn "结论：Google 流量没走 WARP（见上面 [3]），先把这一步修好。"
    else
        warn "WARP 路径不可用，先执行 warp recover。"
    fi
    printf '%s\n' "═════════════════════════════════════════"
}

# ── 找一个「不送中」的 WARP 出口并锁定 ───────────────────────────────
# 邻居污染只能换出口。WARP 出口也是共享池，所以必须逐个接入点实测
# 「出口 IP 在 Google 眼里是不是中国大陆」，找到干净的那个再钉住。
cmd_hunt() {
    local want="" deep=0 rounds=1
    while [ $# -gt 0 ]; do
        case "$1" in
            --region) want=$2; shift 2 ;;
            --deep)   deep=1; shift ;;
            --rounds) rounds=$2; shift 2 ;;
            *) shift ;;
        esac
    done

    command -v warp-cli >/dev/null 2>&1 || die "warp-cli 未安装"

    local bases ports
    if [ "$deep" = "1" ]; then
        bases="$DEEP_BASE"; ports="2408 500 1701 4500"
    else
        bases="$DEFAULT_BASE"; ports="$SCAN_PORTS"
    fi

    local b p ep list=""
    for b in $bases; do for p in $ports; do list="$list $b:$p"; done; done
    [ -n "$SCAN_EXTRA" ] && list="$list $SCAN_EXTRA"

    local total=0
    for ep in $list; do total=$((total + 1)); done

    printf '%s\n' "════════ 寻找不送中的 WARP 出口 ════════"
    printf '  接入点候选 : %s 个 × %s 轮\n' "$total" "$rounds"
    printf '  目标地区   : %s\n' "${want:-不限}"
    printf '\n'
    warn "过程中会反复断开重连 WARP，网页 Google 会短暂走直连，属正常"

    local saved_ep="$ENDPOINT" hunt_done=0
    hunt_restore() {
        [ "$hunt_done" = "1" ] && return 0
        hunt_done=1
        printf '\n'
        info "恢复原接入点设置..."
        if [ -n "$saved_ep" ]; then endpoint_set "$saved_ep" >/dev/null 2>&1
        else endpoint_reset >/dev/null 2>&1; fi
        wcli disconnect; sleep 1; wcli connect
        local rst
        rst=$(wait_connected "$CONNECT_TIMEOUT")
        warn "未找到可用出口，已恢复原设置（状态: $rst）"
    }
    trap 'hunt_restore; trap - INT TERM; exit 130' INT TERM

    clear_iptables
    clear_quic_block

    : > "$CONF_DIR/hunt.tsv"
    local r st tr gip cc colo cn cnst found=0
    for r in $(seq 1 "$rounds"); do
        [ "$rounds" -gt 1 ] && printf '%s\n' "── 第 $r 轮 ──"
        for ep in $list; do
            printf '  → %-22s' "$ep"
            if ! endpoint_set "$ep" >/dev/null 2>&1; then
                printf ' 无法设置接入点，终止\n'
                hunt_restore; trap - INT TERM; return 1
            fi
            wcli disconnect
            sleep 1
            wcli connect
            st=$(wait_connected "$CONNECT_TIMEOUT")
            if [ "$st" != "connected" ]; then
                printf ' × 连不上 (%s)\n' "$st"
                printf '%s\t-\t%s\t-\t%s\n' "$ep" "FAIL" "$st" >> "$CONF_DIR/hunt.tsv"
                continue
            fi
            sleep 2
            tr=$(probe_trace 4)
            if [ -z "$tr" ]; then
                printf ' ! 拿不到出口信息\n'
                printf '%s\t-\tNO-TRACE\t-\t-\n' "$ep" >> "$CONF_DIR/hunt.tsv"
                continue
            fi
            gip=$(printf '%s' "$tr" | cut -d'|' -f1)
            cc=$(printf '%s' "$tr" | cut -d'|' -f2)
            colo=$(printf '%s' "$tr" | cut -d'|' -f3)
            cn=$(google_cn_state "-x socks5://127.0.0.1:$WARP_PROXY_PORT")
            cnst=$(printf '%s' "$cn" | cut -d'|' -f1)
            printf ' %-4s %-5s %-15s %s\n' "$cc" "$colo" "$gip" "$(printf '%s' "$cn" | cut -d'|' -f2)"
            printf '%s\t%s\t%s\t%s\t%s\n' "$ep" "$gip" "$cc" "$cnst" "$colo" >> "$CONF_DIR/hunt.tsv"

            if [ "$cnst" != "cn" ] && [ "$cnst" != "unreachable" ]; then
                if [ -z "$want" ] || [ "$cc" = "$want" ]; then
                    found=1
                    break
                fi
            fi
        done
        [ "$found" = "1" ] && break
    done

    printf '\n%s\n' "════════ 结果 ════════"
    awk -F'\t' '{printf "  %-22s %-16s %-4s %-6s %s\n",$1,$2,$3,$5,$4}' "$CONF_DIR/hunt.tsv" | head -40

    if [ "$found" = "1" ]; then
        hunt_done=1
        cfg_set ENDPOINT "$ep"
        [ -n "$want" ] && cfg_set PREFER_REGION "$want"
        printf '\n'
        ok "找到不送中的出口: $ep （出口 IP $gip, 地区 $cc, colo $colo）"
        do_start >/dev/null 2>&1
        ok "已锁定该接入点并重新装好劫持规则"
        printf '\n'
        show_exit
        printf '\n'
        warn "Google 的判定会随时间变化，建议定期复查: warp leak"
        trap - INT TERM
        return 0
    fi

    # 区分两种失败：真的全送中，还是有不送中的但地区不匹配
    local clean_regions
    clean_regions=$(awk -F'\t' '$4!="cn" && $4!="unreachable" && $4!="FAIL" && $4!="NO-TRACE" && $3!="-" {print $3}' \
        "$CONF_DIR/hunt.tsv" 2>/dev/null | sort -u | tr '\n' ' ')
    hunt_restore
    trap - INT TERM
    printf '\n'
    if [ -n "$clean_regions" ]; then
        warn "没有找到地区为 $want 的出口，但下面这些地区的出口是不送中的: $clean_regions"
        warn "换个目标地区再试: warp hunt --region <上面某个地区>"
    else
        warn "试遍了也没有一个不送中的 WARP 出口。"
        warn "说明 Cloudflare WARP 这批出口在 Google 眼里同样是中国区 —— 免费方案到头了："
        warn "  要么换目标地区的小鸡做落地，要么用静态住宅 IP。"
        warn "别再来回换接入点了，换不出来的。"
    fi
    return 1
}

# ── 一键恢复到已知可用状态 ───────────────────────────────────────────
cmd_recover() {
    info "恢复中：重置接入点 → 重连 → 刷新规则"
    endpoint_reset >/dev/null 2>&1
    cfg_set ENDPOINT ""
    cfg_set PREFER_REGION ""
    wcli disconnect >/dev/null 2>&1
    sleep 1
    wcli connect >/dev/null 2>&1
    local st
    st=$(wait_connected "$CONNECT_TIMEOUT")
    printf '  WARP 状态: %s\n' "$st"
    if [ "$st" = "connected" ] && warp_socks_ok; then
        ok "WARP 已恢复，重新安装 Google 劫持规则..."
        do_start
        printf '\n'
        show_exit
        return 0
    fi
    warn "WARP 仍然不通（状态: $st）—— 已保持直连，Google 可以正常打开"
    warn "执行 warp doctor 可以看到具体卡在哪一层"
    clear_iptables
    clear_quic_block
    [ "$BLACKHOLE_GOOGLE_V6" = "1" ] && apply_v6_blackhole
    return 1
}

# ── 逐层体检 ─────────────────────────────────────────────────────────
cmd_doctor() {
    printf '%s\n' "════════ warp-google 体检 ════════"
    printf '\n[1] 组件\n'
    if command -v warp-cli >/dev/null 2>&1; then
        printf '  warp-cli      : %s\n' "$(warp-cli --version 2>/dev/null | head -1 || echo '已安装(版本未知)')"
    else
        printf '  warp-cli      : 未安装\n'
    fi
    printf '  warp-svc      : %s\n' "$(systemctl is-active warp-svc 2>/dev/null || echo 未知)"
    printf '  redsocks      : %s\n' "$(pgrep -x redsocks >/dev/null 2>&1 && echo 运行中 || echo 未运行)"
    printf '  redsocks 配置 : %s\n' "$([ -f /etc/redsocks.conf ] && echo 存在 || echo 缺失)"

    printf '\n[2] WARP 连接\n'
    local st
    st=$(warp_state)
    printf '  warp_state    : %s\n' "$st"
    printf '  原始 status   : %s\n' "$(warp_status_raw | tr '\n' ' ' | cut -c1-100)"
    printf '  配置接入点    : %s\n' "${ENDPOINT:-（自动任播）}"
    endpoint_show | sed 's/^/  dump          : /'

    printf '\n[3] SOCKS5 出口（127.0.0.1:%s）\n' "$WARP_PROXY_PORT"
    local tr
    tr=$(probe_trace 4)
    if [ -n "$tr" ]; then
        printf '  可用          : 是  (%s)\n' "$tr"
    else
        printf '  可用          : 否（连不上或出不了网）\n'
    fi

    printf '\n[4] 透明代理规则\n'
    local n4 nq
    n4=$(iptables -t nat -S "$CHAIN_NAT" 2>/dev/null | grep -c REDIRECT)
    nq=$(iptables -t filter -S "$CHAIN_FLT" 2>/dev/null | grep -c REJECT)
    n4=$((n4 + 0)); nq=$((nq + 0))
    printf '  Google v4 劫持: %s 条\n' "$n4"
    printf '  QUIC 阻断     : %s 条\n' "$nq"
    printf '  IPv6 黑洞     : %s 条\n' "$(ip -6 route show type blackhole 2>/dev/null | grep -c '/')"

    printf '\n[5] Google 送中快检（经 WARP）\n'
    local cs
    cs=$(google_cn_state "-x socks5://127.0.0.1:$WARP_PROXY_PORT")
    printf '  google.com : %s\n' "$(f2 "$cs")"

    printf '\n[6] 结论\n'
    if [ "$n4" -gt 0 ] && [ -z "$tr" ]; then
        warn "劫持规则还在，但 WARP 出不了网 —— 这就是 Google 打不开的直接原因"
        warn "执行：warp recover"
    elif [ "$n4" -gt 0 ]; then
        ok "劫持生效且 WARP 可用"
    else
        ok "当前没有劫持 Google 流量（走直连，网页能打开）"
        if [ "$st" != "connected" ]; then
            warn "WARP 未连接，所以没接管。修好后执行 warp start"
        fi
    fi
    warn "要做完整的送中 / 泄漏分析，执行：warp leak"
    printf '%s\n' "══════════════════════════════════"
}

# ── 分发 ─────────────────────────────────────────────────────────────
case "$1" in
    recover)        cmd_recover ;;
    doctor)         cmd_doctor ;;
    leak|cn)        cmd_leak ;;
    hunt)           shift; cmd_hunt "$@" ;;
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
warp-google —— WARP Google 透明代理运行时 (v2.2.0)

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
  hunt [--region CC] [--deep] [--rounds N]
                                  逐个接入点实测出口是否送中，找到干净的就锁定
  leak                            送中 / 泄漏检测：Google 到底有没有走 WARP
  recover                         一键恢复（重置接入点 + 重连 + 刷新规则）
  doctor                          逐层体检，定位到底卡在哪一层
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
# 1 = WARP 不通时不劫持 Google 流量（保证网页至少能直连打开）
#     强烈建议保持 1，否则 WARP 一挂 Google 就会彻底打不开
REQUIRE_WARP=1
# 1 = 全量接管所有 80/443 出站流量（不再依赖 Google IP 列表）
#     如果你确认 Google 流量有漏网（warp leak 的 [3] 没命中），把它设为 1 最稳
HIJACK_ALL=0
# 等待 WARP 连上的超时秒数
CONNECT_TIMEOUT=25
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
    status|start|stop|restart|probe|scan|region|nat64|endpoint|ipv4|watchdog|refresh-google|recover|doctor|leak|hunt)
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

  出口被送中（邻居污染）时
    warp hunt                    逐个接入点实测，找到「不送中」的出口并锁定
    warp hunt --region JP        同上，但只接受日本出口
    warp hunt --deep --rounds 2  试得更狠（更多接入点 × 多轮）

  地区 / 接入点
    warp scan [--deep]           扫描所有接入点，列出各自落地的地区
    warp region list             查看上一次扫描到哪些地区
    warp region set JP           锁定出口到日本（换地区码即可）
    warp region off              取消地区锁定
    warp endpoint set 162.159.192.1:2408
    warp endpoint reset
    warp nat64 list              用第三方 NAT64 网关换落地国家
    warp nat64 set us

  出问题了（Google 打不开时按这个顺序来）
    warp leak                    送中 / 泄漏检测：Google 到底有没有走 WARP
    warp doctor                  逐层体检，看到底卡在哪一层
    warp recover                 一键恢复：重置接入点 + 重连 + 刷新规则
    warp endpoint reset          只重置接入点（回到 Cloudflare 自动任播）

  其它
    warp ipv4 on|off             强制 IPv4 开关
    warp refresh-google          更新 Google 网段（官方 goog.json）
    warp start | stop            启停透明代理
    warp uninstall               完整卸载
    warp menu                    打开菜单

  说明：WARP 不通时脚本不会劫持 Google 流量，会保持直连，
        所以最坏情况也「只是地区不理想」，不会整个打不开。

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
    info "同步 Google 官方网段（goog.json + 域名解析兜底）..."
    "$ENGINE" refresh-google || warn "拉取失败，继续使用内置精简列表"

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
    # ── 1) 先停：stop 会触发 ExecStop=/usr/local/bin/warp-google stop
    #        （此时引擎还在，能正常清掉 iptables / IPv6 黑洞）
    systemctl stop warp-google-watchdog.timer   >/dev/null 2>&1
    systemctl stop warp-google-watchdog.service >/dev/null 2>&1
    systemctl stop warp-google.service          >/dev/null 2>&1

    # ── 2) 再去掉开机自启（删 multi-user.target.wants / timers.target.wants 软链）
    systemctl disable warp-google-watchdog.timer >/dev/null 2>&1
    systemctl disable warp-google.service        >/dev/null 2>&1

    # ── 3) 删 unit 文件，并显式清掉可能残留的 enable 软链
    #        （systemctl disable 失败时会留下悬空软链，daemon-reload 会报 warning）
    rm -f /etc/systemd/system/warp-google.service \
          /etc/systemd/system/warp-google-watchdog.service \
          /etc/systemd/system/warp-google-watchdog.timer
    rm -f /etc/systemd/system/multi-user.target.wants/warp-google.service \
          /etc/systemd/system/timers.target.wants/warp-google-watchdog.timer
    rm -f /etc/systemd/system/*.wants/warp-google.service \
          /etc/systemd/system/*.wants/warp-google-watchdog.service \
          /etc/systemd/system/*.wants/warp-google-watchdog.timer

    # ── 4) 让 systemd 真正忘掉这几个 unit（含 failed 记录）
    systemctl daemon-reload   >/dev/null 2>&1
    systemctl reset-failed warp-google.service warp-google-watchdog.service \
        warp-google-watchdog.timer >/dev/null 2>&1

    # 兜底：万一 systemd 没接住（容器 / 非 systemd 环境），手动再停一次引擎
    [ -x "$ENGINE" ] && "$ENGINE" stop >/dev/null 2>&1

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
    # ── 校验 systemd 是否真的清干净了
    local left
    left=$(systemctl list-unit-files 'warp-google*' --no-legend 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [ -n "$left" ]; then
        warn "systemd 里仍残留: $left"
        warn "可手动执行: systemctl daemon-reload && systemctl reset-failed $left"
    else
        ok "systemd 单元已清理干净（warp-google.service + watchdog.service + watchdog.timer）"
    fi
    if pgrep -x warp-svc >/dev/null 2>&1 || pgrep -x warp-cli >/dev/null 2>&1; then
        warn "warp-svc 仍在运行，可执行: systemctl stop warp-svc"
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
    printf '  %s2.%s  查看 IP 信息（直连 / WARP 出口）\n' "$GREEN" "$PLAIN"
    printf '  %s3.%s  测试 Google / AI Studio 连通性\n' "$GREEN" "$PLAIN"
    printf '  %s4.%s  扫描接入点，看你的机器能落到哪些地区\n' "$GREEN" "$PLAIN"
    printf '  %s5.%s  锁定出口地区 / 手动指定接入点\n' "$GREEN" "$PLAIN"
    printf '  %s6.%s  强制 IPv4 开关 / NAT64 换落地国家\n' "$GREEN" "$PLAIN"
    printf '  %s7.%s  更新 Google 网段（官方 goog.json）\n' "$GREEN" "$PLAIN"
    printf '  %s8.%s  重启透明代理\n' "$GREEN" "$PLAIN"
    printf '\n'
    printf '  %s9.%s  一键恢复（Google 打不开时先选这个） %s←%s\n' "$GREEN" "$PLAIN" "$YELLOW" "$PLAIN"
    printf '  %s10.%s 找不送中的出口并锁定（邻居污染用这个） %s←%s\n' "$GREEN" "$PLAIN" "$YELLOW" "$PLAIN"
    printf '  %s11.%s 逐层体检诊断\n' "$GREEN" "$PLAIN"
    printf '  %s12.%s 完整卸载\n' "$GREEN" "$PLAIN"
    printf '\n'
    printf '  %s0.%s  退出\n' "$GREEN" "$PLAIN"
    printf '\n'
    hr
    read -rp "  请输入选项 [0-12]: " choice
    printf '\n'
    case "$choice" in
        1) do_install ;;
        2) show_current_ip; [ -x "$ENGINE" ] && "$ENGINE" probe ;;
        3) do_test ;;
        4) if [ -x "$ENGINE" ]; then "$ENGINE" scan; else warn "请先安装"; fi ;;
        5)
            printf '  1) 锁定地区   2) 手动指定接入点   3) 取消锁定\n'
            read -rp "  选择: " sub
            case "$sub" in
                1) read -rp "  目标国家码（如 JP/SG/US）: " cc; [ -x "$ENGINE" ] && "$ENGINE" region set "$cc" ;;
                2) read -rp "  接入点 IP:PORT: " ep; [ -x "$ENGINE" ] && "$ENGINE" endpoint set "$ep" ;;
                3) [ -x "$ENGINE" ] && "$ENGINE" region off ;;
            esac
            ;;
        6)
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
        7) [ -x "$ENGINE" ] && "$ENGINE" refresh-google && "$ENGINE" restart ;;
        8) [ -x "$ENGINE" ] && "$ENGINE" restart ;;
        9) if [ -x "$ENGINE" ]; then "$ENGINE" recover; else warn "请先安装"; fi ;;
        10) if [ -x "$ENGINE" ]; then "$ENGINE" hunt; else warn "请先安装"; fi ;;
        11) if [ -x "$ENGINE" ]; then "$ENGINE" doctor; else warn "请先安装"; fi ;;
        12)
            read -rp "  确认完整卸载? [y/N]: " cu
            if [[ "$cu" =~ ^[Yy]$ ]]; then do_uninstall; else warn "已取消"; fi
            ;;
        0) printf '%s  再见！%s\n\n' "$GREEN" "$PLAIN"; exit 0 ;;
        *) error "无效选项，请输入 0-12" ;;
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
    ip|probe|start|stop|restart|scan|region|nat64|endpoint|ipv4|watchdog|refresh-google|recover|doctor|leak|hunt)
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
