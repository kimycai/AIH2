#!/bin/bash

# Hysteria2 Linux服务端一键部署脚本
# 支持Debian/Ubuntu/CentOS/RHEL等系统
# 随机生成端口和密码，并自动生成客户端配置

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查是否为root用户
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}错误: 请使用root用户运行此脚本!${NC}"
    exit 1
fi

# 定义变量
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="${CONFIG_DIR}/config.yaml"
SERVICE_FILE="/etc/systemd/system/hysteria.service"
LOG_DIR="/var/log/hysteria"
BINARY_PATH="/usr/local/bin/hysteria"

# 系统检测
if [ -f /etc/debian_version ]; then
    SYSTEM="debian"
    PACKAGE_MANAGER="apt-get"
elif [ -f /etc/redhat-release ]; then
    SYSTEM="centos"
    PACKAGE_MANAGER="yum"
else
    echo -e "${RED}不支持的系统!${NC}"
    exit 1
fi

# 获取最新版本号
get_latest_version() {
    echo -e "${YELLOW}正在获取Hysteria2最新版本...${NC}"
    VERSION=$(curl -s "https://api.github.com/repos/apernet/hysteria/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
    if [ -z "$VERSION" ]; then
        echo -e "${RED}获取版本号失败，使用默认版本...${NC}"
        VERSION="v2.5.0"
    fi
    echo -e "${GREEN}最新版本: ${VERSION}${NC}"
    echo "$VERSION"
}

# 随机生成4位数字端口（1000-9999范围）
generate_random_port() {
    echo $((1000 + RANDOM % 9000))
}

# 安装必要工具
install_tools() {
    echo -e "${YELLOW}正在安装必要工具...${NC}"
    if [ "$SYSTEM" = "debian" ]; then
        $PACKAGE_MANAGER update
        $PACKAGE_MANAGER install -y wget curl tar systemd openssl jq qrencode
    else
        $PACKAGE_MANAGER install -y wget curl tar systemd openssl jq qrencode
    fi
}

# 下载Hysteria2
download_hysteria() {
    VERSION=$(get_latest_version)
    echo -e "${YELLOW}正在下载Hysteria2 ${VERSION}...${NC}"
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        armv7l)
            ARCH="armv7"
            ;;
        *)
            echo -e "${RED}不支持的架构: ${ARCH}${NC}"
            exit 1
            ;;
    esac
    
    # 下载二进制文件
    DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/${VERSION}/hysteria-linux-${ARCH}-avx"
    TEMP_FILE="/tmp/hysteria-linux-${ARCH}-avx"
    
    if ! wget -q -O "$TEMP_FILE" "$DOWNLOAD_URL"; then
        echo -e "${RED}下载失败: ${DOWNLOAD_URL}${NC}"
        exit 1
    fi
    
    # 赋予执行权限并移动到指定位置
    chmod +x "$TEMP_FILE"
    mv "$TEMP_FILE" "$BINARY_PATH"
    
    if [ ! -f "$BINARY_PATH" ]; then
        echo -e "${RED}Hysteria2安装失败!${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Hysteria2安装成功!${NC}"
}

# 配置Hysteria2
configure_hysteria() {
    echo -e "${YELLOW}正在配置Hysteria2...${NC}"
    
    # 创建配置目录
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$LOG_DIR"
    
    # 生成随机密码
    AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '+/=' | cut -c1-16)
    OBFS_PASSWORD=$(openssl rand -base64 16 | tr -d '+/=' | cut -c1-16)
    
    # 生成随机端口
    SERVER_PORT=$(generate_random_port)
    
    # 获取服务器公网IP
    SERVER_IP=$(curl -s ifconfig.me)
    
    # 生成自签名证书
    echo -e "${YELLOW}正在生成自签名证书...${NC}"
    CERT_DIR="${CONFIG_DIR}/certs"
    mkdir -p "$CERT_DIR"
    
    openssl req -x509 -newkey rsa:4096 -keyout "$CERT_DIR/private.key" -out "$CERT_DIR/cert.crt" -days 3650 -nodes -subj "/CN=$SERVER_IP" -addext "subjectAltName = IP:$SERVER_IP"
    
    if [ ! -f "$CERT_DIR/cert.crt" ] || [ ! -f "$CERT_DIR/private.key" ]; then
        echo -e "${RED}自签名证书生成失败!${NC}"
        exit 1
    fi
    
    # 创建配置文件（使用随机参数）
    cat > "$CONFIG_FILE" << EOF
# Hysteria2 服务器配置
listen: :$SERVER_PORT
tls:
  cert: $CERT_DIR/cert.crt
  key: $CERT_DIR/private.key
auth:
  type: password
  password: $AUTH_PASSWORD
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD
bandwidth:
  up: 100 mbps
  down: 100 mbps
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
EOF
    
    echo -e "${GREEN}Hysteria2配置文件创建成功!${NC}"
    echo -e "${YELLOW}随机生成的认证密码: ${AUTH_PASSWORD}${NC}"
    echo -e "${YELLOW}随机生成的混淆密码: ${OBFS_PASSWORD}${NC}"
    echo -e "${YELLOW}随机生成的服务端口: ${SERVER_PORT}${NC}"
    echo -e "${YELLOW}自签名证书路径: ${CERT_DIR}/cert.crt${NC}"
    
    # 生成客户端配置URI
    CLIENT_URI="hysteria2://${AUTH_PASSWORD}@${SERVER_IP}:${SERVER_PORT}/?obfs=salamander&obfs-password=${OBFS_PASSWORD}&insecure=1"
    echo -e "${YELLOW}客户端配置URI: ${CLIENT_URI}${NC}"
    
    # 保存配置信息到文件
    cat > "${CONFIG_DIR}/client_info.txt" << EOF
Hysteria2 客户端配置信息

服务器IP: ${SERVER_IP}
认证密码: ${AUTH_PASSWORD}
混淆密码: ${OBFS_PASSWORD}
服务端口: ${SERVER_PORT}

客户端URI: ${CLIENT_URI}

使用说明:
1. 将此URI导入到Hysteria2客户端应用中
2. 或使用以下命令启动客户端:
   hysteria-linux-amd64 client -c <(echo '{"server":"${SERVER_IP}:${SERVER_PORT}","auth":"${AUTH_PASSWORD}","obfs":"salamander","obfsPassword":"${OBFS_PASSWORD}","insecure":true,"socks5":{"listen":"127.0.0.1:1080"},"http":{"listen":"127.0.0.1:8080"}}')
EOF
    
    echo -e "${GREEN}客户端配置信息已保存到: ${CONFIG_DIR}/client_info.txt${NC}"
}

# 创建systemd服务
create_service() {
    echo -e "${YELLOW}正在创建systemd服务...${NC}"
    
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Hysteria2 Server
After=network.target

[Service]
ExecStart=$BINARY_PATH server -c $CONFIG_FILE
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=append:$LOG_DIR/server.log
StandardError=append:$LOG_DIR/error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # 重载systemd
    systemctl daemon-reload
    
    # 启用服务
    systemctl enable hysteria.service
    
    echo -e "${GREEN}systemd服务创建成功!${NC}"
}

# 启动Hysteria2
start_hysteria() {
    echo -e "${YELLOW}正在启动Hysteria2服务...${NC}"
    
    systemctl start hysteria.service
    
    # 检查服务状态
    if ! systemctl is-active --quiet hysteria.service; then
        echo -e "${RED}Hysteria2服务启动失败!${NC}"
        echo -e "${YELLOW}查看服务状态: systemctl status hysteria${NC}"
        echo -e "${YELLOW}查看服务日志: journalctl -u hysteria -f${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}Hysteria2服务启动成功!${NC}"
}

# 配置防火墙
configure_firewall() {
    echo -e "${YELLOW}正在配置防火墙...${NC}"
    
    if [ "$SYSTEM" = "debian" ]; then
        if command -v ufw &>/dev/null; then
            ufw allow $SERVER_PORT/udp
            ufw allow $SERVER_PORT/tcp
            echo -e "${GREEN}ufw防火墙配置成功!${NC}"
        else
            echo -e "${YELLOW}未找到ufw，跳过防火墙配置...${NC}"
            echo -e "${YELLOW}请手动开放${SERVER_PORT}端口(UDP和TCP)${NC}"
        fi
    else
        if command -v firewalld &>/dev/null; then
            firewall-cmd --permanent --add-port=$SERVER_PORT/udp
            firewall-cmd --permanent --add-port=$SERVER_PORT/tcp
            firewall-cmd --reload
            echo -e "${GREEN}firewalld防火墙配置成功!${NC}"
        else
            echo -e "${YELLOW}未找到firewalld，跳过防火墙配置...${NC}"
            echo -e "${YELLOW}请手动开放${SERVER_PORT}端口(UDP和TCP)${NC}"
        fi
    fi
}

# 显示配置信息和客户端二维码
show_config_info() {
    echo -e "\n${GREEN}==== Hysteria2 部署完成 ====${NC}"
    echo -e "${YELLOW}服务器IP: ${SERVER_IP}${NC}"
    echo -e "${YELLOW}随机生成的认证密码: ${AUTH_PASSWORD}${NC}"
    echo -e "${YELLOW}随机生成的混淆密码: ${OBFS_PASSWORD}${NC}"
    echo -e "${YELLOW}随机生成的服务端口: ${SERVER_PORT}${NC}"
    echo -e "${YELLOW}自签名证书路径: ${CONFIG_DIR}/certs/cert.crt${NC}"
    echo -e "${YELLOW}配置文件: ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}服务控制:${NC}"
    echo -e "  启动: ${GREEN}systemctl start hysteria${NC}"
    echo -e "  停止: ${RED}systemctl stop hysteria${NC}"
    echo -e "  重启: ${YELLOW}systemctl restart hysteria${NC}"
    echo -e "  状态: ${YELLOW}systemctl status hysteria${NC}"
    
    # 生成客户端配置URI
    CLIENT_URI="hysteria2://${AUTH_PASSWORD}@${SERVER_IP}:${SERVER_PORT}/?obfs=salamander&obfs-password=${OBFS_PASSWORD}&insecure=1"
    
    echo -e "\n${GREEN}==== 客户端配置信息 ====${NC}"
    echo -e "${YELLOW}客户端URI:${NC}"
    echo -e "${GREEN}${CLIENT_URI}${NC}"
    
    # 生成二维码
    echo -e "\n${YELLOW}扫描下方二维码导入配置:${NC}"
    qrencode -t ansiutf8 "$CLIENT_URI"
    
    echo -e "\n${YELLOW}客户端配置信息已保存到: ${CONFIG_DIR}/client_info.txt${NC}"
    echo -e "${YELLOW}你可以将此文件分享给其他需要连接的用户${NC}"
    
    echo -e "\n${YELLOW}注意:${NC}"
    echo -e "  1. 由于使用自签名证书，客户端连接时需要添加 &insecure=1 参数"
    echo -e "  2. 请妥善保管你的认证密码和混淆密码"
    echo -e "  3. 如需修改配置，请编辑 ${CONFIG_FILE} 并重启服务"
}

# 主函数
main() {
    echo -e "${GREEN}==== Hysteria2 一键部署脚本（含客户端配置） ====${NC}"
    
    install_tools
    download_hysteria
    configure_hysteria
    create_service
    start_hysteria
    configure_firewall
    show_config_info
}

# 执行主函数
main    
