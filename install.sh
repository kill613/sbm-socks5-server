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

# 以下程序包由build_installer.py生成；可审阅app/中的明文源码。
sbm_os
sbm_fresh_guard
work=$(mktemp -d /root/sbm-sk5-install-XXXXXX)
chmod 700 "$work"
echo "本次安装记录目录：$work"
sbm_dependencies "$work"
exec 9>/run/lock/sbm-sk5-installer.lock
flock -n 9 || { echo '已有本服务安装器正在运行，请稍后重试。' >&2; exit 1; }
sbm_fresh_guard
cat <<'SBM_SK5_PAYLOAD' | base64 --decode >"$work/source.tar.gz"
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
SBM_SK5_PAYLOAD
python3 -c 'import hashlib,sys; assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==sys.argv[2],"内置程序包校验失败"' "$work/source.tar.gz" 2830018e8f12099871fc0c218e884fdac059c7e22fddbf01b1afc741f5cdadb8
tar -xzf "$work/source.tar.gz" -C "$work"
python3 "$work/app/sk5_install.py" --work "$work"
