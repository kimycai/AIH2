#!/usr/bin/env bash
#
# install_server.sh - hysteria server install script with random config
# Try `install_server.sh --help` for usage.
#
# SPDX-License-Identifier: MIT
# Copyright (c) 2023 Aperture Internet Laboratory & 改进贡献者
#

set -e


###
# SCRIPT CONFIGURATION
###

# 基础配置
SCRIPT_NAME="$(basename "$0")"
EXECUTABLE_INSTALL_PATH="/usr/local/bin/hysteria"
SYSTEMD_SERVICES_DIR="/etc/systemd/system"
CONFIG_DIR="/etc/hysteria"
REPO_URL="https://github.com/apernet/hysteria"
HY2_API_BASE_URL="https://api.hy2.io/v1"
CURL_FLAGS=(-L -f -q --retry 5 --retry-delay 10 --retry-max-time 60)

# 随机配置参数
ENABLE_RANDOM_CONFIG="true"         # 启用随机配置
RANDOM_PORT_MIN=1000                # 随机端口最小值
RANDOM_PORT_MAX=65535               # 随机端口最大值
PASSWORD_LENGTH=16                  # 密码长度
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
DISABLE_RANDOM_CONFIG=           # 禁用随机配置


###
# COMMAND REPLACEMENT & UTILITIES
###

has_command() {
  local _command=$1
  type -P "$_command" > /dev/null 2>&1
}

curl() {
  command curl "${CURL_FLAGS[@]}" "$@"
}

mktemp() {
  command mktemp "$@" "/tmp/hyservinst.XXXXXXXXXX"
}

tput() {
  if has_command tput; then
    command tput "$@"
  fi
}

tred() {
  tput setaf 1
}

tgreen() {
  tput setaf 2
}

tyellow() {
  tput setaf 3
}

tblue() {
  tput setaf 4
}

taoi() {
  tput setaf 6
}

tbold() {
  tput bold
}

treset() {
  tput sgr0
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

has_prefix() {
    local _s="$1"
    local _prefix="$2"
    [[ "x$_s" != "x${_s#"$_prefix"}" ]]
}

systemctl() {
  if [[ "x$FORCE_NO_SYSTEMD" == "x2" ]] || ! has_command systemctl; then
    warning "Ignored systemd command: systemctl $@"
    return
  fi
  command systemctl "$@"
}

chcon() {
  if ! has_command chcon || [[ "x$FORCE_NO_SELINUX" == "x1" ]]; then
    return
  fi
  command chcon "$@"
}

get_systemd_version() {
  if ! has_command systemctl; then
    return
  fi
  command systemctl --version | head -1 | cut -d ' ' -f 2
}

systemd_unit_working_directory() {
  local _systemd_version="$(get_systemd_version || true)"
  if [[ -n "$_systemd_version" && "$_systemd_version" -lt "227" ]]; then
    echo "$HYSTERIA_HOME_DIR"
  else
    echo "~"
  fi
}

get_selinux_context() {
  local _file="$1"
  local _lsres="$(ls -dZ "$_file" | head -1)"
  local _sectx=''
  case "$(echo "$_lsres" | wc -w)" in
    2) _sectx="$(echo "$_lsres" | cut -d ' ' -f 1)" ;;
    5) _sectx="$(echo "$_lsres" | cut -d ' ' -f 4)" ;;
  esac
  [[ "x$_sectx" == "x?" ]] && _sectx=""
  echo "$_sectx"
}

show_argument_error_and_exit() {
  local _error_msg="$1"
  error "$_error_msg"
  echo "Try \"$0 --help\" for usage." >&2
  exit 22
}

install_content() {
  local _install_flags="$1"
  local _content="$2"
  local _destination="$3"
  local _overwrite="$4"
  local _tmpfile="$(mktemp)"
  echo -ne "Install $_destination ... "
  echo "$_content" > "$_tmpfile"
  if [[ -z "$_overwrite" && -e "$_destination" ]]; then
    echo -e "exists"
  elif install "$_install_flags" "$_tmpfile" "$_destination"; then
    echo -e "ok"
  fi
  rm -f "$_tmpfile"
}

remove_file() {
  local _target="$1"
  echo -ne "Remove $_target ... "
  if rm "$_target"; then
    echo -e "ok"
  fi
}

exec_sudo() {
  local _saved_ifs="$IFS"
  IFS=$'\n'
  local _preserved_env=(
    $(env | grep "^PACKAGE_MANAGEMENT_INSTALL=" || true)
    $(env | grep "^OPERATING_SYSTEM=" || true)
    $(env | grep "^ARCHITECTURE=" || true)
    $(env | grep "^HYSTERIA_\w*=" || true)
    $(env | grep "^SECONTEXT_SYSTEMD_UNIT=" || true)
    $(env | grep "^FORCE_\w*=" || true)
  )
  IFS="$_saved_ifs"
  exec sudo env "${_preserved_env[@]}" "$@"
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
  echo "安装依赖: $_package_name ..."
  if $PACKAGE_MANAGEMENT_INSTALL "$_package_name"; then
    echo "完成"
  else
    error "安装依赖失败，请手动安装 $_package_name"
    exit 65
  fi
}

is_user_exists() {
  local _user="$1"
  id "$_user" > /dev/null 2>&1
}

rerun_with_sudo() {
  if ! has_command sudo; then
    return 13
  fi
  local _target_script
  if has_prefix "$0" "/dev/" || has_prefix "$0" "/proc/"; then
    local _tmp_script="$(mktemp)"
    chmod +x "$_tmp_script"
    if has_command curl; then
      curl -o "$_tmp_script" 'https://get.hy2.sh/'
    elif has_command wget; then
      wget -O "$_tmp_script" 'https://get.hy2.sh'
    else
      return 127
    fi
    _target_script="$_tmp_script"
  else
    _target_script="$0"
  fi
  note "将使用sudo重新运行脚本"
  exec_sudo "$_target_script" "${SCRIPT_ARGS[@]}"
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
      if ! rerun_with_sudo; then
        error "请使用root用户或安装sudo"
        exit 13
      fi
      ;;
  esac
}

check_environment_operating_system() {
  if [[ -n "$OPERATING_SYSTEM" ]]; then
    warning "OPERATING_SYSTEM=$OPERATING_SYSTEM，跳过系统检测"
  elif [[ "x$(uname)" == "xLinux" ]]; then
    OPERATING_SYSTEM=linux
  else
    error "仅支持Linux系统"
    note "指定OPERATING_SYSTEM=[linux|darwin|freebsd|windows] 绕过检测"
    exit 95
  fi
}

check_environment_architecture() {
  if [[ -n "$ARCHITECTURE" ]]; then
    warning "ARCHITECTURE=$ARCHITECTURE，跳过架构检测"
  else
    case "$(uname -m)" in
      'i386'|'i686') ARCHITECTURE='386' ;;
      'amd64'|'x86_64') ARCHITECTURE='amd64' ;;
      'armv5tel'|'armv6l'|'armv7'|'armv7l') ARCHITECTURE='arm' ;;
      'armv8'|'aarch64') ARCHITECTURE='arm64' ;;
      'mips'|'mipsle'|'mips64'|'mips64le') ARCHITECTURE='mipsle' ;;
      's390x') ARCHITECTURE='s390x' ;;
      'loongarch64') ARCHITECTURE='loong64' ;;
      *)
        error "不支持的架构: $(uname -m)"
        note "指定ARCHITECTURE=<架构> 绕过检测"
        exit 8
        ;;
    esac
  fi
}

check_environment_systemd() {
  if [[ -d "/run/systemd/system" ]] || grep -q systemd <(ls -l /sbin/init); then
    return
  fi
  case "$FORCE_NO_SYSTEMD" in
    '1') warning "FORCE_NO_SYSTEMD=1，假设systemd存在" ;;
    '2') warning "FORCE_NO_SYSTEMD=2，跳过所有systemd操作" ;;
    *)
      error "仅支持systemd系统"
      note "指定FORCE_NO_SYSTEMD=1/2 绕过检测"
      exit 95
      ;;
  esac
}

check_environment_selinux() {
  if ! has_command getenforce; then
    return
  fi
  note "检测到SELinux"
  if [[ "x$FORCE_NO_SELINUX" == "x1" ]]; then
    warning "FORCE_NO_SELINUX=1，跳过SELinux操作"
    return
  fi
  if [[ -z "$SECONTEXT_SYSTEMD_UNIT" ]] && [[ -e "$SYSTEMD_SERVICES_DIR" ]]; then
    local _sectx="$(get_selinux_context "$SYSTEMD_SERVICES_DIR")"
    [[ -n "$_sectx" ]] && SECONTEXT_SYSTEMD_UNIT="$_sectx"
  fi
}

check_environment_curl() {
  if has_command curl; then
    return
  fi
  install_software curl
}

check_environment_grep() {
  if has_command grep; then
    return
  fi
  install_software grep
}

check_environment() {
  check_environment_operating_system
  check_environment_architecture
  check_environment_systemd
  check_environment_selinux
  check_environment_curl
  check_environment_grep
}

vercmp_segment() {
  local _lhs="$1"
  local _rhs="$2"
  if [[ "x$_lhs" == "x$_rhs" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs" ]]; then
    echo -1
    return
  fi
  if [[ -z "$_rhs" ]]; then
    echo 1
    return
  fi
  local _lhs_num="${_lhs//[A-Za-z]*/}"
  local _rhs_num="${_rhs//[A-Za-z]*/}"
  if [[ "x$_lhs_num" == "x$_rhs_num" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs_num" ]]; then
    echo -1
    return
  fi
  if [[ -z "$_rhs_num" ]]; then
    echo 1
    return
  fi
  local _numcmp=$(($_lhs_num - $_rhs_num))
  if [[ "$_numcmp" -ne 0 ]]; then
    echo "$_numcmp"
    return
  fi
  local _lhs_suffix="${_lhs#"$_lhs_num"}"
  local _rhs_suffix="${_rhs#"$_rhs_num"}"
  if [[ "x$_lhs_suffix" == "x$_rhs_suffix" ]]; then
    echo 0
    return
  fi
  if [[ -z "$_lhs_suffix" ]]; then
    echo 1
    return
  fi
  if [[ -z "$_rhs_suffix" ]]; then
    echo -1
    return
  fi
  [[ "$_lhs_suffix" < "$_rhs_suffix" ]] && echo -1 || echo 1
}

vercmp() {
  local _lhs=${1#v}
  local _rhs=${2#v}
  while [[ -n "$_lhs" && -n "$_rhs" ]]; do
    local _clhs="${_lhs/.*/}"
    local _crhs="${_rhs/.*/}"
    local _segcmp="$(vercmp_segment "$_clhs" "$_crhs")"
    if [[ "$_segcmp" -ne 0 ]]; then
      echo "$_segcmp"
      return
    fi
    _lhs="${_lhs#"$_clhs"}"
    _lhs="${_lhs#.}"
    _rhs="${_rhs#"$_crhs"}"
    _rhs="${_rhs#.}"
  done
  if [[ "x$_lhs" == "x$_rhs" ]]; then
    echo 0
    return
  fi
  [[ -z "$_lhs" ]] && echo -1 || echo 1
}

check_hysteria_user() {
  local _default_hysteria_user="$1"
  if [[ -n "$HYSTERIA_USER" ]]; then
    return
  fi
  if [[ ! -e "$SYSTEMD_SERVICES_DIR/hysteria-server.service" ]]; then
    HYSTERIA_USER="$_default_hysteria_user"
    return
  fi
  HYSTERIA_USER="$(grep -o '^User=\w*' "$SYSTEMD_SERVICES_DIR/hysteria-server.service" | tail -1 | cut -d '=' -f 2 || true)"
  [[ -z "$HYSTERIA_USER" ]] && HYSTERIA_USER="$_default_hysteria_user"
}

check_hysteria_homedir() {
  local _default_hysteria_homedir="$1"
  if [[ -n "$HYSTERIA_HOME_DIR" ]]; then
    return
  fi
  if ! is_user_exists "$HYSTERIA_USER"; then
    HYSTERIA_HOME_DIR="$_default_hysteria_homedir
