#!/usr/bin/env bash
#
# install_hysteria2.sh - Hysteria2 官方增强版一键部署脚本
# 支持随机端口、密码生成及客户端配置自动生成
# Try `install_hysteria2.sh --help` for usage.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2023 Aperture Internet Laboratory & 增强功能贡献者
#

set -e


###
# SCRIPT CONFIGURATION
###

# 基础配置（继承官方脚本）
SCRIPT_NAME="$(basename "$0")"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/hysteria"
REPO_URL="https://github.com/apernet/hysteria"
HY2_API_BASE_URL="https://api.hy2.io/v1"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 增强功能配置
ENABLE_RANDOM_CONFIG="true"         # 启用随机配置生成
RANDOM_PORT_MIN=1000                # 随机端口最小值
RANDOM_PORT_MAX=65535               # 随机端口最大值
CLIENT_CONFIG_OUTPUT_DIR="$CONFIG_DIR"  # 客户端配置输出目录


###
# AUTO DETECTED GLOBAL VARIABLE
###

PACKAGE_MANAGEMENT_INSTALL="${PACKAGE_MANAGEMENT_INSTALL:-}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-}"
ARCHITECTURE="${ARCHITECTURE:-}"
HYSTERIA_USER="${HYSTERIA_USER:-hysteria}"
HYSTERIA_HOME_DIR="${HYSTERIA_HOME_DIR:-/var/lib/$HYSTERIA_USER}"
SECONTEXT_SYSTEMD_UNIT="${SECONTEXT_SYSTEMD_UNIT:-}"


###
# ARGUMENTS
###

OPERATION=
VERSION=
FORCE=
LOCAL_FILE=
DISABLE_RANDOM_CONFIG=           # 禁用随机配置生成


###
# 工具函数
###

has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

tred() {
  if has_command tput; then
    tput setaf 1
  fi
  echo -n
}

tgreen() {
  if has_command tput; then
    tput setaf 2
  fi
  echo -n
}

tyellow() {
  if has_command tput; then
    tput setaf 3
  fi
  echo -n
}

tblue() {
  if has_command tput; then
    tput setaf 4
  fi
  echo -n
}

tbold() {
  if has_command tput; then
    tput bold
  fi
  echo -n
}

treset() {
  if has_command tput; then
    tput sgr0
  fi
  echo -n
}

note() {
  local _msg="$1"
  echo -e "$SCRIPT_NAME: $(tbold)note: $_msg$(treset)"
}

warning() {
  local _msg="$1"
  echo -e "$SCRIPT_NAME: $(tyellow)warning: $_msg$(treset)"
}

error() {
  local _msg="$1"
  echo -e "$SCRIPT_NAME: $(tred)error: $_msg$(treset)"
}

systemctl() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
    warning "Ignored systemd command: systemctl $@"
    return
  fi
  command systemctl "$@"
}

detect_package_manager() {
  if [[ -n "$PACKAGE_MANAGEMENT_INSTALL" ]]; then
    return 0
  fi

  if has_command apt; then
    apt update
    PACKAGE_MANAGEMENT_INSTALL='apt -y --no-install-recommends install'
    return 0
  fi

  if has_command dnf; then
    PACKAGE_MANAGEMENT_INSTALL='dnf -y install'
    return 0
  fi

  if has_command yum; then
    PACKAGE_MANAGEMENT_INSTALL='yum -y install'
    return 0
  fi

  if has_command zypper; then
    PACKAGE_MANAGEMENT_INSTALL='zypper install -y --no-recommends'
    return 0
  fi

  if has_command pacman; then
    PACKAGE_MANAGEMENT_INSTALL='pacman -Syu --noconfirm'
    return 0
  fi

  return 1
}

install_software() {
  local _package_name="$1"
  if ! detect_package_manager; then
    error "不支持的包管理器，请手动安装: $_package_name"
    exit 65
  fi
  echo "正在安装依赖: $_package_name ..."
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
    echo "完成"
  else
    error "安装依赖失败，请手动安装 $_package_name"
    exit 65
  fi
}

check_permission() {
  if [[ "$UID" -eq '0' ]]; then
    return
  fi
  note "当前用户不是root"
  case "$FORCE_NO_ROOT" in
    '1')
      warning "FORCE_NO_ROOT=1，将以当前用户继续，但可能出现权限不足"
      ;;
    *)
      if ! has_command sudo; then
        error "请使用root用户或安装sudo"
        exit 13
      fi
      note "将使用sudo重新运行脚本"
      local _tmp_script=$(mktemp)
      chmod +x "$_tmp_script"
      if has_command curl; then
        curl -o "$_tmp_script" "$0"
      elif has_command wget; then
        wget -O "$_tmp_script" "$0"
      else
        error "未安装curl或wget，无法重新运行"
        exit 127
      fi
      exec sudo env "$0=$_tmp_script" "$@"
      ;;
  esac
}

check_environment() {
  if [[ -n "$OPERATING_SYSTEM" ]]; then
    warning "已指定OPERATING_SYSTEM=$OPERATING_SYSTEM，跳过系统检测"
  elif [[ "x$(uname)" != "xLinux" ]]; then
    error "仅支持Linux系统"
    exit 95
  else
    OPERATING_SYSTEM=linux
  fi

  if [[ -n "$ARCHITECTURE" ]]; then
    warning "已指定ARCHITECTURE=$ARCHITECTURE，跳过架构检测"
  else
    case "$(uname -m)" in
      'i386' | 'i686') ARCHITECTURE='386' ;;
      'amd64' | 'x86_64') ARCHITECTURE='amd64' ;;
      'armv5tel' | 'armv6l' | 'armv7' | 'armv7l') ARCHITECTURE='arm' ;;
      'armv8' | 'aarch64') ARCHITECTURE='arm64' ;;
      'mips' | 'mipsle' | 'mips64' | 'mips64le') ARCHITECTURE='mipsle' ;;
      's390x') ARCHITECTURE='s390x' ;;
      'loongarch64') ARCHITECTURE='loong64' ;;
      *)
        error "不支持的架构: $(uname -m)"
        exit 8
        ;;
    esac
  fi

  if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
    :
  else
    case "$FORCE_NO_SYSTEMD" in
      '1') warning "FORCE_NO_SYSTEMD=1，将继续假设systemd存在" ;;
      '2') warning "FORCE_NO_SYSTEMD=2，将跳过所有systemd操作" ;;
      *)
        error "仅支持systemd系统"
        exit 95
        ;;
    esac
  fi

  if has_command getenforce; then
    note "检测到SELinux"
    if [[ "x$FORCE_NO_SELINUX" == "x1" ]]; then
      warning "FORCE_NO_SELINUX=1，将跳过SELinux操作"
    elif [[ -z "$SECONTEXT_SYSTEMD_UNIT" ]] && [[ -e "$SYSTEMD_SERVICES_DIR" ]]; then
      SECONTEXT_SYSTEMD_UNIT=$(get_selinux_context "$SYSTEMD_SERVICES_DIR")
    fi
  fi

  if ! has_command curl; then
    install_software curl
  fi
}

get_selinux_context() {
  local _file="$1"
  local _lsres=$(ls -dZ "$_file" 2>/dev/null | head -1)
  local _sectx=''
  case "$(echo "$_lsres" | wc -w)" in
    2) _sectx=$(echo "$_lsres" | cut -d ' ' -f 1) ;;
    5) _sectx=$(echo "$_lsres" | cut -d ' ' -f 4) ;;
  esac
  echo "$_sectx"
}


###
# 增强功能：随机配置生成
###

# 生成随机端口
generate_random_port() {
  if [[ "$DISABLE_RANDOM_CONFIG" == "true" ]]; then
    echo "443"
    return
  fi
  echo $((RANDOM_PORT_MIN + RANDOM % (RANDOM_PORT_MAX - RANDOM_PORT_MIN + 1)))
}

# 生成随机密码
generate_random_password() {
  if [[ "$DISABLE_RANDOM_CONFIG" == "true" ]]; then
    echo "hysteria2_default_password"
    return
  fi
  dd if=/dev/random bs=16 count=1 status=none | base64 | tr -d '+/=' | cut -c1-16
}

# 生成客户端配置URI
generate_client_uri() {
  local server_ip=$(curl -s ifconfig.me)
  local port=$(generate_random_port)
  local auth_pass=$(generate_random_password)
  local obfs_pass=$(generate_random_password)
  echo "hysteria2://${auth_pass}@${server_ip}:${port}/?obfs=salamander&obfs-password=${obfs_pass}&insecure=1"
}

# 输出客户端配置信息
output_client_config() {
  local uri=$(generate_client_uri)
  local server_ip=$(echo $uri | grep -oP '@[^:]+:' | cut -d@ -f2 | cut -d: -f1)
  local port=$(echo $uri | grep -oP ':\d+' | cut -d: -f2)
  local auth_pass=$(echo $uri | grep -oP '@[^:]+:' | cut -d@ -f2 | cut -d: -f1)
  local obfs_pass=$(echo $uri | grep -oP 'obfs-password=[^&]+' | cut -d= -f2)
  
  mkdir -p "$CLIENT_CONFIG_OUTPUT_DIR"
  cat > "$CLIENT_CONFIG_OUTPUT_DIR/client_info.txt" << EOF
==== Hysteria2 客户端配置信息 ====
服务器IP: ${server_ip}
随机端口: ${port}
认证密码: ${auth_pass}
混淆密码: ${obfs_pass}

客户端连接URI:
${uri}

使用说明:
1. 将URI导入Hysteria2客户端（需允许不安全连接）
2. 或手动配置:
   - 服务器地址: ${server_ip}:${port}
   - 认证密码: ${auth_pass}
   - 混淆类型: salamander
   - 混淆密码: ${obfs_pass}
   - 安全设置: 忽略证书验证
EOF
  
  echo -e "\n$(tgreen)客户端配置已保存至: $(tbold)$CLIENT_CONFIG_OUTPUT_DIR/client_info.txt$(treset)"
  echo -e "$(tgreen)URI链接:$(treset) $(tblue)$uri$(treset)"
  
  # 尝试生成二维码
  if has_command qrencode; then
    echo -e "\n$(tgreen)扫描二维码导入配置:$(treset)"
    qrencode -t ansiutf8 "$uri"
  fi
}

# 生成配置文件内容
tpl_etc_hysteria_config_yaml() {
  local port=$(generate_random_port)
  local auth_pass=$(generate_random_password)
  local obfs_pass=$(generate_random_password)
  
  cat << EOF
# Hysteria2 自动配置 (随机生成)
listen: :$port

auth:
  type: password
  password: $auth_pass

obfs:
  type: salamander
  salamander:
    password: $obfs_pass

# 证书配置（建议使用ACME自动申请）
# acme:
#   domains:
#     - your.domain.com
#   email: your@email.com

# 带宽限制 (可选)
# bandwidth:
#   up: 100 mbps
#   down: 100 mbps

# QUIC配置 (可选)
# quic:
#   initialStreamReceiveWindow: 8388608
#   maxStreamReceiveWindow: 8388608
#   initialConnectionReceiveWindow: 20971520
#   maxConnectionReceiveWindow: 20971520
EOF
}


###
# 版本相关函数
###

is_hysteria_installed() {
  [[ -f "$EXECUTABLE_INSTALL_PATH" || -h "$EXECUTABLE_INSTALL_PATH" ]]
}

is_hysteria1_version() {
  local _version="$1"
  [[ "$_version" == v1.* || "$_version" == v0.* ]]
}

get_installed_version() {
  if is_hysteria_installed; then
    if "$EXECUTABLE_INSTALL_PATH" version > /dev/null 2>&1; then
      "$EXECUTABLE_INSTALL_PATH" version | grep '^Version' | grep -o 'v[.0-9]*'
    elif "$EXECUTABLE_INSTALL_PATH" -v > /dev/null 2>&1; then
      "$EXECUTABLE_INSTALL_PATH" -v | cut -d ' ' -f 3
    fi
  fi
}

get_latest_version() {
  if [[ -n "$VERSION" ]]; then
    echo "$VERSION"
    return
  fi

  local _tmpfile=$(mktemp)
  if ! curl -sS "$HY2_API_BASE_URL/update?cver=installscript&plat=${OPERATING_SYSTEM}&arch=${ARCHITECTURE}&chan=release&side=server" -o "$_tmpfile"; then
    error "无法获取最新版本信息，请检查网络"
    exit 11
  fi

  local _latest_version=$(grep -oP '"lver":\s*\K"v.*?"' "$_tmpfile" | head -1)
  _latest_version=${_latest_version#'"'}
  _latest_version=${_latest_version%'"'}

  if [[ -n "$_latest_version" ]]; then
    echo "$_latest_version"
  else
    error "无法解析版本信息，使用默认版本"
    echo "v2.6.1"
  fi

  rm -f "$_tmpfile"
}

check_update() {
  local _installed=$(get_installed_version)
  local _latest=$(get_latest_version)
  
  echo -ne "已安装版本: "
  if [[ -n "$_installed" ]]; then
    echo "$_installed"
  else
    echo "未安装"
  fi

  echo -ne "最新版本: "
  echo "$_latest"

  if [[ -z "$_installed" || $(vercmp "$_installed" "$_latest") -lt 0 ]]; then
    return 0  # 有更新
  fi
  return 1  # 已是最新
}

vercmp() {
  local _lhs=${1#v}
  local _rhs=${2#v}
  local _clhs _crhs _segcmp

  while [[ -n "$_lhs" && -n "$_rhs" ]]; do
    _clhs=${_lhs/.*/}
    _crhs=${_rhs/.*/}

    _clhs=${_clhs//[A-Za-z]*/}
    _crhs=${_crhs//[A-Za-z]*/}

    if [[ "$_clhs" -ne "$_crhs" ]]; then
      echo $((_clhs - _crhs))
      return
    fi

    _lhs=${_lhs#"$_clhs"}
    _lhs=${_lhs#.}
    _rhs=${_rhs#"$_crhs"}
    _rhs=${_rhs#.}
  done

  if [[ -z "$_lhs" && -z "$_rhs" ]]; then
    echo 0
  elif [[ -z "$_lhs" ]]; then
    echo -1
  else
    echo 1
  fi
}


###
# 安装与服务管理
###

perform_install_hysteria
