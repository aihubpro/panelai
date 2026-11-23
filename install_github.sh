#!/bin/bash
# PanelAI Server 一键安装
# 用法: curl -fsSL https://example.com/install-github.sh | bash
#   或: bash install-github.sh [--version vX.X.X] [--install-dir /path]
set -euo pipefail

# ★ PATH 固化: PVE/精简镜像/su 降权环境下 sbin (/usr/sbin /sbin) 可能不在 PATH,
# 而 iptables 等系统管理二进制装在 sbin —— 缺失会导致误判"未安装"反复重装失败,
# 且面板进程 exec iptables 报 executable file not found (sudo iptables 却可用).
# 前置标准目录, 脚本内检测、自检与 pai infra setup 子进程全部受益.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

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

IMAGE_BASE_URL="${IMAGE_BASE_URL:-https://download.panelai.cn/images}"
VERSION_IMAGE_JSON_URL="${VERSION_IMAGE_JSON_URL:-https://install.panelai.cn/version_image.json}"
PANELAI_IMAGE_VERSION="${PANELAI_IMAGE_VERSION:-}"

# ASR 语音识别模型 (缺失时自动下载到模型目录)
SHERPA_MODEL_URL="${SHERPA_MODEL_URL:-https://download.panelai.cn/model/sherpa-model.tar.gz}"
SHERPA_MODEL_DIR="${SHERPA_MODEL_DIR:-${HOME}/panelai/sherpa-model}"

# 完整镜像名列表 (带 tag, 与 docker-infra.yml 引用一致). 已存在检查按精确 tag 判断,
# 避免服务器残留旧 tag 镜像时误判"已存在"跳过加载, 导致部署时去 Docker Hub 拉取超时.
# OSS 镜像包文件名 = 纯名 (去掉 kukuxiong8/ 前缀与 tag), 如 panelai-postgres.tar.gz
PANELAI_DOCKER_IMAGES=(
    kukuxiong8/panelai-traefik:3.7.8
    kukuxiong8/panelai-redis:7.4.8
    kukuxiong8/panelai-postgres:15.17
    kukuxiong8/panelai-netbird:latest
    kukuxiong8/panelai-netbird-server:latest
    kukuxiong8/panelai-sherpa-asr:zh-en
)

REQUIRED_PORTS=(3000 3001 50051 5432 6379 80 443 8080 9000 13603)
REQUIRED_UDP_PORTS=(3478)

# 端口转发自检参考值 (与面板 portforward 默认值对齐):
# INPUT 放行 = 应用网关端口 + 外部转发端口段; 段起点可被同名环境变量覆盖.
APP_HTTP_PORT="${APP_HTTP_PORT:-3001}"
FORWARD_PORT_START="${FORWARD_PORT_START:-40000}"

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
    step "Step 3/9: 解析安装版本"
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
    step "Step 1/9: 检测系统环境"
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
    ensure_iptables
}

# ─── iptables 依赖 (端口转发必需) ─────────────────────────────────
#
# ★ 为什么必须装:
#   端口转发 (外部端口段 -> 3001) 与 INPUT 放行都依赖 iptables 命令.
#   Debian 12 / Ubuntu 22.04+ 等新发行版**默认不预装 iptables** (内核有 nftables
#   支持但没有命令行工具), 装完 PanelAI 后 `iptables: 未找到命令`,
#   面板启动时的补规则与安装时的 setup 全部静默失败 ->
#   应用打不开 (502/503) 且用户完全看不到任何失败原因.
#
# ★ 为什么装 iptables 而不是只装 nftables:
#   iptables 在新发行版上是 nftables 的兼容前端 (iptables-nft), 行为一致,
#   但脚本与面板代码统一用 iptables 语法, 装 iptables 即可全平台一致.
#
# ★ 覆盖的发行版 (包名统一为 iptables):
#   Debian/Ubuntu/Mint/Raspbian (apt) | RHEL/CentOS/Rocky/Alma/Fedora (dnf/yum)
#   | openSUSE/SLES (zypper) | Arch/Manjaro (pacman) | Alpine (apk)
#
# ★ 覆盖的部署形态 (与发行版无关):
#   物理裸金属 | 云主机 (AWS/Azure/GCP) | 微软 Hyper-V 虚拟机
#   | VMware ESXi 虚拟机 | PVE/Proxmox 虚拟机 (含 LXC 容器) | Docker 容器
#   这些形态的差别只在"谁来执行 iptables", 与本函数无关:
#   - 宿主/裸机: iptables 作用在宿主机 netfilter 上, 正是需要的
#   - 虚拟机: iptables 作用在虚拟机内核上, 外部流量先经虚拟网卡, 同样生效
#   - 面板跑在容器内: 由 portforward.EnsureOnStartup 检测到容器环境后跳过
#     (容器内无法改宿主机 netfilter), 规则由宿主机上的面板进程补齐
# 带完整输出的安装 (失败原因可见), 返回 0 = iptables 可用.
# 供 ensure_iptables (Step 1) 与 setup_network (Step 8 兜底) 复用.
install_iptables_loud() {
    local pkg
    for pkg in iptables nftables; do
        warn "尝试安装 $pkg (详细输出):"
        $PKG_UPDATE || true
        $PKG_INSTALL "$pkg" || warn "  $pkg 安装失败 (退出码 $?), 错误输出见上"
        if command -v iptables &>/dev/null; then
            info "iptables 安装完成 (包: $pkg)"
            return 0
        fi
    done
    return 1
}

ensure_iptables() {
    if command -v iptables &>/dev/null; then
        info "iptables 已就绪"
        return 0
    fi
    info "安装 iptables (端口转发必需)..."
    # 逐个尝试候选包, 每次安装后都实际验证命令是否出现.
    # 不依赖 pkg_install 的返回值 (不同包管理器的退出码语义不完全一致),
    # 以 "command -v iptables" 为唯一判据.
    local pkg
    for pkg in iptables nftables; do
        pkg_install "$pkg" || true
        if command -v iptables &>/dev/null; then
            info "iptables 安装完成 (包: $pkg)"
            return 0
        fi
    done
    # 静默安装全部失败: 带完整输出重试一轮, 暴露真实原因.
    # 常见失败: PVE/精简模板 apt lists 为空, 或 enterprise 源无订阅拖垮 update,
    # 而 pkg_install 把错误输出全部丢弃, 用户只能看到一句 warn 无法定位.
    install_iptables_loud && return 0
    warn "iptables 本次安装失败, Step 8 配置防火墙前还会自动补装一次"
    warn "  若届时仍失败, 请手动执行: apt-get update && apt-get install -y iptables (Debian/Ubuntu) 或 dnf install -y iptables (RHEL/CentOS)"
    warn "  若 sudo iptables 可用而直接 iptables 不存在, 多为 PATH 缺 /usr/sbin: export PATH=/usr/sbin:\$PATH"
}

# ─── Step 5: 部署核心程序 (GitHub Releases) ───────────────────────
download_and_extract() {
    step "Step 5/9: 部署核心程序"
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

# ─── Step 2: 端口检查 ─────────────────────────────────────────────
check_ports() {
    step "Step 2/9: 检查端口占用"
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

# ─── Step 4: Docker & Compose (官方源) ────────────────────────────
check_docker() {
    step "Step 4/9: 安装基础环境"

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
    # plugin 优先 (docker compose 子命令); 系统源无 plugin 再装 docker-compose;
    # 都失败最后落到 GitHub 官方二进制.
    case "$PKG_MGR" in
        apt|dnf|yum) pkg_install docker-compose-plugin 2>/dev/null && return 0 ;;
        zypper|pacman|apk) pkg_install docker-compose 2>/dev/null && return 0 ;;
    esac
    local arch=$(uname -m)
    case "$arch" in x86_64) arch="x86_64" ;; aarch64) arch="aarch64" ;; armv7l) arch="armv7" ;; *) arch="x86_64" ;; esac
    curl -fSL# --connect-timeout 15 --max-time 120 "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}" -o /usr/local/bin/docker-compose || { error "下载失败"; exit 1; }
    chmod +x /usr/local/bin/docker-compose
    info "Docker Compose 安装完成"
}

# ─── Step 6: 初始化基础设施组件 (镜像/GeoDB/模型/灾备) ────────────
fetch_image_version() {
    local json_text=$(curl -fsSL --connect-timeout 10 --max-time 30 "$VERSION_IMAGE_JSON_URL" 2>/dev/null) || { warn "跳过镜像预加载"; return 1; }
    local resolved_version=$(echo "$json_text" | sed -n 's/.*"latest"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [[ -z "$resolved_version" ]] && { warn "镜像版本信息异常"; return 1; }
    PANELAI_IMAGE_VERSION="$resolved_version"
}

setup_netbird_geodb() {
    [[ -z "$PANELAI_IMAGE_VERSION" ]] && return 0
    local tmp_file=$(mktemp /tmp/netbird-geo.XXXXXX.tar.gz)
    curl -fSL# --connect-timeout 15 --max-time 300 "${IMAGE_BASE_URL}/${PANELAI_IMAGE_VERSION}/netbird-geo.tar.gz" -o "$tmp_file" || { rm -f "$tmp_file"; return 0; }
    mkdir -p "$HOME/panelai/netbird-server"
    tar -xzf "$tmp_file" -C "$HOME/panelai/netbird-server" 2>/dev/null || true
    rm -f "$tmp_file"
}

# ─── 数据灾备目录 ─────────────────────────────────────────────────
# 备份包属于「数据实体」, 按交付规范落在 /root/panelai/backup (非 /opt/panelai).
# 提前建好目录并收紧权限 (备份含配置明文与 SSL 私钥).
setup_backup_dir() {
    local backup_root="${PANELAI_BACKUP_ROOT:-/root/panelai/backup}"
    if mkdir -p "$backup_root/panelai" "$backup_root/tmp" 2>/dev/null; then
        chmod 750 "$backup_root" 2>/dev/null || true
        info "数据灾备目录已就绪: ${backup_root}"
    else
        warn "数据灾备目录创建失败: ${backup_root} (备份功能将不可用, 可稍后手动创建并设置 backup.root_path)"
    fi
}

# ─── ASR 模型预下载 (缺失时自动拉取, 失败不阻塞安装) ──────────────
setup_sherpa_model() {
    # 模型已存在则跳过
    if [ -f "$SHERPA_MODEL_DIR/tokens.txt" ]; then
        info "语音识别模型已存在, 跳过下载"
        return 0
    fi
    info "下载语音识别模型..."
    local tmp_file=$(mktemp /tmp/sherpa-model.XXXXXX.tar.gz)
    local tmp_dir=$(mktemp -d)
    if curl -fSL# --connect-timeout 15 --max-time 600 "$SHERPA_MODEL_URL" -o "$tmp_file"; then
        mkdir -p "$SHERPA_MODEL_DIR" "$tmp_dir"
        tar -xzf "$tmp_file" -C "$tmp_dir" 2>/dev/null
        # 兼容嵌套压缩包: 顶层目录下若还有 *.tar.gz (重复打包残留), 二次解压后再定位
        if ! find "$tmp_dir" -name tokens.txt 2>/dev/null | grep -q .; then
            find "$tmp_dir" -name "*.tar.gz" -exec tar -xzf {} -C "$tmp_dir" \; 2>/dev/null || true
            find "$tmp_dir" -name "*.tar.gz" -delete 2>/dev/null
        fi
        # 定位含 tokens.txt 的目录 (兼容包内带顶层目录), 内容拷到模型目录
        local src_dir
        src_dir=$(find "$tmp_dir" -name tokens.txt -exec dirname {} \; 2>/dev/null | head -1)
        if [ -n "$src_dir" ]; then
            cp -a "$src_dir"/. "$SHERPA_MODEL_DIR"/
            rm -rf "$tmp_dir" "$tmp_file"
            info "语音识别模型下载完成"
        else
            rm -rf "$tmp_dir" "$tmp_file"
            warn "模型包内容异常, 请手动放置模型到 $SHERPA_MODEL_DIR"
        fi
    else
        rm -f "$tmp_file"; rm -rf "$tmp_dir"
        warn "语音识别模型下载失败, 引擎暂不可用, 可稍后手动放置到 $SHERPA_MODEL_DIR"
    fi
}

preload_docker_images() {
    [[ -z "$PANELAI_IMAGE_VERSION" ]] && return 0
    local tmp_dir=$(mktemp -d) loaded=0 skipped=0 already=0
    for image in "${PANELAI_DOCKER_IMAGES[@]}"; do
        local short="${image%%:*}"  # 去 tag, 用于取包文件名/显示名
        # 检查本地是否已有该精确 tag 镜像, 有则跳过下载.
        if docker images -q "$image" 2>/dev/null | grep -q .; then
            already=$((already+1))
            info "${short##*/} (已存在, 跳过)"
            continue
        fi
        local img_file="$tmp_dir/${short##*/}.tar.gz"
        info "${short##*/}"
        curl -fSL# --connect-timeout 15 --max-time 600 "${IMAGE_BASE_URL}/${PANELAI_IMAGE_VERSION}/${short##*/}.tar.gz" -o "$img_file" || { skipped=$((skipped+1)); continue; }
        docker load -i "$img_file" >/dev/null 2>&1 && loaded=$((loaded+1)) || skipped=$((skipped+1))
        rm -f "$img_file"
    done
    rm -rf "$tmp_dir"
    local total=$((loaded+already))
    info "镜像: ${total} 就绪 (${loaded} 新增, ${already} 已有, ${skipped} 失败)"
}

# ─── Step 7: 启动基础设施 ─────────────────────────────────────────
start_infra_containers() {
    step "Step 7/9: 启动基础设施"
    cd "$INSTALL_DIR"
    timeout 900 ${CLI_NAME} infra up || { error "infra up 失败"; ${CLI_NAME} infra status 2>/dev/null || true; exit 1; }
    info "基础设施已启动"
}

# ─── Step 8: 网络配置 ─────────────────────────────────────────────
setup_network() {
    step "Step 8/9: 配置防火墙规则"
    cd "$INSTALL_DIR"
    # ★ 最后防线: Step 1 安装全部失败时, 此处自动补装.
    #   此时 Docker 安装阶段已跑通过 apt-get update, 包源必然可用, 补装几乎必成;
    #   仍失败才落到下方自检的 warn (仅提示, 不中断安装).
    if ! command -v iptables &>/dev/null; then
        warn "iptables 缺失, 配置防火墙前自动补装 (最后一次自动尝试)..."
        install_iptables_loud || warn "iptables 补装仍失败, 端口转发将无法配置 (错误原因见上)"
    fi
    ${CLI_NAME} infra setup || { error "infra setup 失败"; exit 1; }

    # ★ 自检: 端口转发必须真的生效, 不能只看命令退出码.
    #   infra setup 内部对单条规则的失败只记警告 (避免单点失败中断安装),
    #   但如果 REDIRECT 或 INPUT 规则整体没加上, 用户后续打开应用会 502/503,
    #   而安装过程却显示成功 —— 这里做一次落地校验, 不通过就明确告知.
    local redirect_ok=0 input_ok=0
    if command -v iptables &>/dev/null; then
        iptables -t nat -S PREROUTING 2>/dev/null | grep -q "REDIRECT" && redirect_ok=1
        iptables -S INPUT 2>/dev/null | grep -qE "dport (${APP_HTTP_PORT}|${FORWARD_PORT_START}:)" && input_ok=1
    fi
    if [[ $redirect_ok -eq 1 && $input_ok -eq 1 ]]; then
        info "端口转发规则已生效"
    else
        warn "端口转发规则未完全生效, 应用可能无法从外部访问 (面板本体访问不受影响)"
        [[ $redirect_ok -eq 0 ]] && warn "  缺少 REDIRECT 规则: iptables -t nat -S PREROUTING | grep REDIRECT"
        [[ $input_ok -eq 0 ]] && warn "  缺少 INPUT 放行规则: iptables -S INPUT | grep -E '${APP_HTTP_PORT}|${FORWARD_PORT_START}'"
        warn "  可在面板菜单执行 'pai infra setup' 重试 (需 root 权限)"
    fi
}

# ─── Step 9: 启动服务 ─────────────────────────────────────────────
start_service() {
    step "Step 9/9: 启动控制面板"
    cd "$INSTALL_DIR"
    if ${CLI_NAME} status 2>/dev/null | grep -q "运行中"; then
        # 进程存活但不等于服务就绪 (HTTP 端口监听是启动最后一步), 继续等待就绪
        info "服务进程已存在, 等待就绪..."
    else
        ${CLI_NAME} start || { error "启动失败"; exit 1; }
    fi

    # 等待 HTTP 端口可访问: 进程拉起 ≠ 可访问, DB 首次初始化/迁移可能耗时较长.
    # curl 连接成功(返回 0)即视为就绪, 不依赖 HTTP 状态码 (首页可能 404/302 均正常).
    local waited=0 max_wait=120
    while (( waited < max_wait )); do
        sleep 2; waited=$((waited+2))
        if curl -s -o /dev/null --connect-timeout 2 --max-time 3 "http://127.0.0.1:3000/" 2>/dev/null; then
            ${CLI_NAME} autostart enable 2>/dev/null && info "服务已启动 (开机自启)" || { info "服务已启动"; warn "开机自启失败, 请手动执行: ${CLI_NAME} autostart enable"; }
            return 0
        fi
        (( waited % 10 == 0 )) && info "等待服务就绪... ${waited}s"
    done
    error "服务启动超时 (HTTP 3000 未就绪)"; ${CLI_NAME} logs 2>/dev/null || true; exit 1
}

# ─── 安装结果 ─────────────────────────────────────────────────────
show_result() {
    local lan_ip=$(get_lan_ip); [[ -z "$lan_ip" ]] && lan_ip="<服务器IP>"
    local pwd=""; [[ -f "${INSTALL_DIR}/storage/initial_admin_password.txt" ]] && pwd=$(cat "${INSTALL_DIR}/storage/initial_admin_password.txt" 2>/dev/null)
    local admin_path=""; [[ -f "${INSTALL_DIR}/storage/initial_admin_path.txt" ]] && admin_path=$(cat "${INSTALL_DIR}/storage/initial_admin_path.txt" 2>/dev/null)
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  PanelAI 部署成功!${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    echo "  用户端:"
    echo "    内网: http://${lan_ip}:3000"
    echo "    公网: http://[公网ip]:3000"
    echo ""
    echo "  管理端:"
    echo "    内网: http://${lan_ip}:3000${admin_path}"
    echo "    公网: http://[公网ip]:3000${admin_path}"
    echo "  管理员:   admin"
    [[ -n "$pwd" ]] && echo "  密  码:   $pwd" || echo "  密  码:   请查看 ${INSTALL_DIR}/storage/initial_admin_password.txt"
    echo ""
    echo "  防火墙放行: TCP 80,443,3000,3001,50051,9000,13603,40000-50000 / UDP 3478"
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
    step "Step 6/9: 初始化基础设施组件"
    fetch_image_version
    setup_netbird_geodb
    preload_docker_images
    setup_sherpa_model
    setup_backup_dir
    start_infra_containers
    setup_network
    start_service
    show_result
}

main "$@"
