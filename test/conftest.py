"""Boots the reference and hardened containers on ephemeral ports."""
import os, time
import http.client
import docker
import pytest

REFERENCE_IMAGE = os.environ.get("REFERENCE_IMAGE", "nginx:1.25-bookworm")
HARDENED_IMAGE  = os.environ.get("HARDENED_IMAGE", "nginx-hardened:latest")


def _wait_http(host, port, timeout=30):
    """Wait until nginx actually answers an HTTP request, not just TCP."""
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            conn = http.client.HTTPConnection(host, port, timeout=2)
            conn.request("GET", "/")
            conn.getresponse().read()
            conn.close()
            return
        except Exception as e:
            last = e
            time.sleep(0.3)
    raise TimeoutError(f"{host}:{port} not ready: {last}")


def _free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _start(client, image, port):
    c = client.containers.run(image, detach=True, remove=True,
                              ports={"80/tcp": ("127.0.0.1", port)})
    _wait_http("127.0.0.1", port)
    return c


@pytest.fixture(scope="session")
def targets():
    client = docker.from_env()
    containers = []
    try:
        rp, hp = _free_port(), _free_port()
        containers.append(_start(client, REFERENCE_IMAGE, rp))
        containers.append(_start(client, HARDENED_IMAGE, hp))
        yield ("127.0.0.1", rp), ("127.0.0.1", hp)
    finally:
        for c in containers:
            try: c.stop(timeout=3)
            except Exception: pass
