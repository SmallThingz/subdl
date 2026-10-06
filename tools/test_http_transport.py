#!/usr/bin/env python3
"""Two isolated loopback origins exercise the actual Zig HTTP transport."""
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading

requests = []
ZSTD_PUBLIC = bytes.fromhex('28 b5 2f fd 04 58 51 00 00 47 45 54 20 70 75 62 6c 69 63 4f d3 b0 26')
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def do_HEAD(self):
        self.do_GET()
    def log_message(self, *_):
        pass
    def do_POST(self):
        self.do_GET()
    def do_GET(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length:
            self.rfile.read(length)
        private = (self.headers.get('Cookie') == 'fixture=session'
                   and self.headers.get('Authorization') == 'Bearer fixture-only'
                   and self.headers.get('X-Api-Key') == 'fixture-api-key'
                   and self.headers.get('User-Agent') == 'fixture-secret-agent'
                   and self.headers.get('Accept-Encoding') == 'identity'
                   and self.headers.get('Content-Type') == 'application/x-fixture-secret')
        any_private = bool(self.headers.get('Cookie') or self.headers.get('Authorization')
                           or self.headers.get('X-Api-Key')
                           or self.headers.get('User-Agent') == 'fixture-secret-agent'
                           or self.headers.get('Connection') == 'close'
                           or self.headers.get('Accept-Encoding') == 'identity'
                           or self.headers.get('Content-Type') == 'application/x-fixture-secret')
        requests.append((self.server.role, self.path, self.command, any_private))
        destination = {
            '/same': '/echo', '/cross': other + '/echo',
            '/roundtrip': other + '/back', '/back': origin + '/echo',
            '/post': other + '/echo', '/loop': '/loop',
        }.get(self.path)
        if destination:
            self.send_response(303 if self.path == '/post' else 302)
            self.send_header('Location', destination)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path in ('/no-content', '/not-modified', '/head'):
            self.send_response({'/no-content': 204, '/not-modified': 304, '/head': 200}[self.path])
            if self.path != '/no-content':
                self.send_header('Content-Length', '12345')
            self.end_headers()
            return
        if self.path == '/early-hints':
            self.send_response_only(103)
            self.send_header('Link', '</synthetic>; rel=preload')
            self.end_headers()
        if self.path == '/too-many-hints':
            for _ in range(17):
                self.send_response_only(100)
                self.end_headers()
            self.close_connection = True
            return
        body = (self.command + (' private' if private else ' leaked' if any_private else ' public')).encode()
        if self.path in ('/gzip', '/gzip-chunked', '/gzip-wire-chunked', '/gzip-members', '/gzip-truncated', '/gzip-garbage'):
            body = gzip.compress(body)
        if self.path == '/gzip-members':
            body = gzip.compress(b'GET ') + gzip.compress(b'private')
        if self.path == '/gzip-garbage':
            body += b'garbage'
        if self.path == '/zstd':
            if 'zstd' not in self.headers.get('Accept-Encoding', '').lower():
                self.send_error(400, 'zstd was not advertised')
                return
            body = ZSTD_PUBLIC
        self.send_response(200)
        if self.path in ('/gzip-chunked', '/gzip-wire-chunked', '/gzip-truncated'):
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(len(body) + (100 if self.path == '/truncated' else 0)))
        if self.path in ('/gzip', '/gzip-chunked', '/gzip-wire-chunked', '/gzip-members', '/gzip-truncated', '/gzip-garbage'):
            self.send_header('Content-Encoding', 'gzip')
        if self.path == '/zstd':
            self.send_header('Content-Encoding', 'zstd')
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.path in ('/gzip-chunked', '/gzip-wire-chunked', '/gzip-truncated'):
            self.wfile.write(f'{len(body):x}\r\n'.encode() + body + (b'\r\n0\r\nX-Fixture: end\r\n\r\n' if self.path != '/gzip-truncated' else b'\r\n'))
        else:
            self.wfile.write(body)
        self.close_connection = True

servers = [ThreadingHTTPServer(('127.0.0.1', 0), Handler) for _ in range(2)]
origin, other = [f'http://127.0.0.1:{server.server_port}' for server in servers]
threads = []
try:
    for role, server in enumerate(servers):
        server.role = role
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        threads.append(thread)
    result = subprocess.run([sys.argv[1], origin], timeout=60, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode:
        raise SystemExit(result.returncode)
    assert 'HTTP_TRANSPORT_PASS cases=21' in result.stderr
    assert not any(private for role, _, _, private in requests if role == 1), requests
    assert any(role == 0 and path == '/echo' and not private for role, path, _, private in requests), requests
    print(f'HTTP_LOOPBACK_PASS requests={len(requests)} cross_origin_credentials=0')
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
    for thread in threads:
        thread.join()
