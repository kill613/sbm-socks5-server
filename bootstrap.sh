#!/usr/bin/env bash
# 只为本次安装使用临时发行版源；不覆盖系统原有源文件。
set -Eeuo pipefail
umask 077
export PYTHONIOENCODING=UTF-8

sbm_os() {
  [[ $EUID -eq 0 ]] || { echo '请以root运行安装器。' >&2; return 1; }
  [[ -r /etc/os-release && -d /run/systemd/system ]] || { echo '需要使用systemd的Linux系统。' >&2; return 1; }
  . /etc/os-release
  SBM_OS="${ID:-}"; SBM_VERSION="${VERSION_ID:-}"; SBM_MAJOR="${SBM_VERSION%%.*}"
  case "$SBM_OS:$SBM_MAJOR" in
    debian:12|debian:13|ubuntu:22|ubuntu:24|ubuntu:26) SBM_FAMILY=apt;;
    centos:7|centos:9|rocky:8|rocky:9|rocky:10|almalinux:8|almalinux:9|almalinux:10) SBM_FAMILY=rpm;;
    *) echo "暂不支持此发行版：${PRETTY_NAME:-unknown}；未修改系统。" >&2; return 1;;
  esac
  echo "已识别系统：${PRETTY_NAME:-$SBM_OS}（$(uname -m)）"
}

sbm_fresh_guard() {
  local path
  local -a paths=(/etc/sbm-sk5 /usr/local/libexec/sbm-sk5 /usr/local/bin/sk5 /etc/profile.d/sbm-sk5.sh /etc/systemd/system/sbm-sk5.service /etc/systemd/system/sbm-sk5-firewall.service)
  for path in "${paths[@]}"; do
    [[ ! -e "$path" && ! -L "$path" ]] || { echo "检测到已有安装或路径占用：$path；拒绝覆盖。" >&2; return 1; }
  done
}

sbm_apt_sources() {
  local scheme="$1" file="$2" code="${VERSION_CODENAME:-}"
  [[ "$code" =~ ^[a-z]+$ ]] || { echo '无法识别发行版代号。' >&2; return 1; }
  if [[ "$SBM_OS" == debian ]]; then
    cat >"$file" <<EOF
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/debian $code main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/debian $code-updates main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/debian-security $code-security main contrib non-free non-free-firmware
EOF
  else
    local mirror=ubuntu
    [[ "$(dpkg --print-architecture)" == amd64 ]] || mirror=ubuntu-ports
    cat >"$file" <<EOF
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/$mirror $code main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/$mirror $code-updates main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://$SBM_REPO_HOST/$mirror $code-security main restricted universe multiverse
EOF
  fi
}

sbm_rpm_sources() {
  local scheme="$1" directory="$2" base key variant
  mkdir -p "$directory" || return
  : > "$directory/sbm.repo" || return
  if [[ "$SBM_OS:$SBM_MAJOR" == centos:7 ]]; then
    base="$scheme://vault.centos.org/7.9.2009"
    key=/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
    [[ -r "$key" ]] || { echo '缺少系统自带CentOS7签名密钥，停止。' >&2; return 1; }
    for variant in os updates extras; do
      cat >>"$directory/sbm.repo" <<EOF
[sbm-$variant]
name=SBM CentOS7 $variant
baseurl=$base/$variant/\$basearch/
enabled=1
gpgcheck=1
gpgkey=file://$key
EOF
    done
    echo 'CentOS7使用官方历史归档源；该系统已停止官方维护，安装兼容性将单独标记。'
  fi
}

sbm_dependencies_once() {
  local work="$1" scheme=https
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || scheme=http
  # Old EL7 CA bundles may exist but cannot validate current HTTPS chains.
  # Bootstrap only signed CA packages over HTTP, then require HTTPS again.
  [[ "$SBM_OS:$SBM_MAJOR" != centos:7 ]] || scheme=http
  echo '使用临时软件源安装依赖；保留原系统源与软件包签名校验。'
  export NEEDRESTART_MODE=l
  if [[ "$SBM_FAMILY" == apt ]]; then
    local file="$work/official.list"
    local -a apt=(apt-get -o "Dir::Etc::sourcelist=$file" -o Dir::Etc::sourceparts=- -o Acquire::Retries=1 -o Acquire::http::Timeout=20 -o APT::Update::Error-Mode=any -o Acquire::http::Pipeline-Depth=0)
    sbm_apt_sources "$scheme" "$file" || return
    "${apt[@]}" update || return
    if [[ "$scheme" == http ]]; then
      DEBIAN_FRONTEND=noninteractive "${apt[@]}" install -y ca-certificates || return
      sbm_apt_sources https "$file" || return; "${apt[@]}" update || return
    fi
    local -a packages=(ca-certificates curl tar gzip iproute2 python3 util-linux openssl iptables procps)
    packages+=(gcc make libc6-dev)
    DEBIAN_FRONTEND=noninteractive "${apt[@]}" install -y "${packages[@]}" || return
  else
    local directory="$work/repos" manager=yum
    command -v dnf >/dev/null && manager=dnf
    sbm_rpm_sources "$scheme" "$directory" || return
    local -a rpm=("$manager" --setopt=timeout=20 --setopt=retries=1 --setopt="reposdir=$directory" --disablerepo='*' --enablerepo='sbm-*' -y)
    "${rpm[@]}" install ca-certificates || return
    if [[ "$scheme" == http ]]; then
      rm -f -- "$directory/sbm.repo"; sbm_rpm_sources https "$directory" || return
    fi
    "${rpm[@]}" install curl tar gzip iproute python3 util-linux openssl gcc make glibc-devel iptables procps-ng || return
  fi
  python3 -c 'import sys; assert sys.version_info >= (3,6), "需要Python3.6或更新版本"'
}

# 使用发行版官方源或系统已配置的签名源。
sbm_dependencies() {
  local SBM_REPO_HOST=deb.debian.org
  if [[ "$SBM_OS" == ubuntu ]]; then
    SBM_REPO_HOST=archive.ubuntu.com
    [[ "$(dpkg --print-architecture)" == amd64 ]] || SBM_REPO_HOST=ports.ubuntu.com
  fi
  if [[ "$SBM_FAMILY" == rpm && "$SBM_OS:$SBM_MAJOR" != centos:7 ]]; then
    local sbm_manager=yum
    command -v dnf >/dev/null && sbm_manager=dnf
    echo '尝试系统已配置的发行版软件源，强制保留软件包签名验证。'
    "$sbm_manager" --setopt=timeout=20 --setopt=retries=1 --setopt=gpgcheck=1 -y install ca-certificates curl tar gzip iproute python3 util-linux openssl gcc make glibc-devel iptables procps-ng || return
    python3 -c 'import sys; assert sys.version_info >= (3,6)' || return
    return 0
  fi
  echo "尝试发行版官方源：$SBM_REPO_HOST"
  sbm_dependencies_once "$@"
}
