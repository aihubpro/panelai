#!/bin/bash
# PanelAI Server 一键安装
# 用法: curl -fsSL https://example.com/install-github.sh | bash
#   或: bash install-github.sh [--version vX.X.X] [--install-dir /path]
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; }
step()   { echo -e "\n${CYAN}>>> $*${NC}"; }
prompt() { echo -e "${BLUE}[INPUT]${NC} $*"; }

[[ -t 0 ]] && TTY_INPUT="/dev/stdin" || TTY_INPUT="/dev/tty"

ask_yn() {
    local msg="$1" default="${2:-y}" result
    while true; do
        read -r -e -p "$(echo -e "${BLUE}[INPUT]${NC} ${msg} [y/n] (默认:${default}): ")" result <"$TTY_INPUT" || true
        result="${result:-$default}"
        result=$(echo "$result" | tr '[:upper:]' '[:lower:]')
        case "$result" in y|yes) return 0 ;; n|no) return 1 ;; *) echo "  请输入 y 或 n" ;; esac
    done
}

ask_choice() {
    local msg="$1" max="$2" result
    while true; do
        read -r -e -p "$(echo -e "${BLUE}[INPUT]${NC} ${msg}")" result <"$TTY_INPUT" || true
        if [[ "$result" =~ ^[0-9]+$ ]] && (( result >= 1 && result <= max )); then echo "$result"; return 0; fi
        echo "  请输入 1-${max} 之间的数字"
    done
}

# ─── 配置 ─────────────────────────────────────────────────────────
INSTALL_DIR="${INSTALL_DIR:-/opt/panelai}"
CLI_NAME="pai"; CLI_PATH="${INSTALL_DIR}/${CLI_NAME}"
PANELAI_VERSION="${PANELAI_VERSION:-latest}"
DOWNLOAD_URL="${DOWNLOAD_URL:-}"
PACKAGE_PREFIX="${PACKAGE_PREFIX:-Panelai}"

GITHUB_RELEASE_URL="${GITHUB_RELEASE_URL:-https://github.com/aihubpro/panelai/releases}"

REQUIRED_PORTS=(3000 3001 50051 5432 6379 80 443 8080 13603)
REQUIRED_UDP_PORTS=(3478)

usage() {
    echo "用法: bash install-github.sh [--version VER] [--download-url URL] [--install-dir DIR] [--help]"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      PANELAI_VERSION="$2"; shift 2 ;;
        --download-url) DOWNLOAD_URL="$2"; shift 2 ;;
        --install-dir)  INSTALL_DIR="$2";  shift 2 ;;
        --help)         usage ;;
        *) error "未知参数: $1"; usage ;;
    esac
done

# ─── 跨发行版抽象层 ───────────────────────────────────────────────
PKG_MGR=""; PKG_UPDATE=""; PKG_INSTALL=""; INIT_SYSTEM=""

detect_pkg_manager() {
    if command -v apt-get &>/dev/null; then
        PKG_MGR="apt"; PKG_UPDATE="apt-get update -qq"; PKG_INSTALL="apt-get install -y -qq"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"; PKG_UPDATE="dnf check-update -q || true"; PKG_INSTALL="dnf install -y -q"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"; PKG_UPDATE="yum check-update -q || true"; PKG_INSTALL="yum install -y -q"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"; PKG_UPDATE="zypper refresh -q"; PKG_INSTALL="zypper install -y -q"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"; PKG_UPDATE="pacman -Sy --noconfirm"; PKG_INSTALL="pacman -S --noconfirm"
    elif command -v apk &>/dev/null; then
        PKG_MGR="apk"; PKG_UPDATE="apk update -q"; PKG_INSTALL="apk add -q"
    fi
}

pkg_install() { $PKG_UPDATE 2>/dev/null || true; $PKG_INSTALL $* &>/dev/null; }
svc_start()  { case "$INIT_SYSTEM" in systemd) systemctl start "$1" 2>/dev/null || true ;; openrc) rc-service "$1" start 2>/dev/null || true ;; *) service "$1" start 2>/dev/null || true ;; esac; }
svc_enable() { case "$INIT_SYSTEM" in systemd) systemctl enable "$1" 2>/dev/null || true ;; openrc) rc-update add "$1" 2>/dev/null || true ;; *) true ;; esac; }
detect_init_system() {
    if command -v systemctl &>/dev/null; then INIT_SYSTEM="systemd"
    elif [[ -x /sbin/openrc-run || -x /usr/sbin/rc-service ]]; then INIT_SYSTEM="openrc"
    else INIT_SYSTEM="sysv"; fi
}

# ─── 工具 ─────────────────────────────────────────────────────────
port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then ss -tlnp "sport = :$port" 2>/dev/null | grep -q ":$port"
    elif command -v netstat &>/dev/null; then netstat -tlnp 2>/dev/null | grep -q ":$port "
    else (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && return 0 || return 1; fi
}

port_udp_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then ss -ulnp "sport = :$port" 2>/dev/null | grep -q ":$port"
    elif command -v netstat &>/dev/null; then netstat -ulnp 2>/dev/null | grep -q ":$port "
    else return 1; fi
}

get_port_process() {
    local port="$1"
    if command -v ss &>/dev/null; then ss -tlnp "sport = :$port" 2>/dev/null | awk 'NR>1 {for(i=7;i<=NF;i++) printf "%s ", $i}'
    elif command -v netstat &>/dev/null; then netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $7}'; fi
}

get_port_pid() {
    local port="$1"
    if command -v ss &>/dev/null; then ss -tlnp "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | head -1
    elif command -v netstat &>/dev/null; then netstat -tlnp 2>/dev/null | grep ":$port " | awk '{print $NF}' | cut -d/ -f1 | head -1; fi
}

get_docker_container_by_port() {
    local port="$1" containers cid
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        containers=$(docker ps -q 2>/dev/null)
        for cid in $containers; do
            if docker port "$cid" 2>/dev/null | grep -q ":$port$"; then
                docker inspect --format '{{.Name}}' "$cid" 2>/dev/null | sed 's|^/||'; return 0
            fi
        done
    fi
}

get_lan_ip() {
    if command -v ip &>/dev/null; then ip -4 addr show 2>/dev/null | grep -o 'inet [0-9.]*' | awk '{print $2}' | grep -v '127.0.0.1' | head -1
    elif command -v hostname &>/dev/null; then hostname -I 2>/dev/null | awk '{print $1}'; fi
}

extract_tar() { tar --overwrite -xzf "$1" -C "$2" 2>/dev/null || tar -xzf "$1" -C "$2"; }

# ─── 版本解析 (GitHub Releases) ────────────────────────────────────
detect_os()   { local n=$(uname -s|tr '[:upper:]' '[:lower:]'); case "$n" in linux|darwin) echo "$n" ;; *) echo "$n" ;; esac; }
detect_arch() { local a=$(uname -m); case "$a" in x86_64|amd64) echo "x86" ;; aarch64|arm64) echo "arm64" ;; *) echo "$a" ;; esac; }

resolve_version() {
    local os=$(detect_os) arch=$(detect_arch)
    info "OS: ${os}  架构: ${arch}"
    [[ -n "$DOWNLOAD_URL" ]] && return 0

    if [[ "$PANELAI_VERSION" == "latest" ]]; then
        DOWNLOAD_URL="${GITHUB_RELEASE_URL}/latest/download/${PACKAGE_PREFIX}_${os}_${arch}.tar.gz"
        info "版本: latest (GitHub 自动定位)"
    else
        DOWNLOAD_URL="${GITHUB_RELEASE_URL}/download/${PANELAI_VERSION}/${PACKAGE_PREFIX}_${PANELAI_VERSION}_${arch}.tar.gz"
        info "版本: $PANELAI_VERSION"
    fi
}

# ─── Step 1: 系统检测 ─────────────────────────────────────────────
check_system() {
    step "Step 1/6: 检测系统环境"
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then exec sudo bash "$0" "$@"; fi
        error "请使用 root 执行: sudo bash install-github.sh"; exit 1
    fi
    [[ ! -f /etc/os-release ]] && { error "不支持的操作系统"; exit 1; }
    . /etc/os-release
    info "系统: $PRETTY_NAME | $(uname -m)"
    detect_pkg_manager; detect_init_system
    [[ -z "$PKG_MGR" ]] && { error "未检测到支持的包管理器"; exit 1; }
    info "包管理器: $PKG_MGR"
    for tool in curl tar gzip; do command -v "$tool" &>/dev/null || pkg_install "$tool"; done
}

# ─── Step 2: 下载安装包 (GitHub) ──────────────────────────────────
download_and_extract() {
    step "Step 3/6: 部署核心程序"
    local tmp_dir pkg_file
    tmp_dir=$(mktemp -d); pkg_file="$tmp_dir/release.tar.gz"
    trap 'rm -rf "${tmp_dir:-}"' EXIT

    curl -fSL# --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$pkg_file" || { error "下载失败"; exit 1; }
    [[ ! -s "$pkg_file" ]] && { error "安装包为空"; exit 1; }

    local is_reinstall=false backup_dir=""
    if [[ -f "$CLI_PATH" ]]; then
        is_reinstall=true; "$CLI_PATH" stop 2>/dev/null || true; sleep 1
        backup_dir=$(mktemp -d)
        for item in configs/config.yaml configs/setting configs/payment configs/netbird certs storage; do
            local src="$INSTALL_DIR/$item"
            [[ -e "$src" ]] && { mkdir -p "$(dirname "$backup_dir/$item")"; cp -a "$src" "$backup_dir/$item" 2>/dev/null || true; }
        done
    fi

    mkdir -p "$INSTALL_DIR"; extract_tar "$pkg_file" "$INSTALL_DIR"

    if $is_reinstall && [[ -n "$backup_dir" ]]; then
        for item in configs/config.yaml configs/setting configs/payment configs/netbird certs storage; do
            local src="$backup_dir/$item" dst="$INSTALL_DIR/$item"
            [[ -e "$src" ]] && { rm -rf "$dst" 2>/dev/null || true; mkdir -p "$(dirname "$dst")"; cp -a "$src" "$dst" 2>/dev/null || true; }
        done
        rm -rf "$backup_dir"
    fi

    [[ -f "$CLI_PATH" ]] && chmod +x "$CLI_PATH" || { error "安装包不完整"; exit 1; }
    mkdir -p "$INSTALL_DIR/storage/logs" "$INSTALL_DIR/storage/temp"
    [[ ! -f "$INSTALL_DIR/configs/config.yaml" && -f "$INSTALL_DIR/configs/config.yaml.example" ]] && cp "$INSTALL_DIR/configs/config.yaml.example" "$INSTALL_DIR/configs/config.yaml"
    setup_cli_path
}

# ─── 注册 CLI 到 PATH ─────────────────────────────────────────────
setup_cli_path() {
    local output
    output=$("$CLI_PATH" help 2>&1) || true
    if echo "$output" | grep -qi "GLIBC\|libc.so\|version.*not found"; then
        error "${CLI_NAME} 与当前系统 glibc 不兼容"; ldd --version 2>&1 | head -1; exit 1
    fi
    if ! echo "$output" | grep -qi "panelai\|用法\|Usage\|help\|serve\|infra"; then
        error "${CLI_NAME} 二进制异常, 安装包可能损坏"; exit 1
    fi

    local wrapper="/usr/local/bin/${CLI_NAME}"
    cat > "$wrapper" <<EOF
#!/bin/bash
cd "$INSTALL_DIR" && exec "$CLI_PATH" "\$@"
EOF
    chmod +x "$wrapper"
    [[ -d /usr/bin ]] && ln -sf "$CLI_PATH" "/usr/bin/${CLI_NAME}" 2>/dev/null || true
    export PATH="/usr/local/bin:$PATH"
    mkdir -p /etc/profile.d
    echo 'export PATH="/usr/local/bin:$PATH"' > /etc/profile.d/panelai.sh; chmod 644 /etc/profile.d/panelai.sh

    if command -v "$CLI_NAME" &>/dev/null; then
        info "${CLI_NAME} 命令已就绪"
    else
        warn "${CLI_NAME} 请执行: export PATH=\"/usr/local/bin:\$PATH\""
    fi
}

# ─── Step 3: 端口检查 ─────────────────────────────────────────────
check_ports() {
    if ! command -v ss &>/dev/null && ! command -v netstat &>/dev/null; then
        case "$PKG_MGR" in apt) pkg_install iproute2 ;; yum|dnf) pkg_install iproute ;; zypper|pacman|apk) pkg_install iproute2 ;; esac
    fi

    local occupied=()
    for port in "${REQUIRED_PORTS[@]}"; do
        if port_in_use "$port"; then warn "端口 $port 已占用"; occupied+=("$port"); fi
    done
    for port in "${REQUIRED_UDP_PORTS[@]}"; do
        if port_udp_in_use "$port"; then warn "UDP 端口 $port 已占用"; occupied+=("${port}/udp"); fi
    done

    [[ ${#occupied[@]} -eq 0 ]] && return 0

    echo ""
    warn "端口被占用: ${occupied[*]}"
    echo "  [1] 自动停止占用进程  [2] 退出"
    local choice=$(ask_choice "请选择 [1-2]: " 2)

    case "$choice" in
        1)
            for port in "${occupied[@]}"; do
                local pn="${port%/udp}"
                local cname=$(get_docker_container_by_port "$pn")
                if [[ -n "$cname" ]]; then docker stop "$cname" 2>/dev/null || true; docker rm -f "$cname" 2>/dev/null || true; continue; fi
                local pid=$(get_port_pid "$pn")
                [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; sleep 1; kill -9 "$pid" 2>/dev/null || true; }
            done
            for port in "${occupied[@]}"; do
                local pn="${port%/udp}"
                if [[ "$port" == */udp ]]; then port_udp_in_use "$pn" && { error "端口 $port 仍被占用"; exit 1; }
                else port_in_use "$pn" && { error "端口 $port 仍被占用"; exit 1; }; fi
            done
            info "端口冲突已解决"
            ;;
        *) error "安装已取消"; exit 1 ;;
    esac
}

# ─── Step 4: Docker & Compose (系统源) ────────────────────────────
check_docker() {
    step "Step 2/6: 安装基础环境"

    if command -v docker &>/dev/null; then
        info "Docker 已安装 ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ','))"
        docker info &>/dev/null || { svc_start docker; sleep 2; docker info &>/dev/null || { error "Docker 启动失败"; exit 1; }; }
    else
        ask_yn "安装 Docker?" "y" || { error "Docker 是必需品, 安装已取消"; exit 1; }
        install_docker
    fi

    if docker compose version &>/dev/null 2>&1; then
        info "Docker Compose 已安装 ($(docker compose version 2>/dev/null | awk '{print $NF}'))"
    elif command -v docker-compose &>/dev/null; then
        info "Docker Compose 已安装 ($(docker-compose --version 2>/dev/null | awk '{print $NF}'))"
    else
        install_docker_compose
    fi
}

install_docker() {
    info "正在安装 Docker (官方源)..."
    curl -fsSL https://get.docker.com | bash || { error "Docker 安装失败"; exit 1; }
    svc_start docker; svc_enable docker; sleep 2
    docker info &>/dev/null || { error "Docker 启动失败"; exit 1; }
    info "Docker 安装完成"
}

install_docker_compose() {
    case "$PKG_MGR" in
        apt) apt-get install -y docker-compose 2>/dev/null && return 0 ;;
        dnf) $PKG_INSTALL docker-compose 2>/dev/null && return 0 ;;
        yum) $PKG_INSTALL docker-compose 2>/dev/null && return 0 ;;
        zypper) $PKG_INSTALL docker-compose 2>/dev/null && return 0 ;;
        pacman) $PKG_INSTALL docker-compose 2>/dev/null && return 0 ;;
        apk) $PKG_INSTALL docker-compose 2>/dev/null && return 0 ;;
    esac
    local arch=$(uname -m)
    case "$arch" in x86_64) arch="x86_64" ;; aarch64) arch="aarch64" ;; armv7l) arch="armv7" ;; *) arch="x86_64" ;; esac
    curl -fSL# --connect-timeout 15 --max-time 120 "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" -o /usr/local/bin/docker-compose || { error "下载失败"; exit 1; }
    chmod +x /usr/local/bin/docker-compose
    info "Docker Compose 安装完成"
}

# ─── Step 5: 启动基础设施 ─────────────────────────────────────────
start_infra_containers() {
    step "Step 4/6: 启动基础设施"
    cd "$INSTALL_DIR"
    info "拉取镜像并启动容器 (首次从 Docker Hub 拉取, 请耐心等待)..."
    timeout 900 ${CLI_NAME} infra up || { error "infra up 失败"; ${CLI_NAME} infra status 2>/dev/null || true; exit 1; }
    info "基础设施已启动"
}

# ─── Step 6: 网络配置 ─────────────────────────────────────────────
setup_network() {
    step "Step 5/6: 配置防火墙规则"
    cd "$INSTALL_DIR"
    ${CLI_NAME} infra setup || { error "infra setup 失败"; exit 1; }
}

# ─── Step 7: 启动服务 ─────────────────────────────────────────────
start_service() {
    step "Step 6/6: 启动控制面板"
    cd "$INSTALL_DIR"
    ${CLI_NAME} status 2>/dev/null | grep -q "运行中" && { info "服务已在运行中"; return 0; }
    ${CLI_NAME} start || { error "启动失败"; exit 1; }

    local waited=0 max_wait=30
    while (( waited < max_wait )); do
        sleep 2; waited=$((waited+2))
        timeout 5 ${CLI_NAME} status 2>/dev/null | grep -q "运行中" && {
            ${CLI_NAME} autostart enable 2>/dev/null && info "服务已启动 (开机自启)" || { info "服务已启动"; warn "开机自启失败, 请手动执行: ${CLI_NAME} autostart enable"; }
            return 0
        }
    done
    error "启动超时"; ${CLI_NAME} logs 2>/dev/null || true; exit 1
}

# ─── 安装结果 ─────────────────────────────────────────────────────
show_result() {
    local lan_ip=$(get_lan_ip); [[ -z "$lan_ip" ]] && lan_ip="<服务器IP>"
    local pwd=""; [[ -f "${INSTALL_DIR}/storage/initial_admin_password.txt" ]] && pwd=$(cat "${INSTALL_DIR}/storage/initial_admin_password.txt" 2>/dev/null)
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  PanelAI 部署成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  访问地址: http://${lan_ip}:3000"
    echo "  管理员:   admin"
    [[ -n "$pwd" ]] && echo "  密  码:   $pwd" || echo "  密  码:   请查看 ${INSTALL_DIR}/storage/initial_admin_password.txt"
    echo ""
    echo "  防火墙放行: TCP 80,443,3000,3001,50051,13603,40000-50000 / UDP 3478,40000-50000"
    echo "  管理命令:   pai"
    echo ""
}

# ─── 主流程 ───────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}  PanelAI Server 一键安装${NC}"
    echo -e "${CYAN}========================================${NC}"
    echo ""

    trap 'echo ""; warn "安装中断, 清理中..."; ${CLI_PATH} stop 2>/dev/null || true; cd "$INSTALL_DIR" 2>/dev/null && docker compose -f configs/docker-infra.yml down 2>/dev/null || true; exit 130' INT TERM

    warn "建议在纯净系统上部署, 避免端口冲突"
    echo ""
    if [[ -f "$CLI_PATH" ]]; then
        ask_yn "检测到已有安装, 是否覆盖?" "y" || { info "已取消"; exit 0; }
    else
        ask_yn "确认开始安装?" "y" || { info "已取消"; exit 0; }
    fi

    check_system "$@"
    check_ports
    resolve_version
    check_docker
    download_and_extract
    start_infra_containers
    setup_network
    start_service
    show_result
}

main "$@"
