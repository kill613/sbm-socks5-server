"""共享安装工具；兼容Python3.6，以适配CentOS7的独立服务端。"""
import downloader
import errno
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import string
import subprocess
import tarfile
import tempfile
import time
from urllib.parse import urlparse
from urllib.request import Request, ProxyHandler, build_opener

HERE = Path(__file__).resolve().parent
MIRRORS = ('https://ghfast.top/', 'https://gh-proxy.com/', 'https://ghproxy.net/')
ALPHABET = string.ascii_letters.replace('O', '') + '123456789'
OPENER = build_opener(ProxyHandler({}))


def run(*args, **kwargs):
    options = dict(check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   universal_newlines=True, timeout=90)
    options.update(kwargs)
    return subprocess.run(list(args), **options)


def generated(length):
    if type(length) is not int or not 3 <= length <= 128:
        raise ValueError('随机凭据长度必须在3至128之间')
    while True:
        value = ''.join(secrets.choice(ALPHABET) for _ in range(length))
        if any(c.islower() for c in value) and any(c.isupper() for c in value) and any(c.isdigit() for c in value):
            return value


def credential(value, label, maximum=64):
    if not isinstance(value, str) or not 1 <= len(value) <= maximum or any(c not in ALPHABET for c in value):
        raise ValueError(label+'仅可使用英文字母和数字1至9，不含大写O、数字0或特殊符号')
    return value


def ipv4(value, public=False):
    address = ipaddress.IPv4Address(value)
    if public and (not address.is_global or address.is_multicast or address.is_reserved):
        raise ValueError('公网地址必须是可公开路由的IPv4地址')
    return str(address)


def port_available(port):
    if type(port) is not int or not 1024 <= port <= 65535:
        return False
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.bind(('0.0.0.0', port))
        try:
            with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
                sock.bind(('::', port))
        except OSError as exc:
            if exc.errno not in (errno.EAFNOSUPPORT, errno.EPROTONOSUPPORT, errno.EADDRNOTAVAIL):
                raise
        return True
    except OSError:
        return False


def random_port(excluded=(40000, 40999)):
    for _ in range(1000):
        port = 10000 + secrets.randbelow(55536)
        if not excluded[0] <= port <= excluded[1] and port_available(port):
            return port
    raise RuntimeError('未找到空闲的五位端口，请手动指定')


def network():
    # EL7's iproute can lack JSON output. Use the same read-only query in
    # its stable token form there; never guess an interface or gateway.
    result = run('ip', '-j', '-4', 'route', 'get', '223.5.5.5', check=False)
    if result.returncode == 0:
        route = json.loads(result.stdout)[0]
        addresses = json.loads(run('ip', '-j', '-4', 'addr', 'show', 'dev', route['dev']).stdout)
        candidates = [a for item in addresses for a in item.get('addr_info', [])
                      if a.get('family') == 'inet' and a.get('scope') == 'global']
    else:
        tokens = run('ip', '-4', 'route', 'get', '223.5.5.5').stdout.splitlines()[0].split()
        route = {'dev': tokens[tokens.index('dev')+1]}
        for field, key in (('src', 'prefsrc'), ('via', 'gateway')):
            if field in tokens:
                route[key] = tokens[tokens.index(field)+1]
        candidates = []
        for line in run('ip', '-o', '-4', 'addr', 'show', 'dev', route['dev'], 'scope', 'global').stdout.splitlines():
            fields = line.split()
            address, prefix = fields[fields.index('inet')+1].split('/')
            candidates.append({'local': address, 'prefixlen': int(prefix)})
    interface = route['dev']
    if not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
        raise ValueError('自动检测的网卡名称无效')
    address = next((a for a in candidates if a['local'] == route.get('prefsrc')), None)
    if address is None:
        if len(candidates) != 1:
            raise ValueError('默认网卡存在多个地址，需先明确默认出口源地址')
        address = candidates[0]
    return {'interface': interface, 'ip': address['local'],
            'address': address['local']+'/'+str(address['prefixlen']),
            'gateway': route.get('gateway', '')}


def udp_occupied():
    ports = set()
    for line in run('ss', '-H', '-l', '-u', '-n').stdout.splitlines():
        fields = line.split()
        if len(fields) >= 5:
            match = re.search(r':([0-9]+)$', fields[-2])
            if match:
                ports.add(int(match.group(1)))
    return ports


def public_address(local):
    if ipaddress.ip_address(local).is_global:
        return local
    found = []
    for url in ('https://4.ipw.cn', 'https://api.ipify.org'):
        try:
            with OPENER.open(Request(url, headers={'User-Agent': 'sbm-installer/1'}), timeout=5) as response:
                value = ipv4(response.read(128).decode('ascii').strip(), public=True)
            found.append(value)
        except (OSError, ValueError):
            continue
    if found and len(set(found)) == 1:
        return found[0]
    return ''


def atomic(path, data, mode=0o600):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='.sbm-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'wb') as stream:
            os.fchmod(stream.fileno(), mode)
            stream.write(data if isinstance(data, bytes) else data.encode('utf-8'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, str(path))
    finally:
        if os.path.exists(name):
            os.unlink(name)


def private_json(path):
    path = Path(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o077:
        raise ValueError('配置文件类型、root所有者或权限无效：'+str(path))
    return json.loads(path.read_text(encoding='utf-8'))


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def public_asset_url(url):
    p = urlparse(url)
    if p.scheme != 'https' or p.netloc != 'github.com' or p.query or p.fragment or not (
        p.path.startswith('/3proxy/3proxy/releases/download/')):
        raise ValueError('下载器仅接受指定公开内核的GitHub Release地址，不转发私有代码或凭据')


def probe(url):
    return downloader.probe(url, OPENER)


def fetch(url, destination, expected):
    return downloader.fetch(url, destination, expected, public_asset_url, OPENER,
                            mirrors=MIRRORS, probe_fn=probe)


def fetch_project(url, destination, expected):
    return downloader.fetch(url, destination, expected, downloader.project_url, OPENER,
                            mirrors=MIRRORS, probe_fn=probe)


def asset(name, work):
    lock = json.loads((HERE / 'release-lock.json').read_text(encoding='utf-8'))
    item = lock[name]
    destination = Path(work) / (name+'.tar.gz')
    fetch(item['url'], destination, item['sha256'])
    return destination


def extract(archive, destination):
    destination = Path(destination).resolve()
    destination.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tarfile.open(str(archive), 'r:gz') as tar:
        members = tar.getmembers()
        if len(members) > 30000 or sum(m.size for m in members) > 1024**3:
            raise ValueError('压缩包文件数量或解压大小异常')
        for member in members:
            target = (destination / member.name).resolve()
            if not str(target).startswith(str(destination)+os.sep) or not (member.isfile() or member.isdir()):
                raise ValueError('压缩包包含越界路径、链接或特殊文件')
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod(0o700 if member.mode & 0o111 else 0o600)
    return destination
