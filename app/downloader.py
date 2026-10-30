"""Public-file downloads: bounded probes, verified failover, atomic publication.

Vendored identically in the independent server project; never used for secrets,
private repositories, package-manager metadata or application API requests.
"""
import concurrent.futures
import hashlib
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlparse
from urllib.request import Request

MIRRORS = ('https://ghfast.top/', 'https://gh-proxy.com/', 'https://ghproxy.net/')
PROJECTS = {
    'sing-box-hy2-multiline': {'install-manager.sh', 'update-admin.sh', 'update-address-ui.sh', 'update-download-tools.sh',
                             'integrations/v4-ui/metrics.py', 'integrations/v4-ui/dashboard.js'},
    'sbm-socks5-server': {'install.sh'},
}


def project_url(url):
    p = urlparse(url)
    parts = p.path.strip('/').split('/')
    if (p.scheme != 'https' or p.netloc != 'raw.githubusercontent.com' or p.query or p.fragment
            or len(parts) < 4 or parts[0] != 'kill613' or parts[1] not in PROJECTS
            or not re.fullmatch(r'(?:main|[0-9a-f]{40})', parts[2])
            or '/'.join(parts[3:]) not in PROJECTS.get(parts[1], set())):
        raise ValueError('只允许指定公开项目文件，不代理私有数据、凭据或任意网址')


def probe(url, opener):
    started = time.monotonic()
    try:
        request = Request(url, headers={'Range': 'bytes=0-65535', 'User-Agent': 'sbm-installer/2'})
        with opener.open(request, timeout=7) as response:
            data = response.read(65536)
        if not data or data.lstrip().lower().startswith((b'<html', b'<!doctype', b'<?xml')):
            return None
        return len(data)/max(time.monotonic()-started, .001)
    except (OSError, ValueError):
        return None


def fetch(url, destination, expected, validator, opener, mirrors=MIRRORS, probe_fn=None):
    validator(url)
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('缺少固定的可信SHA-256，拒绝下载')
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError('下载目标不能是符号链接')
    print('正在检测中国加速点对本次实际文件的下载可用性……', flush=True)
    candidates = [base+url for base in mirrors]
    scores = []
    check = probe_fn or (lambda value: probe(value, opener))
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(check, candidate): candidate for candidate in candidates}
        for future in concurrent.futures.as_completed(futures):
            try:
                score = future.result()
            except Exception:
                score = None
            if score is not None:
                scores.append((score, futures[future]))
    # A blocked Range request must not suppress an otherwise usable mirror.
    ranked = [value for _, value in sorted(scores, reverse=True)]
    ordered = ranked+[value for value in candidates if value not in ranked]+[url]
    for candidate in ordered:
        fd, temporary = tempfile.mkstemp(prefix='.download-', dir=str(destination.parent))
        os.close(fd)
        try:
            print('尝试下载：'+urlparse(candidate).netloc, flush=True)
            request = Request(candidate, headers={'User-Agent': 'sbm-installer/2'})
            deadline = time.monotonic()+240
            checksum = hashlib.sha256()
            with opener.open(request, timeout=20) as response, open(temporary, 'wb') as stream:
                total = 0
                while True:
                    block = response.read(256*1024)
                    if not block:
                        break
                    total += len(block)
                    if total > 256*1024*1024 or time.monotonic() > deadline:
                        raise ValueError('文件大小或下载时间超出限制')
                    checksum.update(block); stream.write(block)
            if checksum.hexdigest() != expected:
                raise ValueError('SHA-256不匹配，拒绝使用该下载点返回的文件')
            os.replace(temporary, str(destination))
            print('下载成功，固定SHA-256校验通过。', flush=True)
            return candidate
        except (OSError, ValueError) as exc:
            print('本下载点失败：'+str(exc), flush=True)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    raise RuntimeError('所有加速点及官方直连均未成功；原文件保持，未安装未校验内容')


def pip_install(run, python, requirements):
    for index in ('https://pypi.tuna.tsinghua.edu.cn/simple',
                  'https://mirrors.ustc.edu.cn/pypi/simple', 'https://pypi.org/simple'):
        print('尝试Python依赖源：'+index, flush=True)
        result = run(str(python), '-m', 'pip', 'install', '--disable-pip-version-check',
                     '--timeout', '20', '--retries', '1', '--index-url', index,
                     '-r', str(requirements), timeout=900, check=False)
        if result.returncode == 0:
            return
        print('当前Python源安装失败，自动换源；不禁用TLS验证。', flush=True)
    raise RuntimeError('全部Python依赖源失败，停止安装；请查看依赖版本和网络')
