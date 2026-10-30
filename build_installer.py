"""生成无需克隆仓库的单文件安装器；payload固定SHA并可重现构建。"""
import argparse
import base64
import gzip
import hashlib
import io
from pathlib import Path
import tarfile
import textwrap

ROOT = Path(__file__).resolve().parent


def render():
    files = sorted((ROOT / 'app').glob('*.py'))+[ROOT / 'app/release-lock.json']
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for path in files:
            content = path.read_text(encoding='utf-8').replace('\r\n', '\n').encode()
            info = tarfile.TarInfo('app/'+path.name)
            info.size = len(content); info.mode = 0o600; info.mtime = 0
            tar.addfile(info, io.BytesIO(content))
    packed = gzip.compress(raw.getvalue(), compresslevel=9, mtime=0)
    # Python3.11 gzip.compress can emit an OS byte different to 3.13; normalize
    # that informational header field for byte-identical committed installers.
    packed = packed[:9]+b'\xff'+packed[10:]
    checksum = hashlib.sha256(packed).hexdigest()
    bootstrap = (ROOT / 'bootstrap.sh').read_text(encoding='utf-8').replace('\r\n', '\n')
    ending = '\n'.join(textwrap.wrap(base64.b64encode(packed).decode('ascii'), 76))
    return bootstrap+'''\n# 以下程序包由build_installer.py生成；可审阅app/中的明文源码。
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
'''+ending+'''
SBM_SK5_PAYLOAD
python3 -c 'import hashlib,sys; assert hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest()==sys.argv[2],"内置程序包校验失败"' "$work/source.tar.gz" '''+checksum+'''
tar -xzf "$work/source.tar.gz" -C "$work"
python3 "$work/app/sk5_install.py" --work "$work"
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='检查已提交安装器与明文源码完全一致')
    args = parser.parse_args()
    output = ROOT / 'install.sh'
    if args.check:
        if output.read_text(encoding='utf-8') != render():
            raise SystemExit('install.sh已过期，请先运行python3 build_installer.py')
        print('单文件安装器与明文源码一致')
    else:
        output.write_text(render(), encoding='utf-8', newline='\n')
        print('已生成单文件安装器：'+str(output))
