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
H4sIAAAAAAAC/+19aXcbx5Vovoa/oqPMSQMiAAKkSElMmBlGpi1NZIlHlDOTR/HggECTbAtE46EB
UYxH51C2qZ2iHGtfLMmWbMW2Fi+xKFHLf3lmA+Cn/IV3l6ru6gUg5dg+894QTkSgu5Zbt6pu3b1y
5XJX3pqetkqp8uwvfppPGj596TT9TYf+dqf7+rbIZ/w8k+7p2/oLLf2Ln+FTs6u5CnT/i/+Zn02b
NjnzX608/cJ5cLL5ybzz+K4z//gfz64588+cB0+GZ6tTVqkn1fePZ2dWlu+uzr27Or+wwyhV945s
bVx9v3H6y8YXp+vXF5xTtxtfPPx+7l1orsOcLluVqlawZkpFK1cwKvKJUamULPljKmdPFc1x+dMs
5wqFimHb8sHbtlWS3y27Y6JiTWvlXBXraOLxMPyURSqG/GYb+YpRdduxp2pVs+j+svIHjar7q5pT
vlfM0qT7qzZerlh5BR5YJRNm0e2lakyXfb/NaYOBrFWKAGOqnKvYhoQUntFvX4mK8b9rhl2VZfbx
z4Q2XLEOz+7MlQpFo5LQxmtmsZC1ykYJENmxc2jfkDZAI49lswhANhuHlmyreMiIxbFXmJ2ON3ft
27d33wiUjOlT1WrZ7u/qmpyayNnVVNUqd+kJTXmcLGOHKaACgRf8vGRUu/R4x+Du4Z2DfxjaD20y
qlI5O2+a2aJRrRoVG2AoF3N5I6bvxUb0uNap6Znuni29fVu3bdc79g4P7RnaB5XV8cTUocbeORKP
d3R0FIwJrVIrxTbnKpN2Qtu8+eAMfov3d2jwscpV0yrZ0FDBzFdj+Skjf3Bgf6VmJACsglWrDnhT
lxreNTxEz2HlhZ5Tc4FPrWQegsHkitmSMVM0S4Yt2sbpxca3p+MqGKlauZCrGjEBIr2CxVerlJQV
lMLRFE27GqNCOCRRXQ53EpEB7RRiRaM0WZ0SYzUntOps2ZAPNdPWShaslxLsiAp97dF+N6Dxa/yW
6d7W7w6rkjNhAf4pV6wZQ5WKVYnpq1cX69efOsfv1xcerF546Tz91Hk5v3p72bl+r6d5/BuovfLk
9Oqlb3UeyMwULC8Nx+81egibA+TreuptyyzFxGZL5acsEyZfLpK4NgEQZgFUAKM06Q4h7jYEY8uV
ZmP5lGkXrRmYfa6SxyrUSRzeF9wytXJ5zTIFc9Kshsv0+yZazA69EtiHERRg05i5YoweJ7Ribtwo
JrTp3GFzujY90LfFmxCaANssAekowYBFBdgRcTknGTEnMQEi/BINYQkCVkyj5u6pliCHJpFA69RX
luedxYcrz182zt9rnv6qfvG4c/9S/eGC89cz9QuP4HsGJnQ7Uu2lBefcF86dz5xjV/Z+P3eU36br
Jy42Tj6pPzjV+PJTZ/Gx7lu6KnLM8qEtcpTl2njRzA+8nivaEkZBtGFFuAQ8tWv40JZB/i5wIJHH
DdCkxRAFsoZpZyeL1niuSBjyHk7XilUzD1Qr8Bz+GpVDRqEdonRn/svG8w+c64+cG3O8zuuXHwLS
4LnzbK75+GHj/FdwhiG0XMiPBJjSmOhSblMk09ncoZwJk1A0YvgzsFPpUcQ+zaS7t+BCIEIPf/t6
e3t6FeC5S0IsPaxWZr23Mybsbj64UvwnJn4Nvp7dtWdof0K+Hdm744/Zkf37hgbfhK1h02P/8scn
qXGzVIjF9HSK/gNyTWB7e9PX+7og6HsFEFwwbCAc8BdooWxt1/Dwvr3792Z3Df/JaxF/ZP/Ut3fP
7j8ntEw8ui0xpP7+8GiMw3mjXNX2jtC6QJjgiR8kmD54liL+RO7NGP1KDQ2+vmfvyFvDw3v3AZ7F
M4Iy/Hjwtdf27dm7f/BPg7t2x8ODpiUanHMkrx1hMFusDXE6wgayprM4zhhUK9YKRmEgtgV554S2
Jb19+/a46D5AhTNQQgGMViOcGlgRjmtJy7F5IDLWTKwXlmmfj2YjcmSXo+kxdU27jzNjtMNb75bA
0PBNh7eH99VKeNqKXVy//nn95AvnxKPG356uXvoaNuzK0/MrzxeA3XQWPwEC13z4uH7ytHPqXv3M
cefBVV1uVmBbZqzKwZjo89fa0O6tug1kqgLnuKHlcyUg8/mD2r+P7N2jwaNyrZrS3oL+q1OGZuem
DQAvV0hapeKsBoxZZRbQKFoyqzayjjAqrWodNEqI5mmsVzF+C/0CB6FN1pAqQh9ABIzKBDBGSAom
4Yyfyc2mBJ2xgbwB/pE90M0ysk3Jt+nfLfgvwYlfJo0q/unu7kn14n/wg9keJsSSAHF7KUZq3irA
MT2gpZWFROMeIMY6hYy5HRNVmHGKw3y6hQXlM+xAhWhQsTT+taesGfxbMA7BH+pwlH6MxWUnbg8w
AQUTmSfsYjRHS9UErhpXq9c7Ps3hI3yVAkzEqLOsWZqwoIvRsXgUGyf4Cy4/kZs2i7PAkAI6dGDp
qjpzDfzWzgMrKl7yGaQzFgzArYc8mmc7MFlrTJMcc8ouF80qcZMxRDL/jsVDM/MO4apfdDbKf1JA
2YzDMXoV78yMHXGrIW4mTKNYSGgHjVmiWTCeSh6hKFeMCfwK3GZMP2TmCEBefXo8HqJ+1Ay2wH1G
0C6aS+hmDOCMgo9aQPhaTPCYD2xEBpElBZvWq6wnfEkzl3CnLRLd/pEQkAgOvg1Ng7Lu4RABBJqH
oSjXGeU/cjJoGeFoRSN6l+5vxxt8KgesKxxO7+hFKw9g9nt96NwJ8IrwFAhFjH/Hj4g97ZKOAd/Y
VVa0YqQmasXidK6an4pV9NHB5P/KJf+STm7PpvqTY+9kEpneI4Ajt6m2HFPz+OdIRz+Zq//9NEr3
wD0t3HbOLTQ+e1S/dKt+4YQYpMf0lYzD1Vgs521TZdJxB46KQY/h/qIx8K5zlyeszz1WySNismlg
ofB5v3r2IE/ttR/XfgVHV+BACYs8y5ebD+6Ikdy/DJKOc+fqytLnzPHB8bF6fc6ZP1G/fLZx+wEX
do4/hZOl/vScjyv0j9sDQxJNcZa9o7uo5jnl7zDXsMrdqXfR4hdCdfE6omAnrLBOhSUdVdbOWDzQ
jNzo/SrK5UMSzo+IQ7JWKGetfL5WNkH2FGsDj2McI7BnYnOEdiyAiHt1J/1bpH9r9G9prV3YfgeK
SeZCce33A1qvf4JpneN2gLpGrkJrvj82Cut9rDP+LwCC2K3J7sDBAC1T3TBlo+GmAK0x3IFUKDUJ
eCvHMvG4TyKgklIUIEkmK2YjRrPkyQKeLGSWA2U8WSfE4lEBgfAanFAu1UT81ypFovCuemYLtD2T
ypdUlU2ubMJTc2I2ZVUmdQXt0Rw962RSqIuJCe1TDPpJaFMGqu3sgXd0YIgqycFJEI9hNen2+HSS
RN9i0ah0ZfQjcU8z0kvsPoy0bJXUkzOoOSCBUhZLIY8Vy3Rvi6cKBvIscLyjVomWUcUsx+Ku1ImM
sn9OCUuSvCqCpsJNxwQ7nVCIQuBMyFvAbpYEE45HIeEeOQRcirgJ6EmcWIRMaNLoZYAI6LpYJbmq
NW3mY6i2TGhALnIJbRoGOZC2+lxGHF9KjR5+F1sODvUSMqEDrqYxNX3Qxu/ilBjQUzgdMP0FszKA
pAFrCwWgWLhhMdKyUxMFmnDsQZ8Z11lKq8JETPsRg0XzUwBvjN+mEIiShVOCg/DPhSgyUwE+LYYj
pW3g6Ul48OOzRLiRtSJ0pIwST3qtOpHcpscj25wo1uypwDGNsNmzpXwQNK+U5WkkEY+komH8CgSb
JVjFs74DBuoQDo3Dpl21qV48hJNaCUjXQX4piUHFPATUNYuMMvfRbmqRdYWn1FMRNdCxuHqi45PU
SHbXyL6hN2JYFnZClhCOEoR8UDMLeP6l1WdYSPuNlrbSW7e2VQPOLzSeP6hfPL6y/F3jq2Xno9Pf
zx2tWFa1fnKufv1kc26+fuJi/cZ7q1fO8bH/j2dX+fBR8CeWuiIb0IBwP2eryBXQ1JqlyQFvchlb
BXMSCY2CJ0SSMAek7Klcd2+fQAktWQ99TKn0SotFi2RyHIjoQSEvoLJseryQ65criYlNunvLZvwH
1vG4rgcmeEpqdKkh31CnUlPGYQF8PHAMgKwCc1IpIvmUkw+Dkmp/euwqwVI2iG+wtWH+mHLrOItl
VLRDp/R4EgZeG0eVvHjHEih9najkJqcNT7cU8+R5Xr5o0KraiDvgS3tIiS//VIyikQO5qksaZ7p8
0kB4rawsnW4+f+5cubeyPF8/e9dZvMRiNivRnGPz9VtLwCq+YVZ31sa1fdy8y1ytLC00n3/pLH7Q
+OworKyV5U8at47C4mIVtO7tH2vcUFAnEO4ZkFJuiYQ4tGTVCQMZX3pRgImBTY2K9QTQ/7KRr7oa
wnCLa1VMhOZWdp1oIXEKDsVExNkDwgKT4MFlJ0oD9MUHdxYevQ29/TTw+9GH/fzooyDcCPqKyhYB
Le1Bn94gRnarLpCWeYUksUgKC+jx9jSDNg2qBQao2VHsjA9bZdiSyBIM0A2B1KmnYCOkJv8iOHjG
GLY1qgMiUIb0YY7fMP3Rx3xbXyknRg7QVnJ5tOjkp8xDhq8pgYUI+NRCntEuWBoOejjSY4JT2IpK
PT7VpTGKzqesdVDhiYhSChMlk0kSFhi6OKop+hERSDahlLfjp43pceD0kM1AXBlV8SDMlIsXwJVr
PaQwBPJj16Zj0ynb/ItBxJd0N0o5IrWbe9aS0ZyzpxvP/uacmecjqX7h0erxRaASzc8+gVdouni0
6Dx711laUmQx6o+6Ujr19wQjggGhDVSdii5ROEUneGAWAppOxCG3ElepKj5Wp7IT2ALbKLsWIIEr
YPVxOmL03H2EUxtvpR2Oxgv+79wXze9ONS6caT5+6Lx4Hw7s1Q9fAEF27TiMux+IoJb4CclQvlGE
B8EtigW85qJ1mfVilMAg2uJWXrVJdU+kxGalyeARCNNErYKiueiImYvDgrlgjXB/JJVklwI4ncuz
2KY1/nZMtsXV4q0Gw/w0bWoFnS7jlslkmDlmAaEVCfox/T9y5P9TMbJlknx/Eh+g9v4/6Z5MemvA
/yeT2brh//Nz+f8wb5hJpVPdaF5Zulu/9Wxl6X5j+TM2sjTPvOdc+3bl5YP6fTS4rLy80bhwZWXp
VH1pyVlYbD54sLJ0tvngTvPhUefBR42zj76fe7ejYzfI1Ie1XcPZ3Xt3DO7Oop0su29wzxtDzuLn
9fPfNT5/v/HNcmP55srSt/VL36kdgbThfPpu/aPrzGnyQ1TczX/X4dy5uPrePQCCOc8VKPryeePC
3eaLJ0AboeOVpx84D0468/cay++vXp9rfnq0cfsBtOKai+oX5tlqLgbw+GtgTGHY9csvnGeLHWhH
dK59tDo3x2PBrp58B72rEDbnLjmPngPYzp2vmt/ehTKNT4/W73+8Ovfe6tySc+IRO1qoQ0OcoG9U
Szemjj8O7dsztJtxRA4W+q/NCWQ1InDY8UtzIrZ5ZPD1wTd37f5zzM6RckLYYrXf/Kbjl0A4fgXE
Mjed/L1dOQT/WKmsYm+VryyUNg02tSY0z/yaiOo10fHLX8byU7mKtjn+GzIoQkU4+62JGP2Kx+Pv
QBGAC+swVFr6t/BIKtACAJHRNhoUPGNrefbXQgUadGnnEtrI4Miu/zWETceh3SMdvzZKBXMCcNUx
NLJjcHhIRd8vuzZrQ4dQbGIHrYppFLQZYoAOGqUUWlSL2jiaAKsWWuqMMkplFXRCKCE/O2XmpzTT
JlzOTOWqZBg8aFRKRlG4/2i5ceuQAYy2YUMJA4VO1AwjCzBlleBEoCoSUxa1hB0dnsoB1QFo6JU2
bkzlDkETruFxJgeiHpRj4Iu5KtoXU9rmro4I5P4kuNU9FVa5XJwVx1uEWkO8QNberuSlJ2leZ/UT
HLxS09GGyXc9KOAtHKq1UjWmbgZW9CMPpRRQpztoCYiSYmmvX3uKlODkifr1L9G8oRI3kkzRV+bM
k9X5BaQTp//aWL7RuPZ149qD+skPm7fvriwdFbCKcRE4UsmkQgzsNqy9kT+82Y/iGAiRsC5wPjSj
BDOZF1Odt0oT5mStguvAKMKU02rAaW7TjTpu6OZAVXbEZmfDzufKxhrNHygdqLKrw4BGPgu79rw1
MvRbfCwWUzLzWwEDzR1p9Xjy8B9gvEJT+IuNz/+bH+T/VE3Bz8//Zbq3pLuD/F9395YN/u9n4v+G
SdGVRFHGVRrZ/do4WjaAepDGx05oQF/MCTxDJ3JmEc69SkLYN4SmjHUXHR1/gjPZQrJjkldlHtXs
5FowhQbEgoHmGlRfkgtfRRO6Kek4U7OxB9QtsDdSokNo14GKlS3brFpwjqN9Hg7u3KSRnM6V4A+K
utUc2R3QEl0uS3i0weFdmnC0tlMdins60Md8rUKy5UQNqJ5ht/BMfyXn85/MLbzjp/DpBnbv34d2
7Mc23yFyr9tA1ZPj1uHk1Gx3ktwv0VCr95Nhmwx/EuMpewpbZnV5MleYNkvBR2T3TNZM/3O5xJJV
yyra9K6tLlIjk/pkhebT7jq0BVrsgumumHkb6BW2HFGgAJM4buUqhdTbtn4kIUY3Pp1ErsfuTfLq
UweGkEDBI55SWupM19Tql3NsMncV8Gi6RJ+QoHsIcDmx9ej/K7mZFNsAYD9U0ESJ67StOcBvp6qQ
zo7gimu/07ZQWfyFTnvYw0GzWOzL9Ojei8yYdH2UyyLYZITDSexf+6dzZum/0ASfS06MvbMlfSSu
J0STQSs8tAGoYM9xLtHTPxYPdkv+ChKmBPshtLdSgEzpzB9tPlhSjROrt58g70Z6MbZFIJd37hjb
IuoXHtUXHnw/d5RtEfUTF1eWl+vvL6KrCDl9BEwTCY1DFgQcpA000EaPOzwFTK9VtUpmPhZheJUb
ekBrYWTfh5wZ2tfJPjqQTpJ7MC7sdub3bv1IPGDcJQhZkVWR0STSPr+1jX2eCOeA5rfK90U6f0oa
S+bbojDSp4QLv6okjY3rv5uqTqN3CHz7VcHKo4c0//rXw/A8Hu0Nim4/Ic8IGBB2GO+azh2OBTGe
FJOR0FLATcQ71m//V7tcnz0pgX4M6PmDbTK+E22sJeTbxP259XzGwEA4gdeNGlEQdPKSe61vC/p2
BUxF0Tuk8eyp8+gDIQFdfR9jB17eHtk5mOzu7XOlHTb26fH1mC/kAFS7hWln7dlpMo+vw6iIm/PW
cTQRvve8fvkhByKwVlsKHxV0ydHr9z9xrgu3tJWl+861586pW6tzNxvvPnEePgFhrv7lbefBR6tX
hAGBlFhktlx82Dh/rz732f+Z+xT+h+5B6EugqIv9PorjOdvoREcbsiTnbHJ4EpPLNicbVaWKPyP5
4SLhFxOOMyaszuzw0i8oiIigEDREsdmE2ZDU/incf8NwOg4dNvI1XDKw7LNo3EJ60UMbuQyvFdM3
V8VzHF+k7Nr4tCmioxLeKOP93neOOXF/+Xz3Aj6m1DiVCAObs7NwLJWLBkYviYeBjR1yPnIxie6V
VCXFnsgBK4zYxEP0BxZY61Z8REOsTH4nYjH8zoS+6q6HZox+JiQyR/nvmJitX2uD7F0AVJ8ItkvX
p0GEYHNRrVyuCL9vC93BZ3Dl12zyFOd1JFy/c6WDdHiMslcUueknhIsU4Nm2kJ4xPMDrVpAztg1e
t7zwrAqcHdQEt9WptOQ243fG5MfirOVaY52jsNw9JzPfchBdKIsMyBLyt1YlB8xHO8ckl8VTvJNU
QuFzUhJ+NfmiBSzVRKFNGIqgB86jG82HF3iLk2uKy5B5C10wU+Ed3/pQdiuv1//NdwAzycwVyE8y
zBV0gpDrdzvDrWnXplu5vqz/YO9O+052JjIxd6LW8PJi53YYEaoTwya0iBBA9TMuTP1+zgFGwR42
HS0883ERUtX+lpz/OLR0MPItQ9vJMXaKm05EP1z095oEiP4hTWJgeqCMnLzWIIUPMj5v2EKNHCQt
yfql71Yvfdv8bt45/nT1yjnnxHd6NIByCfhdjn7r96WLGCAMzK2quCQhWy95gfWYl8XpH1Z6iqjC
h3fFOf3uk+bL8861j9BKErQyB1ztlFUXNJLHo7aywNiJc86pm2hqIf5EAFa/dXv18zOrc1ebL49/
P/eu3m4vExvnbuB1eYFGBoJJjuP6l+7YpY1HuMBBlXg0JCGPwmivQhdFEeZzz73QK9U6Moq89TxW
aPGU8+By/SIIPd82X37k3DiOoVMCs9ecszd57lZe3qifOYpzff1zDvnHYoRq59i88+CJJ/qY5awg
dhj3A1wtJQNIEOk0KwYKnbYSZ0ahEX4f5fJs2UxVa6VcqoqKhalaLmUUaql8qcs2kWeIlPzd2oLz
SsHxmpf1sEW3subvyKpMyldqkJt6aHA+g5UXN5p/v1h/eo5mleCOnlJfiBY5QFJ99KdJTlOYDceu
CDSRC3yyYNKBn4R3STy3YfEnab+20nNAHUHLKX4ozc1UUMNhkKN9hp8QoEl0XUowslu2h8EzCK5v
ptQg9nRECNk6w8i8DRdC8fMPnZMLjGIMn+CEEtJEKoJLFj4mvF8DstP49CjQmf27R2DtNR8ejd7j
USvfmb+3+t69wFy6HTlHr9fvf8y9Q0cYH3jzbuP6aS7J5h/nr2dA0G8sX/8fb7pA/T9LL/bB3p8o
Bcwa/h99PX19wfwvW7f2bOj/f678L9fvNV9eb3zxEORroJGN6zdBmt6/Y7jrrdeGtdf2jAjl2csH
9fNPVm98XL/x8vu5oxw/j0zP0w84AYxz5R5sYZExBiR75/gx5+mHzsI3IIb7M8NMGtVyzsusEkr9
EszgEsjZgsZr99es3cHac1i+UmWeq2G8BVmcjcO5fBW/l4uz4lwj3alUULCNYsI0KhTxxAHQFNiY
JWVcrJvJEPHcrAoZ1w8cTvfMzMzAn97xnFmo4W8QguFPWvw/I//qqg+X11knNZJRa+j8LK1v7uuU
vUkbfMlG9RrHUAj+3ws2cpVj2u+0TLfUzY32d5OiVxTHn0GVjJ+owkQDj+fcWeDMIDSzp2Fad73m
cojSkbaYw8QsEkj4ygDanBoGZge4GLTPxPRf7dyJQWIEUHf/tjGf3ovaQb+3w9uEP6n3ZELqvkTT
64QdmRpylmTGB63898/Xb5/wp3YQbQrsov5aLgdhk6JxxKIzWpilcg0OO8xzMNLLOSbwNbISbtCS
YHZFfD0ejqIW7Cpn/q6z+In0R1IrqbjJtMsWEdbuUWu+GE20G1BIMbpxUigiAdD8Fmb2sa9fZGNg
N86AvA/lxN5Mib9w2D481rgFDOOJ1avnmpcWmy8+hBH849lJauOIMH/YthGIV4MzpWrlLRG0BuMm
dfZrw22j0jyhXGzSllkoYKNixE3eKpVA4IFVGIvx3In0Dx6zs42dnvPlCLk3X8YkFKJkbBvIXkg6
YvA8QQgMy23mhDcyDBnHgUVLjNx4qYDsM+3sXh9d6BQDwUjibA7E0JgaOd4p9pHcRYC83p54tBhJ
tA1hjq8JR7jVoqdRiMc75bfIhlwjgSSrjKfQjtcToTLdcYx7Dzcb7fjbEns9EbSyFU6KudkE/8mK
bbgGnqQyPip0k9qJDN2MFrODKSxEfjQWo5GcLj5cWT7LxKP54OXqpQeks0aXSxk7A4IJ9xrZlSun
ipZBSnY+OAXbixvxqnfq/Sy3eqhosYxeMcvMa2/sExleaoVya3zAS/8WW6NkqVC1eMLT/sPxB2wX
uZzXMC/zJxZaMvHWsGI/RhVNkyCGIZlF4CtG/hByIrEt6e19LdeYqAInc0SPbIzFtkf7t9DxHYEK
pdCW/gybc38Adl5tDcPS4hOWF1j9xl0QuYBHgJPXteP4mIQW1EMAnkn3j4WKkWcflIlkdzqit4Ak
xp06cqrMutbPf+csfsCKI/TNJQ6gfuGRq8OhjiKml88xaQ6QTa8rqDjhw1c75ZIfYmBYJKCKgslv
/iIDV/3sx2j+Wp4HSbl++Wz9/h1M5XblnnPiUf3knHP7C2ZI0Lb38Inz9Dx7ZoP8+x9mqWDN2Ktz
i1DNOXGs/vejK8sLmPZg4ULj9Jee7O1jkSg8QZ7rcLCrJ/gYxyhkgH+CQtkschjZLB2H2SxyU9ms
OBN9Bzyw6qgDwxh7ZLjWttOGkCgRQmIKJQb6rHn7TFA1ZxaNAeyL0/7Fw/1nNtwV/fL/Tyf5r0f+
70lv7U375X94srVvQ/7/meR/INrO3UuCfjy43Th3zM0CC/SGn5Dn1MFeVgXUP1xYeX79jb0j+7+f
O7q7e/8wRqFRNAeLFywy+GX+XGWSXd1c97vy7Hr1AYFUsJ7T3Vp+eWtpDto57XHj7NDuKhbI3zGh
ZIxMeLk7E5TaIhHIe5bwZQdIoCa5o2Pf3r37pVOF3mVU810Cv0CE39qzC9/p4kkKxRozb0h/fOFG
YsTYv9tTA/BvmdRqypjO6Ws7xnMqANaJ+sRHFOFkUinOQZNlVbeIioYfCgdBOT0YAMoR5SbtwCbw
XFBqtfB8UcH3UujE2zvCtMh2JCBR2hlr7xzTKtGRDws4r+TGWChnJ8yK7f4o5uB73JdJgpJBKghp
lxNSKRYh7LcT+N3srdhU8/g3VNWXwtVdF6MK2GPa731PCf4xBCv8NBldHVjctgoJYBPU8AqAcnXu
r87HIPucrwPncecq8sgrS59zofbAeijiKfA98SBtB05A7cI+RyvPF1aennVlJhFndmxeUaBQqidl
YdKzlkuY3oJIbdrVcDJYehlfR5JenlQOssuIrLxLn0u9zRmG3Tlxa/XKHUTlubMrS3NuAQEbcmTh
FE6kEoKlTKB4IIg0M0oWXCwwyoojTLQmmk5ofYpFP1Tc1SFhFT4BoAqm9vG5EGJnAANBuNYq545X
jy+A3KGIFVSXMjZxEhbVBEyTJdNkkqjlJ5RB8umbal0Tvqk1OXoQn3fsBgm6po6PkSn8oXgV0roQ
Co5cEb0hUR2mJ4LtrVFVjCKm/1prnP8KqD8fvmjF4vhKQivm/r1/Gdaus3hp9co5puFuECInw2y+
RCc554PnK8t34CA+UNJd9OnTucOoNyMC5HtREupPV3bsqubLB0rycSazPdUt/iff5HNw1BDN6vM1
JQR+GzZAr9aT1vrSWmYb/R/+6aWfvVqvrwqq3pDaW6XJAyWeEkA8/u3U/QURwfBOIBoEqc303469
e/YM7difgC09OALsjK8SuxxRrlMkwnSciwS4mpQKQ7Qn3qknwy+Z3sQDUJFfuZbcoiVr3Vqy7K/G
hAuqaElT9po09E753j1hx7DIHtN7452cY4EOyVIKT1x7Pdqa0Y/JxxgIDqtSbr38RZYqYkowjg/V
NaVJm9NzJDiNR6E2XbZFLYz/smsVI0uputiEzBbpUnWgm/ESVyMFZcs9IihhYlJXO+b0WP7dmsAQ
+C0y2TrlF58RJnjMBASvEzgoJMuTFdhbMd3loFKTleykWXBTyXu6SA5/ZOlf5OhgrcS4risZz1WD
ChVWJNAcqRIp5TDqe1iVkHRrhNylsUIUmfNrV5j3br78CDM6LJ5zTi4489+sXrqvED2CtHOAGvTl
BYDn0kxUo4BMHCMpr4VJg1MtRyiiu3Uld2wASd1xV/vUS0XbG2BcRSRI5U0gQ1+9i463IAmcW2Ca
xfRLOZ4SmiSoqD5TDhyZEyye0IIHi/uqxcBQL0xGu1GcEDocYM9RLhjluWwP37nf14MIUt6viYgv
69ef8mibxz+vfzLHfgm6txw5njYvk+UIF5EEJf6qkbcnJzfH8KrZsl/jzjBt8YJJWtYmsGO9tFHS
8fZAi+X38DHMm+I0dKZx6rv63FGy/ggVC/fimaoYQp+Q4SXJVJWSpapVDumTIwYmtEJFpe0tP6Dt
vojGM33q9iz7UtYrun4353tEp2QUTKG0k51GLWGB0q+VI4DuiQI6BFIYRrKTBHMhRuQjjppG1YDA
ed18WXOk8VNmn13DcCOXP6WF5rU7ZeSKQGLkKSAtbJm0m/Gotf+rKCwgydlkShd0w3l0FQ23j75q
LH+uEuKQl+bvIrw02yarjzAT6pnurXQCZxRJUZzPilPtOpLXS6NGd1iTrJDiAKMXaQeLptHrM3dN
WegM7LNx2ZE+sbA6sSzShQjmQgosLSQwaYpuJ3etw4bAdipeoqg0kuIYBn+cOyE5WSA2CKlru2ph
jZF5+VwEtFbUr62cd9ek1CT7QxhwJdpFwyjH0qmeNj6ZCvl3FtEgx0Y+HjcfCH6VP/crT4f8FOXp
L1eMQ6ZVozTUVtmy3eAeqbs62IuTY8zAevHzdW55TqwI/KBFvvqSBcN8F7WyrauvI/KNRWRW4ppS
a6X4/hd8vv88AtXxX/QinSIE0yeaa89venhYL8cZal3hORNaLIITFfnnmEEQMFK6DJns3Z7F6IZ8
tahkJEclHfpkkkpsECjLIWME67CjJkVaKJmQ2c9CnpncuLxlQs9RbfYi9b5jjLVR0NuqrZh4cnSU
c+4heleeuMjej3wvQuPegnPurHNM+G7Ja31ydpY7otVOIwVSLPoO222kXOFfWoQmZRmmOFFIuBCM
2OsxsOdC6EXupZoUg2c0x9euguF/kaXFgeUHqnVUUTjgxB06r8NAftqo4UcVbIOCH4iGV0eFDx1B
INsHWkXyGrSigs69Rz9GC/GTm+Rbfgb4SHE/BxC9m3edO8dXlp+7rCRv0XhcIz27P+pz7Q4xbxP1
5py9ycfGytJZ3hDo7b6uroQ5katDgysvbzj3L0N1vZMoObPFgkV5/DXqoc6hJ6Pun1C2hordyO71
ABTvQ+agybraqbeASl60VJqw/LK7gC/K0yxKPRAwGguXTOfYfFQ9VeHwj2cnvBeKzhzfnPSHYkb4
r0XpOXx1XA1rIMnXD9O6+JpmBSEnjHRbpGsCAto1f7VAkrD6+RfN22dWlk41Xz5yB+j89Qwu4Qvf
BhTEbBTjKlj43Bln8bGr7kYviDs32Zoe9i4Up/dEvlQtdnjRIZNG1aiZBY7gSQcp/gjt8CE0XOuw
l1aW72Kq5ubLcwCAqyFkRZ+rdamw85+0uaUGK5M1DAIYpjcYlpOHIwl3+oAetv6xd/7Ks6ts52uc
fVS/fhKtfXC8oLVPdGPXxsmhA5tEbWwWb7yjXzYF/gzQkWKVFFsKC/6U1wjOvlG09NA1Ljp76Mst
dLt+9CHfXMLypleC95P7jg0yfPbp8ZZ+PljWoqOadyXX96ilzlubH4tQDU1nLg7Iisu3Mv/WtiN5
HhDIRKCIJcRxrV7+unH0C+fjK83P3ndOXOHeZPlkvmjk6M6T+tI8zIFba2XpQ+erj2QVhdsGbBPW
GeUiCe+UUSwPIH79iu1AWbEtRHGBWs6EJ+0M1/guDDT2Xn7RuPNUKPSVZqnBnFhYMeB6kDVKSoUK
ts7TP4DIB9YNpE3D7RLjua9/iQu5sXwC1UbhTqD5CMjhexK794B/vOycuuWCjRvw9hfOsSuALj6U
GudvwkHkNRqAGxsjxRPm269M2gP6v7ptC2v2OQyNa1y40vjbU25s28rzBTdKHiOfIwCFF35AhcmG
cxquZc3xtd4K4rjrfCvUaEEY6FXBhYCPUBUCH8JlQ2t0x4JmqCs2jqodAXX0mfewSKDtUg3zn0I9
tJcOAG0WJfmawIheOFMRWaLVrlwarUpbvutbuGage3ndiljVhXLUVimUk5Q5LdAlhypGnm1ee4H+
Au28OO18+i7d2pakS9vkGoVV6BFW+oNt2P5rAvBJineYTz1NdfCYy2Iv6iVTXswW6qm86iyGqIQr
QJRU03YL+VNcpAFnLkCuCKPKvQjR5oXAjaAKVCiTuED1r8V4q/aMaM9iXyUamIIcyRjAyX7t2/rF
RwHyGyDdnrdcALFusHZM7wL2vAtjd6VrRwp/0OVWHIztD38mniA1gQ/xopiDCfFkN/raDv1n/EfD
spSFyLJdnk0VDKOMX0IYjJgOOq0D8a0K16ogP6IynzmB+7gUq3SAZetv4fCpmgqATdeEjdBnn5W9
44mUdU8kwaeryIgEVPAcQfWQelnfK6sE6OFIbTzw5K2SWX0dhDx+HBUh7buhzx8p8mpTQJvcZXgk
PyR5oPCNcGrdXw2IGj+K7BqqonQVVX79wPj005Hx5szRAqvDrvh4AlOwOwaP8bzXby05D58oclv7
xcLcYuAOEVJIctLNgfUApSgNpWbwWkBZGlaKcnRAZIPNl1fqlx+KZolnRYmZjkY8sNj7Vwb9saAu
PKcpKRb71wYHH6SnEchwmbPw1AgnE6ohOQq6EdO9+XpbtD+2YG1ahyXBNDaff8qMWQY5Mxmb5G8+
E9W+oIUu0fHu6hNRU8xVq/FR8uuRYAr7CHy4PGB/R4toE7wN2nMOGQgiqKW3SDule9iDBpliuvtO
XwcOMIyr1rJnBNwD+FcBgMfWxongSVul+3fvFFRACIPoAyKINd+VgsGEINxJ6HbBfxaL3K7vEIpY
s8BY/LPLNhqnyHxHrjEqyVy2z+7DfnR4yRk5Kfhv6lUqrXuhCYfEx187C7fI9H/R50gZveIEGAMq
mOsYrSsE9LdrWzFtiUvnuCH3gs9W18pFcy+uGBDulBKl2nIYnGZZ5H1M6pHLkDLXUC3S+XSveyGS
fFG/9cx5tohOgktPm39/7Hx2mrGfbCx/WL9x0yd0tdjqnrItEXgsnEHxzvoy3oiYEMOLR13oF2Vz
8vF3YRdq9cbJcP4T8YIjqpSbKSPXNtDOMiWqkrXkem5lw4w2YLZS5lAUq3d39itgrzMTX/fGAZoA
Z7JwPqXQZWf+u5Xli0KBS7tJvevaWfx0de6kT9D08gkRoNI8Hz0tr3Zs+/SsxIPwzUoHSpKQwSO/
E80Po/7hjnw0HXtUqCe8DlPctuMMenC7Mr1CTiLmjHhrD5GvFvDEql9fmFOrgLGEvPe9ddATc66R
yYj+mYgnEf/jicY/QSDQGvm/+3q39gTzf2/Z2r0R//Mzxf+g1oO0qF0B5YekO6hVRbX035468/ec
r+Zcdcj3c3hnAmvP3YfCSuAP/1FDeLxs2fZU0Tjs/cBbldrckNImIIeiakb2D+4figyr6XI1WmTv
FkqRjh1733xzaM9+TqktiiareZKM5U+gFVhy5+CuPeiwNPKHN7Mjf+yV0TgIDZw6WetgbDOSG/91
fSjp0mN/tqVgbiXRVmmimq3Uit59yfISMr5tiu4jielQSg9nsB2V98+qWgosiqqGt+lfugIeYxNI
SMd+6L76UBqo8MWePh1EnCMhoG3kFVHNP4rRLa3yRrHSZVR6kGEuuENGFk4qs2TTXXweygToSg4J
uveP7/KcVoIFUDOMjxgSagvAeOeIT3eV57cTuWmzOAtcNR0AMlsXXt5O3IIoNWVZB/W40HGVa0Fm
WgprmAitZQRScqwT0UkNHqRLtuMcP8RdE7qwd9alr+sCOLa8Aao56cbqhy84RgnE95WnT53Hd1lZ
wcncfD4efrWVm+A0PyoRApwL/GCg+DtLU/7bXbm6sj5Zb6rOW5t5wkXmmyp8EJ4pfCqmEnYTZtqk
2XI3J86TV6b1hEb4logdwGYUue7RzRH+qKjg3y42+CcvrLGwsU8HPqtA7ZBDKGrpqIJ4TNZmRhlR
myzlxPTvaSJVMiNgi4TULRhoVd3ru51cVQNT+xKKrLjDR6iEgWGAeZ0Se577tooF6QwkwPUZe9Dz
V9R2bfyqzcT3PtKS738tbPkyz7TJmWxHseVOvYspMJSD70h+x1xbeVFJbInuEwbdkg6PR3XxUxQm
5tNPOD2jxnRB7n6PevtfkxeXzUrZqB7d0gXd685P2xRqHt0Ers0Ix16lhFkWNFaO333ng8Cr+xeL
fG8BH7xX8LceF5hjSkzbIjxWKJ7E0klrIul6gAzA1LnTpviFBE6zCC83ZaUTTEAjGDYct0XfAyRW
gN4GPFjJOSBGSR7UGr2uRab/4uVlbyOaXbpV/+YC3x/nots589S5eVNXDSro+IjLNwJw7AfQiH88
ORNIHGZ2xHs3zXw1FjPknkpoBp8ZFCIXw0mDH0AueTpFPT5yPQB+re0z8qgltWZKRsWeMsvauDGB
ua+tsiEuxdBsS6MZrNTKeG0Bi4o2pkyFwhrnmiykfGm/3TTSYoeGzkRfQmkBXPhYEy84P/UYpaRi
fRXXj/alAEJNwhGqYEmg99gs4WnaOQropSxRSWwOkMwdxFt4Z+iAC2iDEzm3a9MrRzMY2YWXH134
mxK99bmuvuNSpH65b6E9Xvm0/OCXnNB+ihmNiZ8p6gXpxpF4PDwjCcIoxST7atHhG7pZljgQE/vm
3Gq4rmIudmkloRuKOmg/EsaiWBV38lutDvUUdrFLEBCOUeMQQGlEbijohYY6igMYe6UOKsa0dcgI
9NEi52nUam45KGAlAis6nCz2R5l671xRqT4eGoo1HqccNebeWdOhKIPgGMKXESx3kFzyy7Xvab7p
40Uff+0sXnbOXBROnsSLulKgc+4syIXNhxd0X2/EeriKOqRw+B1VeWaQR2zHExLX6bKca1JyvIH+
7CP01Tu3sPL82OqNjzAHLGWIbT545Dy/0Lj6fsDG72bDbn56rHHtojKKV9ny6g4O8s/+OxaIF8W7
iClnBE0ImV8iZkZNr5eQREHgSWxwZqFw+SdcpGHkCe51ZKmIvVJeZSK3ucpDmxgFXFV46CiIsRxn
iRDg6QkP0haJzOQ49IJQz4kB6RRaSd5Bei6P6jOdHvJygK+b0GmVfnXC9/i69mGLbeVyWr4kDip7
6JbAQ6FE/+6Gf0kvEI+UFlvW3iHruVmklUElk8oPqYOgg90T5fcN7X9r3x59fXeI05qX/cOuRSvW
Vx+tPD3ranlar/Sw0ZdWhG80e1wsrFFw8Mca9j+9EQVxZ5LpaRx+zK3lJsTXMRJG70dnzzabTUjK
o+wWouyJZDK4K9qiTnxzUTa4Y8fQ8P6AieMV1udmBKwVYfBV2qXMLgbWcc3A7RgK2l2VRCtsB1gf
Cis0SxE9j7gL0JUJ0PaGFezgFfXCtY7UjsJEh+VCvICCVMkRUFW8WxD+jpJlgVKwx5Si8U7vCjU5
2f0RWe6A9yrV/NfVMEs3oMXCzZep3URUx7w2Wr5W4QoNkXv0szs8NeuZ7teUNUI9d/crXbwNu5CW
8649w2/t13/ghqf2xzpeZdluxp7ja5EsXKseaBlZbzSjjmE9p0g4INcfnvV54+ZdlbMAnqjxxUOh
rnt+3aexa0nMGJD1R8AJdZAAVaqAhMNjvy+8LaTvkRpnfN4f5eDoaSeoTFDtsg4dhaovZGV8WLaN
EGGM2R9dgnH1ktB4vLV00VqqFyggxh524OZYK/kDe5IyfqQYsgaf73GOqlbpR2FlfiJmJJpi/Aj0
oI0MF+7z9fXyJv/Zpvk1t7nUEjUf3AnIEM7zvwKvJfYlq3zF9S5x/+3qbTSzoZih9aiE2/khJ11L
74/kkMwXwgFJ4BGKRDshH2TfchSXyIUV4JyEnevRvXqKUlvUCnpet9BvuyHVKuULYfPnxJQEVzqf
/3fK/ylv+vlJ8oC2t/93d/f2BO//yPR0b92w//9M9v/G6S8bX5xWo13JLZjvz6EQJRIM2RrJd+g6
i6fCNv5gis9AWs9AFs/136ktHANCN374ieDOoX3AOGHG4moiMlGncbhaoctAQhk7S0YVL9eMSN3J
ToSuz2AFzlBrOsvCH92J5XNn86JjOqICZTre3PvaW7uHRjwXhZpd6aJI3C5AgnHYCOYBHQl4M5DT
fEH8dUNMgdwZWQSEHdUkOIqBlpz8XY0xF+vGrZbQejL0B/+NxzuV9xl+L4qF32/hF33owSPf93dE
+Ddz59L/jn51bt++3fOvCwAcIJdUIeHV62hxDH99G291PvnCOfGo+fKjxvJ9BAlTTP7t6eqlr90I
XeFFN3+Cg9KF3yq52bkIlSdJrGBUxXW8vBKk3C/d0rwkVuiFVUG3fzRt+r1AMPbH9ZV8R+Zm7dcy
4uJytqr1a7Izv63Ny/fmhmz7ipYp36Ln7drvgirNLASy14xnnu2XMHs22X6CP+FG62ijriu8N+ZI
d/ixI20inmX6OcmvzBRePVA5my1Y+WxWDXEOhaDiLpbRhMMiqxzdgFZQ/HzXjq/7p2KylXBnSn+H
8gouAYzMSmiCBCTCFGDcLHXRzk+oW75csSjNSsENI7OnIgOQmVx0hfMGJ0KvPL5GlvFvXPW2QnEl
ATyIvty5BU4eP3RevO96gwc0jK77IqXyi7gwHdYHOc3P+BP7qZ6UfzRmaeOrsY9w1LRi2FXgWCXq
y1cNgJJnv0ccyJjB/HuEe40P2hZpCH8CaBvL778yqLglpGs6fseblq3iIcMv8dMbmGHMA0RTLh+4
U+4+RKmXbnrPYsIgvKzJSm/d2nYIqqHl2gP4V+S4XZ7HbeMsPuQ7UNygZyZuFApCB3PMn/SBwrqb
D485J77gzM20oCLJJ6awuMaBUG4KDD/xFDShVrWybtix/9iPRVWIgCWQoSOmtgnIQ31Q873n7E4g
TGaUqpXj1WVYogsEhSyIW5vUpkXkiLyklbCw/GH9o+uYtQSzoirdmhO+kckASErs4bsDijSbXsmI
6Ij2rvnK4Yd3erdgSMTRPUN3YvHA/FHU7NaujTJ5oEY9FyI6WTv1MR/gbt7G3IzqeF3NT1E2NJ8X
SGw0ndw+1hlPyi/oCZabCVlDqfxaJkXXaZ+jMZyn59cZjeFHlRtlQZ2mJitWrWwrd4EhA0U1XAaK
KrbjnSJ4o5Nzq3MnvTADf4yByhdBsfrpv2H6HiLcXsqTpQWR0IaEAK6oR0woSxGaG/vvrlc1GQOz
ZCuAsucLstjJ8LQq16fhNIlpFn5MHicei6msl4+sBQKbKI/cGnnCWwUyrYEEN2TPl0g7cOlaBCrU
yC91M6pxkV4K7lDGB6WvtSIk1V5FwNmZqCvdQvFnkem83TD0f5pXFjxZfooTkpEAFxMJ2pK2VasQ
D4PHgEz7io+0ASnPxURdLkNsDlfi4tO5gwZyUMjykfTCb1N4kVdM39z1pnif2m2Waod1b/1gjJZb
ee2bFLwMuE/PAa6IJL/vy7/pAu62OpoeE+oyVbNXMbJlImBSrEbtFqqd6EvWK8CYCzwU4/Mng6IU
cY1nF5sPP2DEaplUOtUNUvzK0l0gYIF0/chA3Bd+/81H78E2WFk6VV9aYi5EHOfvX4VzNfrO3vGa
Sf6kpGjF0ZKSdQL/DaCbdbtE3qdBasBEz+Valiz/vA8ylBRWEV+Gd7/1xq49IwNYde/w0J6Rkd3Z
HTuHdvxxYAK1pvj4P/bufj3i8fCOfUP+Z0qrg28Gi+/cv394ZN+f3Af5mQKlMxT49VKF9kXepizs
OXJNEkpSRQuzEPJ3NlaS4abTfeKG76BWnx4q/vQiQ6eAgFoFmYEnVKfb6RCzsTWS/Yr1SYtBSUV5
rfnw08byMebSXA49DL50ELeKRTQ7UOjEr3/F0svUgRJsXi1p1PyZ0WWsvyauxtaSyZI1owUkFa2V
eKL9139pmD3I12hYctL8aUsiaxn5KUvDgBcm5Hy1Fp9ZK0tnG58tr165o2ZcwkRInF2O7mNg/tq7
/kYJdQlmoJSYk4hCuS3hog3Tm29NpyOkCXvKKBbR+5cGaOPYShYg3ixR2jlFbPS9i3sCG3N5/tcd
PtsHkmRgboWbMyuT6Du+SBIPwr9LVpIz6CanrGmR3JIARN93/OsZaxQOhxrA+Oe2+dmDXJeQjAVB
bGEaCBTyJy7t7Y23K5yfgoKxQLnozqNknHRmzUtZiC0QmjwWdDi/E16UTMcDH+Ms7QQEuPqN91av
nFOwKEFqPUZZInJgUuUQrJ+OKOI1oLz1Jd2XRWXifZhgv3+GvNeDHfasUqo8S5EX0AAGEaGihR7w
VWPimxp0yKlDYOPaRhKtKCJGK+C/wXtL6lG7RH6GGOp+xS9/OlfaZ71pefNIyigVbDT5xHTsUuwV
vGlAudlEhA1gUpzuaFrrqnG8VLLKxMUiXkbPURBx5VngpBARO/YO/3nXnjfw6+5dO+CQG4rI0OLB
xuOOoP8t8eYyWBzQixb0QGtBLPpQJNqLUl8ByMpxYBxmvf6f9+/cu2fX3qE9O/a+BgMbeGv/68lt
+NrIa2W+MVxrrQ0XF9Rpm/7l35DO8qT2RoDTUmOGxmZYWdqm/n8ZHty/s38Tonxzvx/+/s1x7be/
1eBfCTYUHdgUKEQNbIJyhp3LC2j86weB9d/F0bFm5ipp+vWnI5BFs7WSWaWjdhRTBo0dKL2maEbl
+YXHlrgJmtJTHij9R65UtQeEFiVpoe3ZSHHktHos0tE4OFE1KtFlXTgK7pEs4//cB7WJGe+lUYUp
gOaSAg9EU/llqN/REX4Bg9qPelurBHiwAL4hWAEjqPUfaHPWh5rjWlZ5YE0G4UBpn4G6aho4aqoG
Zg37QOmtN3P2wYF0euvWMKi72Eg6xpg1Cn+YHZiuFasmHZweYpX5pptz2k8fJ+Dk9D8BIxyCSPpr
e6AVc/RK89i6kVdZKcEZs0FQKUIbb0FrEs4DpTfwkPB+Rk5TYHKD217IKr5IXi9zd6jNfZzMClYQ
pZ+qVQzEHz0bMfIDPf653W1Om9U9e1/ftXtoIHR/EbW3x9pjzAxXzENATiZhCpib3JEr58bNolmd
/QMmxgCKPWJUBw6UhisWCsCs+BxAvZP7bCcwTwNBXpTlDvZv2D9dFu8R3oqZr4rb5l9HJ2sT+hb3
Wmjw9609u/7zR1iagmiubRxI+MlQq8OgjQFC2QWh2uEEYoWcAQxEEpgBYBz0diWNkgyqJYFCdR0K
mzheqR2E35+JDJ+0uv+iV/XxEForPaAOZqUIZc7wZ2T2a5exgKI8u6pcgOC//kl01DmgqUkz1HwZ
ERk68HEon/HVdtrWFl0ynVr98EX9LGajoLuvevu7ulQI+tV+/83DQH/LMQVEJ/T6t+1U9XCVbiah
CsG0GDBMUke46cbddN2NL047C99wbmDnyXfNBy8wy/ezOc6Jxpm8UfZu0XCrmxw4HZuaD9i9aBqT
Ji9/0rx9b+XpBziBMuEaArO8iE9OPMK72j8/Uz//nT+9mjQngEBw/Z6antpNNK35sPb93FFoWGs3
cwgQJSMXGs3Fx5Radq5++Zbz6P3I7jkFsHqv6/XP3fsEhPKHEkA0n3/pLH4AhcTNmYQTwBImY5cu
cI37FxsX7qK4TJkjIjtUk1fDMjpAxnJKuiK+ck4+8YNs0up3LZh0WLyUCW20Ud4aY+K5zMem8WPx
lHPSBJ7hQq9ffMS4kw9lphh8I7e3hEemlNFa2gC8IVXQPQ5zGMIfkYFRvCQ1kvjuJj8NzxMhDHXU
p24583fDnA6mwD9+v76ASfGdax+tzs1F6HXia12HQIRSsPIi2D1Kq9Eqrk4CS/tTvRGAtS6qXmXl
xTV2x/AD2Ca1DUnf/3Q+HnfQrbLuCOLyo2fd+e91/3dI7v5Z/f/S6Z6+dND/D+S7Df+/n+PzDqzb
TeyTtAl9kvCnz/gCT9+htb1J3DUHDzaR+WATK9A31SpFfDZVrZZt4AEmzepUbTyVt6YFsy7/iGVm
d0mtUBc1I14n6QdyqqnJv8im7alcd28ftt6X3t63dcLY2tM3Pp4ez23vmTAy3b357b1bt+S35Qrw
M58pdBe2bylkMoXt2zLj27ZmerZuH8cnxva+LZugwSMdRzp+sfHZ+Gx8Nj4bn43Pxmfjs/HZ+Gx8
Nj4bn43Pxmfjs/HZ+Gx8Nj4bn43Pxmfjs/HZ+Px//Pm/QiAu5gDwAAA=
SBM_SK5_PAYLOAD
python3 -c 'import hashlib,sys; assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==sys.argv[2],"内置程序包校验失败"' "$work/source.tar.gz" 4b288409a2bffb47ef2f575a3a28559d885b71b3addcade542e2ab1b613eb96e
tar -xzf "$work/source.tar.gz" -C "$work"
python3 "$work/app/sk5_install.py" --work "$work"
