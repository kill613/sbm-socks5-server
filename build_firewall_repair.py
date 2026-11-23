"""Generate a standalone firewall-only repair for existing installations."""
import argparse
import base64
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def render():
    module = (ROOT / 'app/sk5_firewall.py').read_text(encoding='utf-8').replace('\r\n', '\n').encode()
    payload = base64.b64encode(module).decode()
    checksum = hashlib.sha256(module).hexdigest()
    return '''#!/usr/bin/env bash
# Updates only firewall management. Keeps 3proxy, users, ports and VPN settings.
set -Eeuo pipefail
umask 077
export PYTHONIOENCODING=UTF-8
[[ $EUID -eq 0 ]] || { echo '请以root运行。' >&2; exit 1; }
for command in python3 nft systemctl flock sha256sum; do
  command -v "$command" >/dev/null || { echo "缺少 $command，未修改。" >&2; exit 1; }
done
module=/usr/local/libexec/sbm-sk5/sk5_firewall.py
relay_hook=/etc/systemd/system/sbm-relay-firewall.service.d/91-sk5-coexist.conf
order_hook=/etc/systemd/system/sbm-sk5-firewall.service.d/91-relay-order.conf
[[ -f "$module" && ! -L "$module" && -x /usr/local/bin/sk5 ]] || { echo '未找到本项目的已有SK5安装，未修改。' >&2; exit 1; }
[[ -f /etc/systemd/system/sbm-relay-firewall.service ]] || { echo '未找到中转防火墙服务，未修改。' >&2; exit 1; }
nft list table inet sbm_relay >/dev/null
exec 9>/run/lock/sbm-sk5-firewall-repair.lock
flock -n 9 || { echo '已有修复正在运行。' >&2; exit 1; }
backup=$(mktemp -d /root/sk5-firewall-repair-XXXXXX)
echo "备份目录：$backup"
nft -a list ruleset >"$backup/ruleset-before.nft"
systemctl cat sbm-relay-firewall.service sbm-sk5-firewall.service --no-pager >"$backup/units-before.txt"
cp -p -- "$module" "$backup/sk5_firewall.py"
for item in relay_hook order_hook; do
  target=${!item}
  [[ ! -L "$target" ]] || { echo "拒绝修改符号链接：$target" >&2; exit 1; }
  if [[ -e "$target" ]]; then cp -p -- "$target" "$backup/$item"; fi
done
cat <<'SK5_FIREWALL_PAYLOAD' | base64 --decode >"$backup/new-firewall.py"
'''+payload+'''
SK5_FIREWALL_PAYLOAD
printf '%s  %s\\n' '''+checksum+''' "$backup/new-firewall.py" | sha256sum -c -
python3 - "$backup/new-firewall.py" <<'SK5_CHECK'
import sys
from pathlib import Path
sys.path.insert(0, '/usr/local/libexec/sbm-sk5')
from common import private_json
import sk5
sk5.validate(private_json('/etc/sbm-sk5/settings.json'))
source = Path(sys.argv[1]).read_bytes()
compile(source, sys.argv[1], 'exec')
namespace = {'__name__': 'repair_preflight'}
exec(compile(source, sys.argv[1], 'exec'), namespace)
for key, text in [('RELAY_DROPIN', 'RELAY_HOOK'), ('ORDER_DROPIN', 'ORDER_HOOK')]:
    path = namespace[key]
    if path.exists() and path.read_text(encoding='utf-8') != namespace[text]:
        raise SystemExit('同名恢复文件不属于本工具，未修改：'+str(path))
SK5_CHECK
rollback() {
  local code=$?
  trap - ERR
  cp -p -- "$backup/sk5_firewall.py" "$module"
  for item in relay_hook order_hook; do
    target=${!item}
    if [[ -f "$backup/$item" ]]; then cp -p -- "$backup/$item" "$target"; else rm -f -- "$target"; fi
  done
  systemctl daemon-reload || true
  echo "修复未完成，已恢复管理模块和服务附加配置。端口规则可能已更新；未回灌整机防火墙。备份：$backup" >&2
  exit "$code"
}
trap rollback ERR
python3 - "$backup/new-firewall.py" <<'SK5_UPDATE'
import sys
from pathlib import Path
sys.path.insert(0, '/usr/local/libexec/sbm-sk5')
from common import atomic
atomic('/usr/local/libexec/sbm-sk5/sk5_firewall.py', Path(sys.argv[1]).read_bytes(), 0o750)
SK5_UPDATE
/usr/local/bin/sk5 firewall
trap - ERR
echo '已更新SK5端口规则及中转防火墙重启恢复配置；未重启SK5、WireGuard、HY2或L2TP。'
/usr/local/bin/sk5 check
nft -a list table inet sbm_relay
echo "本机自检完成；公网TCP/UDP仍需客户端实测。备份：$backup"
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    output = ROOT / 'repair-firewall.sh'
    if args.check:
        assert output.read_text(encoding='utf-8') == render(), '请重新生成repair-firewall.sh'
    else:
        output.write_text(render(), encoding='utf-8', newline='\n')
