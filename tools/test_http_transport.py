#!/usr/bin/env python3
"""Two isolated loopback origins exercise the actual Zig HTTP transport."""
import gzip
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import subprocess
import sys
import threading
import time
import zlib

if len(sys.argv) != 2:
    raise SystemExit('usage: test_http_transport.py BINARY')

requests = []
requests_lock = threading.Lock()

def require(condition, message):
    if not condition:
        raise AssertionError(message)

def header_values(headers, name):
    return tuple(headers.get_all(name, []))

def gzip_bytes(data):
    return gzip.compress(data, mtime=0)

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def setup(self):
        super().setup()
        self.connection.settimeout(5)
    def do_HEAD(self):
        self.do_GET()
    def log_message(self, *_):
        pass
    def do_POST(self):
        self.do_GET()
    def do_GET(self):
        content_lengths = header_values(self.headers, 'Content-Length')
        if len(content_lengths) > 1:
            self.send_error(400, 'duplicate request Content-Length')
            self.close_connection = True
            return
        try:
            length = int(content_lengths[0]) if content_lengths else 0
        except ValueError:
            self.send_error(400, 'invalid request Content-Length')
            self.close_connection = True
            return
        if length < 0 or length > 64 * 1024:
            self.send_error(413, 'request body exceeds fixture limit')
            self.close_connection = True
            return
        payload = b''
        if length:
            payload = self.rfile.read(length)
            if len(payload) != length:
                self.close_connection = True
                return
        if self.command == 'POST' and (self.path != '/post' or payload != b'synthetic input'):
            self.send_error(400, 'unexpected fixture POST body')
            self.close_connection = True
            return
        cookies = header_values(self.headers, 'Cookie')
        authorizations = header_values(self.headers, 'Authorization')
        api_keys = header_values(self.headers, 'X-Api-Key')
        user_agents = header_values(self.headers, 'User-Agent')
        content_types = header_values(self.headers, 'Content-Type')
        transfer_encodings = header_values(self.headers, 'Transfer-Encoding')
        body_shape_valid = ((self.command == 'POST' and self.path == '/post'
                             and payload == b'synthetic input' and not transfer_encodings)
                            or (self.command != 'POST' and not payload and not transfer_encodings))
        private = (cookies == ('fixture=session',)
                   and authorizations == ('Bearer fixture-only',)
                   and api_keys == ('fixture-api-key',)
                   and user_agents == ('fixture-secret-agent',)
                   and content_types == ('application/x-fixture-secret',)
                   and body_shape_valid)
        any_private = bool(cookies or authorizations or api_keys or transfer_encodings
                           or payload
                           or any('fixture-secret-agent' in value for value in user_agents)
                           or any('application/x-fixture-secret' in value for value in content_types))
        accept_encodings = header_values(self.headers, 'Accept-Encoding')
        accept_encoding = ','.join(accept_encodings)
        with requests_lock:
            request_limit_exceeded = len(requests) >= 1024
            if not request_limit_exceeded:
                requests.append((self.server.role, self.path, self.command, any_private,
                                 accept_encodings, len(payload)))
        if request_limit_exceeded:
            self.send_error(508, 'fixture request limit exceeded')
            self.close_connection = True
            return
        destination = {
            '/same': '/echo', '/cross': other + '/echo',
            '/cross-strict': other + '/strict-target',
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
        if self.path == '/encoding-policy':
            encodings = {part.strip().lower() for part in accept_encoding.split(',') if part.strip()}
            if (len(accept_encodings) != 1 or 'gzip' not in encodings
                    or 'deflate' not in encodings or 'zstd' in encodings):
                self.send_error(400, 'unsafe or incomplete Accept-Encoding policy')
                return
        if self.path == '/identity' and (len(accept_encodings) != 1
                                         or accept_encoding.lower().strip() != 'identity'):
            self.send_error(400, 'identity override was not serialized exactly once')
            return
        if self.path == '/slow':
            time.sleep(3)
        body = (self.command + (' private' if private else ' leaked' if any_private else ' public')).encode()
        if self.path == '/chunked-cap':
            body = b'0123456789'
        gzip_paths = ('/gzip', '/gzip-chunked', '/gzip-wire-chunked', '/gzip-members',
                      '/gzip-truncated', '/gzip-garbage', '/gzip-bad-crc', '/gzip-bad-size')
        if self.path in gzip_paths:
            body = gzip_bytes(body)
        if self.path == '/gzip-members':
            body = gzip_bytes(b'GET ') + gzip_bytes(b'private')
        if self.path == '/gzip-garbage':
            # A complete synthetic next-member header makes the rejection
            # deterministic instead of depending on short-read diagnostics.
            body += b'garbage!!!'
        if self.path == '/gzip-bad-crc':
            body = body[:-8] + bytes([body[-8] ^ 1]) + body[-7:]
        if self.path == '/gzip-bad-size':
            body = body[:-4] + bytes([body[-4] ^ 1]) + body[-3:]
        if self.path in ('/deflate', '/deflate-bad-checksum'):
            body = zlib.compress(body)
        if self.path == '/deflate-bad-checksum':
            body = body[:-1] + bytes([body[-1] ^ 1])
        chunked_paths = ('/chunked', '/chunked-extension', '/chunked-cap',
                         '/chunked-truncated', '/chunk-invalid-size',
                         '/chunk-overflow-size', '/chunk-missing-crlf', '/te-cl',
                         '/gzip-chunked', '/gzip-wire-chunked', '/gzip-truncated')
        self.send_response(200)
        if self.path in chunked_paths:
            self.send_header('Transfer-Encoding', 'chunked')
            if self.path == '/te-cl':
                self.send_header('Content-Length', str(len(body)))
        elif self.path == '/duplicate-content-length':
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Content-Length', str(len(body)))
        elif self.path == '/content-length-overflow':
            self.send_header('Content-Length', '18446744073709551616')
        else:
            self.send_header('Content-Length', str(len(body) + (100 if self.path == '/truncated' else 0)))
        if self.path in gzip_paths:
            self.send_header('Content-Encoding', 'gzip')
        if self.path in ('/deflate', '/deflate-bad-checksum'):
            self.send_header('Content-Encoding', 'deflate')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            if self.path in ('/gzip-chunked', '/gzip-wire-chunked', '/gzip-truncated'):
                self.wfile.write(f'{len(body):x}\r\n'.encode() + body + (b'\r\n0\r\nX-Fixture: end\r\n\r\n' if self.path != '/gzip-truncated' else b'\r\n'))
            elif self.path in ('/chunked', '/chunked-cap', '/te-cl'):
                self.wfile.write(f'{len(body):x}\r\n'.encode() + body + b'\r\n0\r\n\r\n')
            elif self.path == '/chunked-extension':
                self.wfile.write(f'{len(body):x};fixture=yes\r\n'.encode() + body + b'\r\n0\r\nX-Fixture: end\r\n\r\n')
            elif self.path == '/chunked-truncated':
                self.wfile.write(f'{len(body) + 5:x}\r\n'.encode() + body)
            elif self.path == '/chunk-invalid-size':
                self.wfile.write(b'g\r\n' + body + b'\r\n0\r\n\r\n')
            elif self.path == '/chunk-overflow-size':
                self.wfile.write(b'10000000000000000\r\n')
            elif self.path == '/chunk-missing-crlf':
                self.wfile.write(f'{len(body):x}\r\n'.encode() + body + b'0\r\n\r\n')
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.close_connection = True

class FixtureServer(ThreadingHTTPServer):
    daemon_threads = True
    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (BrokenPipeError, ConnectionResetError, TimeoutError)):
            return
        super().handle_error(request, client_address)

servers = [FixtureServer(('127.0.0.1', 0), Handler) for _ in range(2)]
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
    require('HTTP_TRANSPORT_PASS checks=53' in result.stderr,
            'Zig transport fixture did not emit its completion marker')
    with requests_lock:
        observed = list(requests)
    require(not any(private for role, _, _, private, _, _ in observed if role == 1),
            f'cross-origin credentials or request body leaked: {observed!r}')
    require(any(role == 0 and path == '/echo' and not private
                for role, path, _, private, _, _ in observed),
            f'cross-origin round trip did not remain public: {observed!r}')
    require(any(role == 0 and path == '/post' and method == 'POST' and body_len == len(b'synthetic input')
                for role, path, method, _, _, body_len in observed),
            f'POST fixture did not receive the expected method and payload: {observed!r}')
    require(any(role == 0 and path == '/head' and method == 'HEAD'
                for role, path, method, _, _, _ in observed),
            f'HEAD fixture did not receive a HEAD request: {observed!r}')
    require(not any(path in ('/must-not-arrive', '/strict-target')
                    for _, path, _, _, _, _ in observed),
            f'locally rejected request reached a fixture server: {observed!r}')
    require(any(role == 0 and path == '/cross-strict' for role, path, _, _, _, _ in observed),
            f'same-origin policy probe did not reach its initial origin: {observed!r}')
    require(any(role == 0 and path == '/slow' for role, path, _, _, _, _ in observed),
            f'deadline probe expired before reaching the slow fixture: {observed!r}')
    require(any(path == '/encoding-policy' and len(encodings) == 1
                and 'zstd' not in encodings[0].lower()
                for _, path, _, _, encodings, _ in observed),
            f'default encoding policy was not observed exactly once: {observed!r}')
    require(any(path == '/identity' and len(encodings) == 1
                and encodings[0].lower().strip() == 'identity'
                for _, path, _, _, encodings, _ in observed),
            f'identity encoding override was not observed exactly once: {observed!r}')
    print(f'HTTP_LOOPBACK_PASS requests={len(observed)} cross_origin_credentials=0')
finally:
    for server in servers:
        server.shutdown()
        server.server_close()
    for thread in threads:
        thread.join()
