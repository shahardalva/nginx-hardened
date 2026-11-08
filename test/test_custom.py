"""Drop-in parity beyond the default configuration.

* HTTP tests: both images run the same custom nginx.conf (test/fixtures/nginx.conf),
  which loads every dynamic module the official image ships.
* Image tests: build arguments, binaries, modules and image metadata.
"""
import shlex

from conftest import BIG_FILE_SIZE, HARDENED_IMAGE, REFERENCE_IMAGE
from test_compat import _parity, _req

EXPECTED_MODULES = sorted(
    f"{name}{suffix}.so"
    for name in (
        "ngx_http_geoip_module", "ngx_stream_geoip_module",
        "ngx_http_image_filter_module", "ngx_http_xslt_filter_module",
        "ngx_http_js_module", "ngx_stream_js_module",
    )
    for suffix in ("", "-debug")
)


# ---- HTTP behaviour with a custom configuration ---------------------------

def test_custom_root(custom_targets):
    _parity(custom_targets, "GET", "/")


def test_custom_add_header(custom_targets):
    for target in custom_targets:
        _, headers, _ = _req(target, "GET", "/")
        assert headers.get("x-compat-test") == "custom"


def test_njs_module(custom_targets):
    _parity(custom_targets, "GET", "/njs")
    _, _, body = _req(custom_targets[1], "GET", "/njs")
    assert body == b"njs 0.8.4\n"


def test_large_response_body(custom_targets):
    _parity(custom_targets, "GET", "/big.bin")
    status, _, body = _req(custom_targets[1], "GET", "/big.bin")
    assert status == 200 and len(body) == BIG_FILE_SIZE


def test_range_request(custom_targets):
    _parity(custom_targets, "GET", "/big.bin", headers={"Range": "bytes=100-199"})


def test_large_request_body(custom_targets):
    body = b"x" * (2 * 1024 * 1024)
    _parity(custom_targets, "POST", "/upload", body=body)
    _, _, resp = _req(custom_targets[1], "POST", "/upload", body=body)
    assert resp == b"2097152\n"


def test_request_body_over_limit(custom_targets):
    _parity(custom_targets, "POST", "/small", body=b"x" * 4096)
    status, _, _ = _req(custom_targets[1], "POST", "/small", body=b"x" * 4096)
    assert status == 413


# ---- Image, binaries and modules -------------------------------------------

def _run(client, image, *cmd):
    """Run a one-off command in the image; return (exit code, stdout + stderr)."""
    container = client.containers.run(image, list(cmd), detach=True)
    try:
        status = container.wait()["StatusCode"]
        out = container.logs(stdout=True, stderr=True).decode(errors="replace")
    finally:
        container.remove(force=True)
    return status, out


def _configure_args(nginx_v_output):
    line = next(l for l in nginx_v_output.splitlines() if l.startswith("configure arguments:"))
    args = shlex.split(line.split(":", 1)[1])
    return [a for a in args if not a.startswith("--with-cc-opt=")]


def test_configure_arguments_match(docker_client):
    _, ref_out = _run(docker_client, REFERENCE_IMAGE, "nginx", "-V")
    _, hard_out = _run(docker_client, HARDENED_IMAGE, "nginx", "-V")
    ref, hard = _configure_args(ref_out), _configure_args(hard_out)
    assert hard == ref


def test_nginx_debug_binary(docker_client):
    for image in (REFERENCE_IMAGE, HARDENED_IMAGE):
        status, out = _run(docker_client, image, "nginx-debug", "-t")
        assert status == 0 and "test is successful" in out, f"{image}: {out}"


def test_dynamic_modules_present(docker_client):
    for image in (REFERENCE_IMAGE, HARDENED_IMAGE):
        status, out = _run(docker_client, image, "ls", "/usr/lib/nginx/modules")
        assert status == 0 and sorted(out.split()) == EXPECTED_MODULES, f"{image}: {out}"


def test_image_config_matches(docker_client):
    keys = ("User", "WorkingDir", "ExposedPorts", "Entrypoint", "Cmd", "StopSignal", "Env")
    ref = docker_client.images.get(REFERENCE_IMAGE).attrs["Config"]
    hard = docker_client.images.get(HARDENED_IMAGE).attrs["Config"]
    for key in keys:
        assert hard.get(key) == ref.get(key), f"{key}: ref={ref.get(key)} hard={hard.get(key)}"


def test_entrypoint_enables_ipv6(docker_client):
    """The entrypoint adds `listen [::]:80` only if default.conf matches the packaged version."""
    script = ("/docker-entrypoint.sh nginx -t >/dev/null 2>&1; "
              "grep -c 'listen  \\[::\\]:80;' /etc/nginx/conf.d/default.conf")
    for image in (REFERENCE_IMAGE, HARDENED_IMAGE):
        _, out = _run(docker_client, image, "sh", "-c", script)
        assert out.strip().splitlines()[-1] == "1", f"{image}: {out}"


# Packages allowed to differ between the images, each with its reason.
# Empty: the hardened image installs exactly the official package set.
PACKAGE_DIFF_ALLOWLIST = {}


def _packages(client, image):
    status, out = _run(client, image, "dpkg-query", "-W", r"-f=${Package}\n")
    assert status == 0, f"{image}: {out}"
    return set(out.split())


def test_installed_packages_match(docker_client):
    """Same Debian packages in both images, so tools such as curl (healthchecks) exist."""
    ref = _packages(docker_client, REFERENCE_IMAGE)
    hard = _packages(docker_client, HARDENED_IMAGE)
    allowed = set(PACKAGE_DIFF_ALLOWLIST)
    only_ref = sorted(ref - hard - allowed)
    only_hard = sorted(hard - ref - allowed)
    assert only_ref == [] and only_hard == [], (
        f"only in reference: {only_ref}; only in hardened: {only_hard}")


# Paths allowed to exist in only one image, each with its reason.
# Empty: every file of the official nginx* packages is present, and nothing extra.
FILE_DIFF_ALLOWLIST = {}

_PKG_FILES = ("for p in $(dpkg-query -W -f='${Package}\\n' 'nginx*'); do "
              "dpkg -L \"$p\" 2>/dev/null; done | sort -u")
_EXISTING = 'for f in "$@"; do if [ -e "$f" ] || [ -L "$f" ]; then echo "$f"; fi; done'


def _package_paths(client, image):
    status, out = _run(client, image, "sh", "-c", _PKG_FILES)
    assert status == 0, f"{image}: {out}"
    return set(out.split())


def _existing(client, image, paths):
    status, out = _run(client, image, "sh", "-c", _EXISTING, "sh", *sorted(paths))
    assert status == 0, f"{image}: {out}"
    return set(out.split())


def test_package_files_match(docker_client):
    """Every path owned by an nginx* package in either image exists in both or in neither
    (paths that the slim base excludes, such as docs, are absent from both)."""
    paths = (_package_paths(docker_client, REFERENCE_IMAGE)
             | _package_paths(docker_client, HARDENED_IMAGE))
    ref = _existing(docker_client, REFERENCE_IMAGE, paths)
    hard = _existing(docker_client, HARDENED_IMAGE, paths)
    allowed = set(FILE_DIFF_ALLOWLIST)
    only_ref = sorted(ref - hard - allowed)
    only_hard = sorted(hard - ref - allowed)
    assert only_ref == [] and only_hard == [], (
        f"only in reference: {only_ref}; only in hardened: {only_hard}")
