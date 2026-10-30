#!/usr/bin/env bash
# 只为本次安装使用独立清华源；不覆盖系统原有源文件。
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
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/debian $code main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/debian $code-updates main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/debian-security $code-security main contrib non-free non-free-firmware
EOF
  else
    local mirror=ubuntu
    [[ "$(dpkg --print-architecture)" == amd64 ]] || mirror=ubuntu-ports
    cat >"$file" <<EOF
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/$mirror $code main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/$mirror $code-updates main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://mirrors.tuna.tsinghua.edu.cn/$mirror $code-security main restricted universe multiverse
EOF
  fi
}

sbm_rpm_sources() {
  local scheme="$1" directory="$2" base key variant
  mkdir -p "$directory"
  if [[ "$SBM_OS:$SBM_MAJOR" == centos:7 ]]; then
    base="$scheme://mirrors.tuna.tsinghua.edu.cn/centos-vault/7.9.2009"
    key=/etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7
    [[ -r "$key" ]] || { echo '缺少系统自带CentOS7签名密钥，停止。' >&2; return 1; }
    for variant in os updates extras; do
      cat >>"$directory/sbm.repo" <<EOF
[sbm-$variant]
name=SBM TUNA CentOS7 $variant
baseurl=$base/$variant/\$basearch/
enabled=1
gpgcheck=1
gpgkey=file://$key
EOF
    done
    echo 'CentOS7使用清华历史归档源；该系统已停止官方维护，安装兼容性将单独标记。'
  else
    case "$SBM_OS" in
      rocky) base="$scheme://mirrors.tuna.tsinghua.edu.cn/rocky/$SBM_MAJOR"; key="/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$SBM_MAJOR"; [[ -r "$key" ]] || key=/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial;;
      almalinux) base="$scheme://mirrors.tuna.tsinghua.edu.cn/almalinux/$SBM_MAJOR"; key="/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-$SBM_MAJOR"; [[ -r "$key" ]] || key=/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux;;
      centos) base="$scheme://mirrors.tuna.tsinghua.edu.cn/centos-stream/$SBM_MAJOR-stream"; key=/etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial;;
    esac
    [[ -r "$key" ]] || { echo "缺少系统签名密钥：$key，停止。" >&2; return 1; }
    for variant in BaseOS AppStream; do
      cat >>"$directory/sbm.repo" <<EOF
[sbm-$variant]
name=SBM TUNA $SBM_OS $variant
baseurl=$base/$variant/\$basearch/os/
enabled=1
gpgcheck=1
gpgkey=file://$key
EOF
    done
  fi
}

sbm_dependencies() {
  local work="$1" scheme=https
  if ! getent ahostsv4 mirrors.tuna.tsinghua.edu.cn >/dev/null; then
    echo '无法解析清华镜像站，请先配置系统DNS，再重新执行；未替换系统源。' >&2; return 1
  fi
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || scheme=http
  # Old EL7 CA bundles may exist but cannot validate current HTTPS chains.
  # Bootstrap only signed CA packages over HTTP, then require HTTPS again.
  [[ "$SBM_OS:$SBM_MAJOR" != centos:7 ]] || scheme=http
  echo '使用独立清华源安装依赖；保留原系统源与软件包签名校验。'
  export NEEDRESTART_MODE=l
  if [[ "$SBM_FAMILY" == apt ]]; then
    local file="$work/tuna.list"
    local -a apt=(apt-get -o "Dir::Etc::sourcelist=$file" -o Dir::Etc::sourceparts=- -o Acquire::Retries=2 -o Acquire::http::Pipeline-Depth=0)
    sbm_apt_sources "$scheme" "$file"
    "${apt[@]}" update
    if [[ "$scheme" == http ]]; then
      DEBIAN_FRONTEND=noninteractive "${apt[@]}" install -y ca-certificates
      sbm_apt_sources https "$file"; "${apt[@]}" update
    fi
    local -a packages=(ca-certificates curl tar gzip iproute2 python3 util-linux openssl iptables procps)
    packages+=(gcc make libc6-dev)
    DEBIAN_FRONTEND=noninteractive "${apt[@]}" install -y "${packages[@]}"
  else
    local directory="$work/repos" manager=yum
    command -v dnf >/dev/null && manager=dnf
    sbm_rpm_sources "$scheme" "$directory"
    local -a rpm=("$manager" --setopt="reposdir=$directory" --disablerepo='*' --enablerepo='sbm-*' -y)
    "${rpm[@]}" install ca-certificates
    if [[ "$scheme" == http ]]; then
      rm -f -- "$directory/sbm.repo"; sbm_rpm_sources https "$directory"
    fi
    "${rpm[@]}" install curl tar gzip iproute python3 util-linux openssl gcc make glibc-devel iptables procps-ng
  fi
  python3 -c 'import sys; assert sys.version_info >= (3,6), "需要Python3.6或更新版本"'
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
/Ww/28//8Of/AQU+/hcA8AAA
SBM_SK5_PAYLOAD
python3 -c 'import hashlib,sys; assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==sys.argv[2],"内置程序包校验失败"' "$work/source.tar.gz" 6053f9509a1b0c34a903faca774bce7760f7f66f564b0dca0951630e6fa36409
tar -xzf "$work/source.tar.gz" -C "$work"
python3 "$work/app/sk5_install.py" --work "$work"
