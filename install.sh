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
python3 -c 'import hashlib,sys; assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==sys.argv[2],"内置程序包校验失败"' "$work/source.tar.gz" 6e6dc65e4de164adbe9d930451acda4d94e541c4aa67e377a6ad8e7a0a3af7dd
tar -xzf "$work/source.tar.gz" -C "$work"
python3 "$work/app/sk5_install.py" --work "$work"
