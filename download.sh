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
