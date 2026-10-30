"""CI下载固定官方SHA的源码并编译，仅输出临时二进制路径。"""
from pathlib import Path
import os
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))
import common

work = Path(os.environ['SBM_BUILD_DIR'])
work.mkdir(parents=True, exist_ok=True)
archive = common.asset('3proxy-source', work)
source = common.extract(archive, work / 'source')
make = list(source.glob('*/Makefile.Linux'))
assert len(make) == 1, '源码结构异常'
source = make[0].parent
from core_patch import apply
apply(source)
result = common.run('make', '-f', 'Makefile.Linux', '-j2', 'PLUGINS=', 'OPENSSL_CHECK=false',
    'WOLFSSL_CHECK=false', 'PCRE_CHECK=false', 'PAM_CHECK=false', 'HTTPSRV=false',
    cwd=str(source), timeout=600, check=False)
if result.returncode:
    print(result.stdout, result.stderr)
    raise SystemExit('服务端编译失败')
binary = source / 'bin/3proxy'
assert binary.is_file()
with open(os.environ['GITHUB_ENV'], 'a') as stream:
    stream.write('SBM_SK5_BINARY='+str(binary.resolve())+'\n')
