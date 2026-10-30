"""真实3proxy内核TCP/UDP回环测试，独立临时配置，不操作systemd或防火墙。"""
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'app'))
import common
import sk5


class WireTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.port = common.random_port((20000, 20999))
        cls.config = {'schema': 1, 'interface': 'lo', 'local_ip': '127.0.0.1',
            'public_ip': '223.5.5.5', 'port': cls.port, 'udp_first': 20000, 'udp_last': 20003,
            'users': [{'name': 'FixtureUser1', 'password': 'AbcdefGh123456789p'},
                      {'name': 'FixtureUser2', 'password': 'AbcdefGh123456789q'}]}
        path = Path(cls.temp.name) / '3proxy.cfg'
        path.write_text('log\n'+sk5.render(cls.config))
        cls.log = (Path(cls.temp.name) / 'proxy.log').open('w')
        cls.process = subprocess.Popen([os.environ['SBM_SK5_BINARY'], str(path)], stdout=cls.log, stderr=cls.log)
        try:
            sk5.health(cls.config)
        except Exception:
            cls.process.terminate(); cls.process.wait(5); cls.log.close()
            print((Path(cls.temp.name) / 'proxy.log').read_text(), file=sys.stderr)
            raise

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate(); cls.process.wait(5); cls.log.close(); cls.temp.cleanup()

    def test_authenticated_tcp_real_payload_and_second_account(self):
        with socket.socket() as echo:
            echo.bind(('127.0.0.1', 0)); echo.listen(1)
            def serve():
                connection, _ = echo.accept()
                with connection:
                    connection.sendall(connection.recv(100))
            worker = threading.Thread(target=serve, daemon=True); worker.start()
            with socket.create_connection(('127.0.0.1', self.port), timeout=3) as sock:
                sock.settimeout(3); sk5.auth(sock, self.config['users'][1])
                sock.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('!H', echo.getsockname()[1]))
                sk5.reply(sock); sock.sendall(b'sbm-real-tcp-echo')
                self.assertEqual(sk5.read_exact(sock, 17), b'sbm-real-tcp-echo')
            worker.join(3)

    def test_udp_public_advertisement_fixed_pool_and_real_payload(self):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as echo:
            echo.bind(('127.0.0.1', 0)); echo.settimeout(4)
            def serve():
                data, sender = echo.recvfrom(1024); echo.sendto(data, sender)
            worker = threading.Thread(target=serve, daemon=True); worker.start()
            with socket.create_connection(('127.0.0.1', self.port), timeout=3) as tcp:
                tcp.settimeout(3); sk5.auth(tcp, self.config['users'][0])
                tcp.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
                public, relay = sk5.reply(tcp)
                self.assertEqual(public, self.config['public_ip'])
                self.assertTrue(20000 <= relay <= 20003)
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                    udp.settimeout(4)
                    payload = b'sbm-real-udp-echo'
                    udp.sendto(b'\x00\x00\x00\x01'+socket.inet_aton('127.0.0.1')+
                        struct.pack('!H', echo.getsockname()[1])+payload, ('127.0.0.1', relay))
                    received, _ = udp.recvfrom(1024)
                    self.assertEqual(received[:4], b'\x00\x00\x00\x01')
                    self.assertEqual(received[10:], payload)
            worker.join(3)

    def test_no_auth_and_wrong_password_are_rejected(self):
        with socket.create_connection(('127.0.0.1', self.port), timeout=3) as sock:
            sock.settimeout(3); sock.sendall(b'\x05\x01\x00')
            self.assertEqual(sk5.read_exact(sock, 2), b'\x05\xff')
        with socket.create_connection(('127.0.0.1', self.port), timeout=3) as sock:
            sock.settimeout(3)
            sk5.auth(sock, {'name': 'FixtureUser1', 'password': 'WrongPass123'})
            sock.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
            with self.assertRaises(RuntimeError):
                sk5.reply(sock)

    def test_z_exhausted_pool_fails_without_escaping_to_ephemeral_ports(self):
        import time
        time.sleep(0.4)
        sockets = []
        try:
            for port in range(20000, 20004):
                udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                udp.bind(('127.0.0.1', port)); sockets.append(udp)
            with socket.create_connection(('127.0.0.1', self.port), timeout=3) as sock:
                sock.settimeout(3); sk5.auth(sock, self.config['users'][0])
                sock.sendall(b'\x05\x03\x00\x01'+b'\x00'*6)
                with self.assertRaises(RuntimeError):
                    sk5.reply(sock)
        finally:
            for udp in sockets:
                udp.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
