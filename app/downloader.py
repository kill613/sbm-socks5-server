"""Verified direct downloads with atomic publication."""
import hashlib
import os
from pathlib import Path
import re
import tempfile
import time
from urllib.parse import urlparse
from urllib.request import Request

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


def fetch(url, destination, expected, validator, opener):
    validator(url)
    if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
        raise ValueError('缺少固定的可信SHA-256，拒绝下载')
    destination = Path(destination)
    if destination.is_symlink():
        raise ValueError('下载目标不能是符号链接')
    fd, temporary = tempfile.mkstemp(prefix='.download-', dir=str(destination.parent))
    os.close(fd)
    try:
        print('尝试下载：'+urlparse(url).netloc, flush=True)
        request = Request(url, headers={'User-Agent': 'sbm-installer/2'})
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
        return url
    except (OSError, ValueError) as exc:
        print('本下载点失败：'+str(exc), flush=True)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    raise RuntimeError('官方直连下载失败，原文件保留')
