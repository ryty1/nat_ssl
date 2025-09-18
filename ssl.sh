#!/bin/bash

# NAT VPS SSL证书申请和博客部署一键脚本
# 适用于无80端口的VPS服务器

set -e

# 颜色定义 - 渐变色系
RED='\033[0;31m'
LIGHT_RED='\033[1;31m'
ORANGE='\033[0;33m'
YELLOW='\033[1;33m'
LIGHT_GREEN='\033[1;32m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
LIGHT_CYAN='\033[1;36m'
BLUE='\033[0;34m'
LIGHT_BLUE='\033[1;34m'
PURPLE='\033[0;35m'
LIGHT_PURPLE='\033[1;35m'
WHITE='\033[1;37m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "${BLUE}[STEP]${NC} $1"
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        log_info "请使用: sudo $0"
        exit 1
    fi
}

# 检测系统类型
detect_system() {
    if [[ -f /etc/debian_version ]]; then
        SYSTEM="debian"
        PACKAGE_MANAGER="apt"
    elif [[ -f /etc/redhat-release ]]; then
        SYSTEM="centos"
        PACKAGE_MANAGER="yum"
    else
        log_error "不支持的系统类型"
        exit 1
    fi
    log_info "检测到系统类型: $SYSTEM"
}

# 检查并安装必要工具
install_dependencies() {
    log_step "步骤1: 检查并安装必要工具"
    
    # 需要安装的包列表
    local missing_packages=()
    
    # 检查必要的命令是否存在
    if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
        missing_packages+=("cron")
    fi
    
    if ! command -v curl >/dev/null 2>&1; then
        missing_packages+=("curl")
    fi
    
    if ! command -v wget >/dev/null 2>&1; then
        missing_packages+=("wget")
    fi
    
    # 如果没有缺失的包，跳过安装
    if [[ ${#missing_packages[@]} -eq 0 ]]; then
        log_info "所有依赖已安装，跳过安装步骤"
        return
    fi
    
    log_info "检测到缺失的依赖: ${missing_packages[*]}"
    
    if [[ $SYSTEM == "debian" ]]; then
        log_info "更新软件包列表..."
        DEBIAN_FRONTEND=noninteractive apt update >/dev/null 2>&1
        
        log_info "安装缺失的依赖..."
        DEBIAN_FRONTEND=noninteractive apt install "${missing_packages[@]}" -y >/dev/null 2>&1
        
        # 确保cron服务运行
        if [[ " ${missing_packages[*]} " =~ " cron " ]]; then
            systemctl enable cron >/dev/null 2>&1
            systemctl start cron >/dev/null 2>&1
        fi
        
    elif [[ $SYSTEM == "centos" ]]; then
        log_info "安装缺失的依赖..."
        # CentOS中cron包名是cronie
        local centos_packages=()
        for pkg in "${missing_packages[@]}"; do
            if [[ "$pkg" == "cron" ]]; then
                centos_packages+=("cronie")
            else
                centos_packages+=("$pkg")
            fi
        done
        
        yum install "${centos_packages[@]}" -y >/dev/null 2>&1
        
        # 确保crond服务运行
        if [[ " ${missing_packages[*]} " =~ " cron " ]]; then
            systemctl enable crond >/dev/null 2>&1
            systemctl start crond >/dev/null 2>&1
        fi
    fi
    
    log_info "依赖安装完成"
}

# 安装acme.sh
install_acme() {
    log_step "步骤2: 安装acme.sh SSL证书工具"
    
    if [[ ! -d ~/.acme.sh ]]; then
        curl -s https://get.acme.sh | sh >/dev/null 2>&1
        source ~/.bashrc
        log_info "acme.sh 安装完成"
    else
        log_info "acme.sh 已存在，跳过安装"
    fi
}

# 配置Cloudflare API
configure_cloudflare() {
    log_step "步骤3: 配置Cloudflare DNS API"
    
    echo -e "${YELLOW}请输入您的Cloudflare配置信息:${NC}"
    
    read -p "Cloudflare 邮箱: " CF_EMAIL
    read -p "Cloudflare Global API Key: " CF_KEY
    read -p "您的域名 (例如: example.com): " DOMAIN
    
    # 验证输入
    if [[ -z "$CF_EMAIL" || -z "$CF_KEY" || -z "$DOMAIN" ]]; then
        log_error "配置信息不能为空"
        exit 1
    fi
    
    # 导出环境变量
    export CF_Email="$CF_EMAIL"
    export CF_Key="$CF_KEY"
    
    # 保存到配置文件
    cat > /root/.ssl_config << EOF
export CF_Email="$CF_EMAIL"
export CF_Key="$CF_KEY"
export DOMAIN="$DOMAIN"
EOF
    
    log_info "Cloudflare API 配置完成"
}

# 申请SSL证书
request_ssl() {
    log_step "步骤4: 申请SSL证书"
    
    source /root/.ssl_config
    source ~/.bashrc
    
    log_info "正在为域名 $DOMAIN 申请SSL证书..."
    
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "www.$DOMAIN" --server letsencrypt >/dev/null 2>&1
    
    if [[ $? -eq 0 ]]; then
        log_info "SSL证书申请成功"
    else
        log_error "SSL证书申请失败，请检查域名和API配置"
        log_info "详细错误信息请查看: ~/.acme.sh/acme.sh.log"
        exit 1
    fi
}

# 安装证书到指定路径
install_ssl() {
    log_step "步骤5: 安装SSL证书到指定路径"
    
    source /root/.ssl_config
    
    # 创建证书目录
    mkdir -p /root/cert
    
    # 安装证书
    ~/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
        --key-file /root/cert/private.key \
        --fullchain-file /root/cert/fullchain.crt >/dev/null 2>&1
    
    # 设置证书文件权限
    chmod 600 /root/cert/private.key
    chmod 644 /root/cert/fullchain.crt
    
    log_info "SSL证书安装完成"
    
    # 验证证书文件
    if [[ -f /root/cert/private.key && -f /root/cert/fullchain.crt ]]; then
        log_info "证书文件验证成功"
    else
        log_error "证书文件验证失败"
        exit 1
    fi
}

# 设置自动续期
setup_auto_renewal() {
    log_step "步骤6: 设置SSL证书自动续期"
    
    # acme.sh 默认会自动添加cron任务，这里确认一下
    crontab -l 2>/dev/null | grep -q "acme.sh" || {
        log_warn "未找到acme.sh的cron任务，手动添加..."
        (crontab -l 2>/dev/null; echo "0 0 * * * ~/.acme.sh/acme.sh --cron --home ~/.acme.sh > /dev/null 2>&1") | crontab - 2>/dev/null
    }
    
    log_info "SSL证书自动续期已设置完成"
}

# 显示完成信息
show_completion() {
    source /root/.ssl_config
    
    echo
    log_info "🎉 SSL证书申请和配置完成！"
    echo
    echo -e "${GREEN}域名信息:${NC}"
    echo -e "  主域名: https://$DOMAIN"
    echo -e "  www域名: https://www.$DOMAIN"
    echo
    echo -e "${GREEN}证书文件位置:${NC}"
    echo -e "  私钥: /root/cert/private.key"
    echo -e "  证书: /root/cert/fullchain.crt"
    echo

    echo -e "${YELLOW}注意事项:${NC}"
    echo -e "  1. 证书将在3个月后自动续期"
    echo -e "  2. 请确保域名已正确解析到Cloudflare"
    echo -e "  3. 可以将您的博客文件上传到 /var/www/$DOMAIN 目录"
    echo
}

# 显示SerokVip标识
show_logo() {
    # 获取终端宽度，默认80
    local term_width=$(tput cols 2>/dev/null || echo 80)
    # SerokVip图案实际宽度约为56字符
    local logo_width=56
    # 计算居中所需的左边距
    local left_padding=$(( (term_width - logo_width) / 2 ))
    # 确保左边距不小于0
    [[ $left_padding -lt 0 ]] && left_padding=0
    
    # 生成空格字符串
    local spaces=$(printf "%*s" $left_padding "")
    
    # SerokVip标识 - 自适应居中，无边框
    printf '%s\033[0;31m   ____\033[1;31m                 \033[0;33m_    \033[1;33m__     \033[1;32m___\033[0m\n' "$spaces"
    printf '%s\033[0;31m  / ___|\033[1;31m  ___ _ __ ___  \033[0;33m| | __\033[1;33m\\ \\   \033[1;32m/ (_)_ __\033[0m\n' "$spaces"
    printf '%s\033[0;31m  \\___ \\\033[1;31m / _ \\ '\''__/ _ \\ \033[0;33m| |/ / \033[1;33m\\ \\ / /\033[1;32m| | '\''_ \\\033[0m\n' "$spaces"
    printf '%s\033[0;31m   ___) \033[1;31m|  __/ | | (_) |\033[0;33m|   <   \033[1;33m\\ V / \033[1;32m| | |_) |\033[0m\n' "$spaces"
    printf '%s\033[0;31m  |____/ \033[1;31m\\___|_|  \\___/ \033[0;33m|_|\\_\\   \033[1;33m\\_/  \033[1;32m|_| .__/\033[0m\n' "$spaces"
    printf '%s\033[0;32m                                        |_|\033[0m\n' "$spaces"
    echo
    
    # 脚本标题 - 精确对齐边框
    # 直接使用固定宽度，确保边框与内容完全匹配
    local title_padding=$(( (term_width - 62) / 2 ))
    [[ $title_padding -lt 0 ]] && title_padding=0
    local title_spaces=$(printf "%*s" $title_padding "")
    
    # 固定边框 - 与内容行完全匹配
    local top_border="+----------------------------------------------------------+"
    local bottom_border="+----------------------------------------------------------+"
    
    printf '%s\033[1;36m%s\033[0m\n' "$title_spaces" "$top_border"
    printf '%s\033[1;36m|\033[1;37m            NAT VPS SSL证书申请一键脚本                   \033[1;36m|\033[0m\n' "$title_spaces"
    printf '%s\033[1;36m|\033[1;37m            适用于无80端口的VPS服务器                     \033[1;36m|\033[0m\n' "$title_spaces"
    printf '%s\033[1;36m%s\033[0m\n' "$title_spaces" "$bottom_border"
    echo
}

# 主函数
main() {
    show_logo
    check_root
    detect_system
    install_dependencies
    install_acme
    configure_cloudflare
    request_ssl
    install_ssl
    setup_auto_renewal
    show_completion
}

# 运行主函数
main "$@"
