"""在远端测试真实TCP/UDP DNS，不修改面板、路由或云服务器。Python3标准库即可。"""
import getpass
import ipaddress
import secrets
import socket
import struct
import sys

from sk5 import auth, read_exact, reply


def query():
    identifier = secrets.token_bytes(2)
    question = b'\x03www\x05baidu\x03com\x00\x00\x01\x00\x01'
    return identifier+b'\x01\x00\x00\x01'+b'\x00'*6+question


def answer(data, request):
    if len(data) < 12 or data[:2] != request[:2]:
        raise RuntimeError('DNS回复长度或事务ID不匹配')
    flags, questions, answers = struct.unpack('!HHH', data[2:8])
    if not flags & 0x8000 or flags & 0xf or not answers:
        raise RuntimeError('DNS回复未包含成功的答案')
    return answers


def main():
    server = str(ipaddress.IPv4Address(input('SOCKS5公网IPv4：').strip()))
    port = int(input('TCP入口端口：').strip())
    if not 1 <= port <= 65535:
        raise ValueError('端口无效')
    user = {'name': input('账户：').strip(), 'password': getpass.getpass('密码（隐藏输入）：')}
    passed = []
    for protocol in ('TCP', 'UDP'):
        try:
            request = query()
            with socket.create_connection((server, port), timeout=8) as tcp:
                tcp.settimeout(8); auth(tcp, user)
                if protocol == 'TCP':
                    tcp.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('223.5.5.5')+struct.pack('!H', 53))
                    reply(tcp)
                    tcp.sendall(struct.pack('!H', len(request))+request)
                    data = read_exact(tcp, struct.unpack('!H', read_exact(tcp, 2))[0])
                else:
                    tcp.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
                    relay, relay_port = reply(tcp)
                    if not ipaddress.ip_address(relay).is_global:
                        raise RuntimeError('服务端返回不可从公网访问的中继地址：'+relay)
                    print('服务端通告UDP中继：'+relay+':'+str(relay_port))
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                        udp.settimeout(8)
                        udp.sendto(b'\x00\x00\x00\x01'+socket.inet_aton('223.5.5.5')+struct.pack('!H', 53)+request,
                                   (relay, relay_port))
                        packet, sender = udp.recvfrom(4096)
                    if sender != (relay, relay_port) or packet[:4] != b'\x00\x00\x00\x01' or packet[4:10] != socket.inet_aton('223.5.5.5')+struct.pack('!H', 53):
                        raise RuntimeError('UDP回复中继来源或DNS目标不匹配')
                    data = packet[10:]
                count = answer(data, request)
                print(protocol+' DNS真实收发通过，答案数：'+str(count))
                passed.append(protocol)
        except (OSError, ValueError, RuntimeError) as exc:
            print(protocol+' DNS未通过：'+str(exc))
    print('本次探测仅证明此机器到所填SOCKS5的对应协议；Windows透明分流仍需单独验证。')
    return 0 if passed == ['TCP', 'UDP'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print('测试未执行：'+str(exc), file=sys.stderr)
        sys.exit(1)
