"""Starts the reference and hardened images as separate containers for the tests."""
import http.client
import os
import time

import docker
import pytest

REFERENCE_IMAGE = os.environ.get("REFERENCE_IMAGE", "nginx:1.25-bookworm")
HARDENED_IMAGE = os.environ.get("HARDENED_IMAGE", "nginx-hardened:latest")

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
SITE = os.path.join(HERE, ".site")
BIG_FILE_SIZE = 5 * 1024 * 1024


def _wait_http(host, port, timeout=30):
    """Wait until nginx answers an HTTP request, not just until the port opens."""
    end = time.time() + timeout
    last = None
    while time.time() < end:
        try:
            conn = http.client.HTTPConnection(host, port, timeout=2)
            conn.request("GET", "/")
            conn.getresponse().read()
            conn.close()
            return
        except Exception as e:  # not ready yet
            last = e
            time.sleep(0.3)
    raise TimeoutError(f"{host}:{port} not ready: {last}")


def _start(client, image, volumes):
    # Docker picks the host port: a port that looks free inside WSL can still be
    # reserved on the Windows side, and picking it ourselves is also racy.
    container = client.containers.run(
        image, detach=True, ports={"80/tcp": ("127.0.0.1", None)}, volumes=volumes)
    try:
        container.reload()
        port = int(container.attrs["NetworkSettings"]["Ports"]["80/tcp"][0]["HostPort"])
        _wait_http("127.0.0.1", port)
    except Exception:
        logs = container.logs().decode(errors="replace")
        container.remove(force=True)
        raise RuntimeError(f"{image} did not start:\n{logs}")
    return container, ("127.0.0.1", port)


def _pair(volumes=None):
    """Yield (reference, hardened) targets started with the same volumes."""
    client = docker.from_env()
    started = []
    try:
        for image in (REFERENCE_IMAGE, HARDENED_IMAGE):
            started.append(_start(client, image, volumes or {}))
        yield started[0][1], started[1][1]
    finally:
        for container, _ in started:
            try:
                container.remove(force=True)
            except Exception:
                pass


@pytest.fixture(scope="session")
def docker_client():
    return docker.from_env()


@pytest.fixture(scope="session")
def targets():
    """Both images with their default configuration."""
    yield from _pair()


@pytest.fixture(scope="session")
def site_dir():
    """Static files served by the custom configuration, including a 5 MiB file."""
    os.makedirs(SITE, exist_ok=True)
    os.chmod(SITE, 0o755)
    files = {
        "index.html": b"<h1>custom config</h1>\n",
        "big.bin": bytes(range(256)) * (BIG_FILE_SIZE // 256),
    }
    for name, data in files.items():
        path = os.path.join(SITE, name)
        with open(path, "wb") as f:
            f.write(data)
        os.chmod(path, 0o644)
    return SITE


@pytest.fixture(scope="session")
def custom_targets(site_dir):
    """Both images with the same custom nginx.conf, which loads every dynamic module."""
    volumes = {
        os.path.join(FIXTURES, "nginx.conf"): {"bind": "/etc/nginx/nginx.conf", "mode": "ro"},
        os.path.join(FIXTURES, "js"): {"bind": "/etc/nginx/js", "mode": "ro"},
        site_dir: {"bind": "/srv/site", "mode": "ro"},
    }
    yield from _pair(volumes)
