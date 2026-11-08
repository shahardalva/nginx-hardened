"""Drop-in parity: same request to both images must give the same result."""
import http.client, socket

VOLATILE = {"date", "connection", "keep-alive"}  # legitimately differ


def _norm(headers):
    return {k.lower(): v for k, v in headers if k.lower() not in VOLATILE}


def _req(target, method, path, headers=None, body=None):
    host, port = target
    conn = http.client.HTTPConnection(host, port, timeout=5)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        r = conn.getresponse()
        return r.status, _norm(r.getheaders()), r.read()
    finally:
        conn.close()


def _raw(target, raw):
    host, port = target
    with socket.create_connection((host, port), timeout=5) as s:
        s.sendall(raw); s.shutdown(socket.SHUT_WR)
        out = b""
        while True:
            b = s.recv(4096)
            if not b: break
            out += b
        return out


def _parity(targets, method, path, headers=None, body=None):
    ref, hard = targets
    rs, rh, rb = _req(ref, method, path, headers, body)
    hs, hh, hb = _req(hard, method, path, headers, body)
    assert hs == rs, f"status {method} {path}: ref={rs} hard={hs}"
    assert hh == rh, f"headers {method} {path}:\n ref={rh}\n hard={hh}"
    assert hb == rb, f"body {method} {path}: {len(rb)} vs {len(hb)} bytes"


def test_root(targets):        _parity(targets, "GET", "/")
def test_not_found(targets):   _parity(targets, "GET", "/does-not-exist")
def test_head(targets):        _parity(targets, "HEAD", "/")
def test_bad_method(targets):  _parity(targets, "DELETE", "/")


def test_server_header_same_version(targets):
    ref, hard = targets
    _, rh, _ = _req(ref, "GET", "/")
    _, hh, _ = _req(hard, "GET", "/")
    assert rh.get("server") == hh.get("server") == "nginx/1.25.5"


def test_malformed_keeps_worker_alive(targets):
    ref, hard = targets
    garbage = b"GET /\x00 BOGUS/9.9\r\nHost: x\r\n\r\n"
    r = _raw(ref,  garbage).split(b"\r\n", 1)[0]
    h = _raw(hard, garbage).split(b"\r\n", 1)[0]
    assert r == h, f"malformed status line: {r!r} vs {h!r}"
    _parity(targets, "GET", "/")   # both still serve afterwards
