#!/usr/bin/env bash
(
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
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/debian $code main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/debian $code-updates main contrib non-free non-free-firmware
deb [signed-by=/usr/share/keyrings/debian-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/debian-security $code-security main contrib non-free non-free-firmware
EOF
  else
    local mirror=ubuntu
    [[ "$(dpkg --print-architecture)" == amd64 ]] || mirror=ubuntu-ports
    cat >"$file" <<EOF
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/$mirror $code main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/$mirror $code-updates main restricted universe multiverse
deb [signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] $scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/$mirror $code-security main restricted universe multiverse
EOF
  fi
}

sbm_rpm_sources() {
  local scheme="$1" directory="$2" base key variant
  mkdir -p "$directory" || return
  : > "$directory/sbm.repo" || return
  if [[ "$SBM_OS:$SBM_MAJOR" == centos:7 ]]; then
    base="$scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/centos-vault/7.9.2009"
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
      rocky) base="$scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/rocky/$SBM_MAJOR"; key="/etc/pki/rpm-gpg/RPM-GPG-KEY-Rocky-$SBM_MAJOR"; [[ -r "$key" ]] || key=/etc/pki/rpm-gpg/RPM-GPG-KEY-rockyofficial;;
      almalinux) base="$scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/almalinux/$SBM_MAJOR"; key="/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux-$SBM_MAJOR"; [[ -r "$key" ]] || key=/etc/pki/rpm-gpg/RPM-GPG-KEY-AlmaLinux;;
      centos) base="$scheme://${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}/centos-stream/$SBM_MAJOR-stream"; key=/etc/pki/rpm-gpg/RPM-GPG-KEY-centosofficial;;
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

sbm_dependencies_once() {
  local work="$1" scheme=https
  if ! getent ahostsv4 ${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn} >/dev/null; then
    echo "无法解析当前软件源：${SBM_REPO_HOST:-mirrors.tuna.tsinghua.edu.cn}；将尝试其他源。" >&2; return 1
  fi
  [[ -s /etc/ssl/certs/ca-certificates.crt || -s /etc/pki/tls/certs/ca-bundle.crt ]] || scheme=http
  # Old EL7 CA bundles may exist but cannot validate current HTTPS chains.
  # Bootstrap only signed CA packages over HTTP, then require HTTPS again.
  [[ "$SBM_OS:$SBM_MAJOR" != centos:7 ]] || scheme=http
  echo '使用临时软件源安装依赖；保留原系统源与软件包签名校验。'
  export NEEDRESTART_MODE=l
  if [[ "$SBM_FAMILY" == apt ]]; then
    local file="$work/tuna.list"
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

# 按本次实际安装结果切换国内源；不覆盖系统现有源，不关闭签名校验。
sbm_dependencies() {
  local sbm_host sbm_official=deb.debian.org
  if [[ "$SBM_OS" == ubuntu ]]; then
    sbm_official=archive.ubuntu.com
    [[ "$(dpkg --print-architecture)" == amd64 ]] || sbm_official=ports.ubuntu.com
  fi
  for sbm_host in mirrors.tuna.tsinghua.edu.cn mirrors.ustc.edu.cn; do
    echo "尝试系统依赖源：$sbm_host"
    SBM_REPO_HOST="$sbm_host"
    if sbm_dependencies_once "$@"; then return 0; fi
    echo '当前系统源失败，自动切换备用源。' >&2
  done
  if [[ "$SBM_FAMILY" == rpm ]]; then
    local sbm_manager=yum
    command -v dnf >/dev/null && sbm_manager=dnf
    echo '尝试系统已配置的发行版软件源，强制保留软件包签名验证。'
    "$sbm_manager" --setopt=timeout=20 --setopt=retries=1 --setopt=gpgcheck=1 -y install ca-certificates curl tar gzip iproute python3 util-linux openssl gcc make glibc-devel iptables procps-ng || return
    python3 -c 'import sys; assert sys.version_info >= (3,6)' || return
    return 0
  fi
  SBM_REPO_HOST="$sbm_official"
  echo "尝试发行版官方源：$sbm_official"
  sbm_dependencies_once "$@"
}
# 公共文件下载器。仅处理公开项目脚本，必须提供可信SHA-256。
sbm_expected_digest() {
  # 更新清单只经GitHub官方TLS读取；不从第三方加速站取得信任依据。
  if ! command -v python3 >/dev/null; then printf '%s\n' "$2"; return; fi
  python3 - "$1" "$2" <<'SBM_OFFICIAL_MANIFEST'
import base64, json, re, sys
from urllib.request import Request, ProxyHandler, build_opener
url, fallback = sys.argv[1:]
expected = fallback
match = re.fullmatch(r'https://raw\.githubusercontent\.com/kill613/(sing-box-hy2-multiline|sbm-socks5-server)/main/([a-z-]+\.sh)', url)
if match:
    try:
        request = Request('https://api.github.com/repos/kill613/'+match[1]+'/contents/download-manifest.json?ref=main',
                          headers={'Accept':'application/vnd.github+json','User-Agent':'sbm-download/2'})
        with build_opener(ProxyHandler({})).open(request, timeout=8) as response:
            raw = response.read(65537)
        if len(raw) > 65536:
            raise ValueError('manifest too large')
        wrapper = json.loads(raw)
        manifest = json.loads(base64.b64decode(wrapper['content'], validate=False))
        value = manifest['files'][match[2]]
        if manifest['schema'] != 1 or not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
            raise ValueError('invalid manifest')
        expected = value
        print('已读取GitHub官方更新清单。', file=sys.stderr)
    except Exception:
        print('官方清单暂不可用，使用入口内置的本版本摘要。', file=sys.stderr)
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise SystemExit('没有可信摘要，停止下载；请重新获取已发布的下载入口。')
print(expected)
SBM_OFFICIAL_MANIFEST
}

sbm_download() {
  local url="$1" target="$2" expected="$3" prefix temporary
  [[ "$url" =~ ^https://raw\.githubusercontent\.com/kill613/(sing-box-hy2-multiline|sbm-socks5-server)/(main|[0-9a-f]{40})/(install-manager\.sh|install\.sh|update-admin\.sh|update-address-ui\.sh|update-download-tools\.sh)$ ]] || {
    echo '拒绝代理非指定公开项目文件。' >&2; return 1;
  }
  expected=$(sbm_expected_digest "$url" "$expected") || return
  [[ "$expected" =~ ^[0-9a-f]{64}$ && ! -L "$target" ]] || {
    echo '缺少可信SHA-256或下载目标为链接，未下载。' >&2; return 1;
  }
  temporary=$(mktemp "${target}.download-XXXXXX") || return 1
  for prefix in 'https://ghfast.top/' 'https://gh-proxy.com/' 'https://ghproxy.net/' ''; do
    echo "正在尝试：${prefix:-GitHub直连}" >&2
    if curl -fL --proto '=https' --proto-redir '=https' \
        --connect-timeout 5 --max-time 120 --speed-limit 1024 --speed-time 20 \
        --max-filesize 268435456 "${prefix}${url}" -o "$temporary" \
      && printf '%s  %s\n' "$expected" "$temporary" | sha256sum -c - >&2
    then
      if mv -f -- "$temporary" "$target"; then return 0; fi
      break
    fi
    echo '下载或校验失败，自动切换下载点。' >&2
  done
  rm -f -- "$temporary"
  echo '所有下载点失败；原目标文件未改动。' >&2
  return 1
}

sbm_os
sbm_fresh_guard
sbm_boot=$(mktemp -d /root/sbm-bootstrap-XXXXXX)
trap 'rm -f -- "$sbm_boot/package.sh"' EXIT
sbm_dependencies "$sbm_boot"
sbm_download "https://raw.githubusercontent.com/kill613/sbm-socks5-server/main/install.sh" "$sbm_boot/package.sh" 18e494893d92763b50ffa155fa929f6e8cb25e0537d96ee3b558a95cdb0b2c6e
bash -n "$sbm_boot/package.sh"
bash "$sbm_boot/package.sh"
)
