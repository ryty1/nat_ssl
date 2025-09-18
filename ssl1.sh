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

# 生成随机状态码用于OAuth
generate_state() {
    openssl rand -hex 16 2>/dev/null || echo "$(date +%s)$(shuf -i 1000-9999 -n 1)"
}

# 启动本地HTTP服务器接收回调
start_callback_server() {
    local port="$1"
    local state="$2"
    
    # 创建临时HTML页面
    cat > /tmp/oauth_success.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>授权成功</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin-top: 100px; }
        .success { color: #28a745; font-size: 24px; }
        .info { color: #6c757d; margin-top: 20px; }
    </style>
</head>
<body>
    <div class="success">✅ Cloudflare 授权成功！</div>
    <div class="info">您可以关闭此页面，返回终端继续操作。</div>
    <script>
        // 提取授权码并发送给本地服务器
        const urlParams = new URLSearchParams(window.location.search);
        const code = urlParams.get('code');
        const state = urlParams.get('state');
        if (code) {
            fetch('/callback?code=' + code + '&state=' + state)
                .then(() => console.log('授权码已发送'))
                .catch(err => console.error('发送失败:', err));
        }
    </script>
</body>
</html>
EOF

    # 启动简单的HTTP服务器
    python3 -c "
import http.server
import socketserver
import urllib.parse
import sys
import os

class CallbackHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/callback'):
            # 解析回调参数
            query = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(query)
            
            if 'code' in params and 'state' in params:
                code = params['code'][0]
                state = params['state'][0]
                
                # 保存授权码到文件
                with open('/tmp/cf_oauth_code', 'w') as f:
                    f.write(f'{code}|{state}')
                
                # 返回成功页面
                self.send_response(200)
                self.send_header('Content-type', 'text/html')
                self.end_headers()
                self.wfile.write(b'<html><body><h1>Authorization successful!</h1><p>You can close this window.</p></body></html>')
                
                # 停止服务器
                os._exit(0)
            else:
                self.send_response(400)
                self.end_headers()
        else:
            # 返回成功页面
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            with open('/tmp/oauth_success.html', 'rb') as f:
                self.wfile.write(f.read())

PORT = $port
with socketserver.TCPServer(('', PORT), CallbackHandler) as httpd:
    httpd.serve_forever()
" &
    
    echo $!
}

# 配置Cloudflare API Token (简化版)
configure_cloudflare() {
    log_step "步骤3: 配置Cloudflare DNS API"
    
    read -p "您的域名 (支持子域名，如: blog.example.com): " DOMAIN
    
    # 验证输入
    if [[ -z "$DOMAIN" ]]; then
        log_error "域名不能为空"
        exit 1
    fi
    
    echo
    log_info "🔑 由于NAT VPS限制，我们使用API Token方式进行授权"
    echo
    log_info "📋 获取Cloudflare API Token步骤:"
    echo -e "${CYAN}1. 打开浏览器访问: ${YELLOW}https://dash.cloudflare.com/profile/api-tokens${NC}"
    echo -e "${CYAN}2. 点击 ${YELLOW}'Create Token'${NC}"
    echo -e "${CYAN}3. 选择 ${YELLOW}'Edit zone DNS'${NC} 模板"
    echo -e "${CYAN}4. 在 'Zone Resources' 中选择 ${YELLOW}'Include All zones'${NC}"
    echo -e "${CYAN}5. 点击 ${YELLOW}'Continue to summary'${NC} → ${YELLOW}'Create Token'${NC}"
    echo -e "${CYAN}6. 复制生成的Token${NC}"
    echo
    
    read -p "请输入您的Cloudflare API Token: " CF_TOKEN
    
    # 验证输入
    if [[ -z "$CF_TOKEN" ]]; then
        log_error "API Token不能为空"
        exit 1
    fi
    
    # 验证Token格式 (Cloudflare Token通常40字符长)
    if [[ ${#CF_TOKEN} -lt 20 ]]; then
        log_warn "Token长度似乎不正确，请确认是否完整复制"
    fi
    
    # 保存配置
    cat > /root/.ssl_config << EOF
export DOMAIN="$DOMAIN"
export CF_Token="$CF_TOKEN"
export AUTH_METHOD="api_token"
EOF
    
    log_info "✅ Cloudflare API Token 配置完成"
    log_info "域名: $DOMAIN"
    log_info "Token: ${CF_TOKEN:0:10}..."
}

# 提取主域名
extract_root_domain() {
    local domain="$1"
    # 简单的主域名提取逻辑
    echo "$domain" | sed 's/^[^.]*\.//' | sed 's/^www\.//'
}

# Cloudflare API操作
cloudflare_api() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    # 在实际应用中，这里应该使用真实的访问令牌
    # 现在我们模拟API调用
    if [[ "$method" == "GET" && "$endpoint" =~ /zones ]]; then
        # 模拟返回Zone信息
        echo '{"success":true,"result":[{"id":"mock_zone_id","name":"example.com"}]}'
    elif [[ "$method" == "POST" && "$endpoint" =~ dns_records ]]; then
        # 模拟创建DNS记录
        echo '{"success":true,"result":{"id":"mock_record_id"}}'
    elif [[ "$method" == "DELETE" ]]; then
        # 模拟删除DNS记录
        echo '{"success":true}'
    else
        echo '{"success":false,"errors":[{"message":"API call failed"}]}'
    fi
}

# 获取Zone ID
get_zone_id() {
    local domain="$1"
    local response=$(cloudflare_api "GET" "/zones?name=$domain")
    
    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    else
        return 1
    fi
}

# 添加DNS记录
add_dns_record() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    local content="$4"
    
    local data="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":120}"
    local response=$(cloudflare_api "POST" "/zones/$zone_id/dns_records" "$data")
    
    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    else
        echo "$response" >&2
        return 1
    fi
}

# 删除DNS记录
delete_dns_record() {
    local zone_id="$1"
    local record_id="$2"
    
    local response=$(cloudflare_api "DELETE" "/zones/$zone_id/dns_records/$record_id")
    echo "$response" | grep -q '"success":true'
}

# 获取服务器IPv4地址
get_server_ipv4() {
    local ip=""
    local services=(
        "https://ipv4.icanhazip.com"
        "https://api.ipify.org"
        "https://checkip.amazonaws.com"
        "https://ipinfo.io/ip"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
        if [[ -n "$ip" && "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# 获取服务器IPv6地址
get_server_ipv6() {
    local ip=""
    local services=(
        "https://ipv6.icanhazip.com"
        "https://api6.ipify.org"
        "https://v6.ident.me"
    )
    
    for service in "${services[@]}"; do
        ip=$(curl -s --connect-timeout 5 -6 "$service" 2>/dev/null | tr -d '\n\r ')
        # 简单的IPv6格式验证
        if [[ -n "$ip" && "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" =~ : ]]; then
            echo "$ip"
            return 0
        fi
    done
    
    return 1
}

# 获取服务器IP地址（IPv4和IPv6）
get_server_ips() {
    local ipv4=""
    local ipv6=""
    
    # 获取IPv4
    ipv4=$(get_server_ipv4)
    if [[ $? -eq 0 && -n "$ipv4" ]]; then
        echo "ipv4:$ipv4"
    fi
    
    # 获取IPv6
    ipv6=$(get_server_ipv6)
    if [[ $? -eq 0 && -n "$ipv6" ]]; then
        echo "ipv6:$ipv6"
    fi
}

# 使用真实的Cloudflare API
cloudflare_api_real() {
    local method="$1"
    local endpoint="$2"
    local data="$3"
    
    if [[ -n "$data" ]]; then
        curl -s -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $CF_Token" \
            -H "Content-Type: application/json" \
            -d "$data"
    else
        curl -s -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
            -H "Authorization: Bearer $CF_Token" \
            -H "Content-Type: application/json"
    fi
}

# 获取真实的Zone ID
get_zone_id_real() {
    local domain="$1"
    local response=$(cloudflare_api_real "GET" "/zones?name=$domain")
    
    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    else
        echo "$response" >&2
        return 1
    fi
}

# 添加真实的DNS记录
add_dns_record_real() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    local content="$4"
    
    local data="{\"type\":\"$type\",\"name\":\"$name\",\"content\":\"$content\",\"ttl\":300}"
    local response=$(cloudflare_api_real "POST" "/zones/$zone_id/dns_records" "$data")
    
    if echo "$response" | grep -q '"success":true'; then
        echo "$response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4
    else
        echo "$response" >&2
        return 1
    fi
}

# 检查DNS记录是否存在
check_dns_record_exists() {
    local zone_id="$1"
    local name="$2"
    local type="$3"
    
    local response=$(cloudflare_api_real "GET" "/zones/$zone_id/dns_records?name=$name&type=$type")
    
    if echo "$response" | grep -q '"success":true'; then
        local count=$(echo "$response" | grep -o '"id":"[^"]*"' | wc -l)
        [[ $count -gt 0 ]]
    else
        return 1
    fi
}

# 添加域名解析记录
add_domain_records() {
    log_step "步骤4: 添加域名DNS解析记录"
    
    source /root/.ssl_config
    
    # 获取服务器IP地址（IPv4和IPv6）
    log_info "检测服务器IP地址..."
    local ip_results=($(get_server_ips))
    
    if [[ ${#ip_results[@]} -eq 0 ]]; then
        log_error "无法获取服务器IP地址"
        log_warn "请手动添加DNS记录指向您的服务器IP"
        return 1
    fi
    
    # 解析IP地址
    local ipv4=""
    local ipv6=""
    
    for result in "${ip_results[@]}"; do
        if [[ "$result" =~ ^ipv4: ]]; then
            ipv4="${result#ipv4:}"
            log_info "检测到IPv4地址: $ipv4"
        elif [[ "$result" =~ ^ipv6: ]]; then
            ipv6="${result#ipv6:}"
            log_info "检测到IPv6地址: $ipv6"
        fi
    done
    
    # 提取主域名
    local root_domain=$(extract_root_domain "$DOMAIN")
    log_info "主域名: $root_domain"
    
    # 获取Zone ID
    log_info "获取Cloudflare Zone ID..."
    local zone_id=$(get_zone_id_real "$root_domain")
    
    if [[ -z "$zone_id" ]]; then
        log_error "无法获取域名 $root_domain 的Zone ID"
        log_warn "请确认域名已添加到Cloudflare并且API Token权限正确"
        return 1
    fi
    
    log_info "Zone ID: $zone_id"
    
    # 添加IPv4 A记录
    if [[ -n "$ipv4" ]]; then
        log_info "添加IPv4 A记录: $DOMAIN → $ipv4"
        
        if check_dns_record_exists "$zone_id" "$DOMAIN" "A"; then
            log_warn "IPv4 A记录已存在: $DOMAIN"
        else
            local record_id=$(add_dns_record_real "$zone_id" "$DOMAIN" "A" "$ipv4")
            if [[ -n "$record_id" ]]; then
                log_info "✅ IPv4 A记录添加成功: $DOMAIN → $ipv4"
            else
                log_error "❌ IPv4 A记录添加失败: $DOMAIN"
            fi
        fi
    fi
    
    # 添加IPv6 AAAA记录
    if [[ -n "$ipv6" ]]; then
        log_info "添加IPv6 AAAA记录: $DOMAIN → $ipv6"
        
        if check_dns_record_exists "$zone_id" "$DOMAIN" "AAAA"; then
            log_warn "IPv6 AAAA记录已存在: $DOMAIN"
        else
            local record_id=$(add_dns_record_real "$zone_id" "$DOMAIN" "AAAA" "$ipv6")
            if [[ -n "$record_id" ]]; then
                log_info "✅ IPv6 AAAA记录添加成功: $DOMAIN → $ipv6"
            else
                log_error "❌ IPv6 AAAA记录添加失败: $DOMAIN"
            fi
        fi
    fi
    
    # 检查是否至少添加了一个记录
    if [[ -z "$ipv4" && -z "$ipv6" ]]; then
        log_error "未检测到任何可用的IP地址"
        return 1
    fi
    
    log_info "🌐 DNS解析记录配置完成"
    log_info "⏳ DNS记录可能需要几分钟时间全球生效"
    
    # 显示添加的记录摘要
    echo
    log_info "📋 已添加的DNS记录:"
    [[ -n "$ipv4" ]] && echo -e "  ${GREEN}IPv4 A记录:${NC} $DOMAIN → $ipv4"
    [[ -n "$ipv6" ]] && echo -e "  ${GREEN}IPv6 AAAA记录:${NC} $DOMAIN → $ipv6"
    echo
}

# 申请SSL证书 - 使用Cloudflare DNS API
request_ssl() {
    log_step "步骤5: 申请SSL证书"
    
    source /root/.ssl_config
    source ~/.bashrc
    
    log_info "正在为域名 $DOMAIN 申请SSL证书..."
    log_info "使用Cloudflare DNS API自动验证"
    log_info "API Token: ${CF_Token:0:10}..."
    
    # 设置Cloudflare API环境变量
    export CF_Token="$CF_Token"
    
    # 创建临时日志文件
    local temp_log="/tmp/acme_$(date +%s).log"
    
    # 临时禁用set -e，以便捕获错误
    set +e
    
    # 使用acme.sh的Cloudflare DNS插件自动申请证书
    log_info "🚀 开始自动DNS验证和证书申请..."
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d "$DOMAIN" -d "www.$DOMAIN" --server letsencrypt > "$temp_log" 2>&1
    local exit_code=$?
    
    # 重新启用set -e
    set -e
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "🎉 SSL证书申请成功"
        log_info "✅ DNS记录已自动添加和清理"
        rm -f "$temp_log"
    else
        log_error "❌ SSL证书申请失败 (退出码: $exit_code)"
        echo
        log_error "错误详情:"
        echo -e "${RED}$(cat "$temp_log")${NC}"
        echo
        log_info "完整日志文件: ~/.acme.sh/acme.sh.log"
        log_info "临时日志文件: $temp_log"
        echo
        log_warn "常见问题排查:"
        echo -e "${YELLOW}1. 检查API Token权限是否正确 (需要Zone:DNS:Edit)${NC}"
        echo -e "${YELLOW}2. 确认域名已添加到Cloudflare${NC}"
        echo -e "${YELLOW}3. 验证API Token是否包含正确的域名权限${NC}"
        echo -e "${YELLOW}4. 检查网络连接是否正常${NC}"
        echo -e "${YELLOW}5. 确认域名DNS已指向Cloudflare${NC}"
        exit 1
    fi
}

# 继续处理手动DNS验证的剩余部分（如果需要回退）
handle_manual_dns() {
    local temp_log="$1"
    
    log_warn "需要手动添加DNS记录"
    echo
    log_info "📋 请按照以下步骤添加DNS记录:"
    echo
    
    # 显示需要添加的DNS记录
    echo -e "${CYAN}$(cat "$temp_log" | grep -A 10 "Add the following TXT record")${NC}"
    echo
    
    log_info "🌐 DNS记录添加步骤:"
    echo -e "${YELLOW}1. 登录 Cloudflare Dashboard${NC}"
    echo -e "${YELLOW}2. 选择您的域名${NC}"
    echo -e "${YELLOW}3. 进入 DNS 设置页面${NC}"
    echo -e "${YELLOW}4. 添加上面显示的 TXT 记录${NC}"
    echo -e "${YELLOW}5. 等待DNS记录生效 (通常1-5分钟)${NC}"
    echo
    
    read -p "DNS记录添加完成后，按回车键继续..."
    
    log_info "正在验证DNS记录并完成证书申请..."
    
    # 重新尝试验证和申请
    set +e
    ~/.acme.sh/acme.sh --renew --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "$DOMAIN" > "$temp_log" 2>&1
    local exit_code=$?
    set -e
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "SSL证书申请成功"
        rm -f "$temp_log"
    else
        log_error "SSL证书验证失败 (退出码: $exit_code)"
        echo
        log_error "错误详情:"
        echo -e "${RED}$(cat "$temp_log")${NC}"
        echo
        log_warn "可能的原因:"
        echo -e "${YELLOW}1. DNS记录尚未生效，请等待几分钟后重试${NC}"
        echo -e "${YELLOW}2. DNS记录添加不正确${NC}"
        echo -e "${YELLOW}3. 域名解析问题${NC}"
        exit 1
    fi
}

# 安装证书到指定路径
install_ssl() {
    log_step "步骤6: 安装SSL证书到指定路径"
    
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
    log_step "步骤7: 设置SSL证书自动续期"
    
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
    add_domain_records
    request_ssl
    install_ssl
    setup_auto_renewal
    show_completion
}

# 运行主函数
main "$@"
