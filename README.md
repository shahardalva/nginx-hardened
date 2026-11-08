# nginx-hardened

A drop-in replacement for the official **`nginx:1.25-bookworm`** image. nginx
1.25.5, `nginx-debug` and the dynamic modules the official image ships (njs,
geoip, image-filter, xslt) are rebuilt from source on `debian:bookworm-slim`
and packaged as `.deb`s. CVEs are remediated with two techniques: a
**backported upstream patch** and a **dependency version bump**. Scanner
findings that do not apply to this image are documented with **OpenVEX**
statements. VEX records why a finding does not apply; it does not fix anything.

## Quick start

```bash
make all     # build the .debs from source, build the image, run the compatibility tests
make scan    # Trivy + Grype on the hardened image -> reports/hardened-*.txt
```

| Target | What it does |
|--------|--------------|
| `make deb` | compiles nginx, nginx-debug and the modules in a clean `debian:bookworm-slim` builder -> `dist/*.deb` |
| `make image` | builds `nginx-hardened:latest` from `Containerfile` and `dist/*.deb` |
| `make test` | runs the compatibility suite in `test/` against both images |
| `make scan` | Trivy and Grype scans of the hardened image into `reports/` |
| `make triage` | Trivy JSON scans of both images + `scripts/triage.py` → `reports/triage.csv`, `docs/TRIAGE-SUMMARY.md` |
| `make all` | `deb` + `image` + `test` |
| `make clean` | removes `dist/` and the built images |

`make clean && make all` was run from a clean state: the build completed and all
18 tests passed.

**Prerequisites:** Docker, Python 3 with `pytest` and the `docker` SDK, Trivy, Grype.

**Scanner notes.**
- **Trivy** runs with `--pkg-types os`. Without it, Trivy also downloads its
  Java database, and that download stalled on my machine. Grype catalogues all
  package types; the findings it reported for the baseline image are
  all for packages of these types: deb (789 findings).
- **Grype**'s built-in database download hung, although the same file
  downloaded with `curl` at about 37 MB/s. Workaround: fetch the database listed
  in `https://grype.anchore.io/databases/v6/latest.json` with `curl`, load it
  with `grype db import`, and run Grype with `GRYPE_DB_AUTO_UPDATE=false`. I ran
  Grype from its official container image (`anchore/grype`) with the repository
  mounted as the working directory, so that `--vex vex/vex.openvex.json`
  resolves.
- Later in the session Grype became very slow on this machine: a scan of either
  image produced no result within 15 minutes, with no shortage of memory. I did
  not find the cause, so the Grype reports come from earlier runs (section 1).

## 1. What was fixed, and how

### Remediated CVEs

| CVE | Severity | Component | Technique | Evidence |
|-----|----------|-----------|-----------|----------|
| **CVE-2026-15176** | Critical | nginx `ngx_http_core_module` (`ngx_http_map_uri_to_path`) | **Backport**: upstream commit `f8a23425b` (released in nginx 1.31.7) applied to 1.25.5 | `build/patches/CVE-2026-15176.patch`, `poc/prove-cve-2026-15176.sh`, `reports/cve-2026-15176-proof.txt` |
| **CVE-2026-31789** | Critical | `libssl3` / `openssl` (OS packages) | **Version bump**: `libssl3` 3.0.11-1~deb12u2 → 3.0.22-1~deb12u2 (Debian fixed it in 3.0.19-1~deb12u2) | present in `reports/baseline-trivy.txt` (2 rows), absent from `reports/hardened-trivy.txt` |

The same OpenSSL bump closes most of the other OpenSSL findings: Trivy reports
98 rows mentioning `libssl3`/`openssl` in the baseline and
2 in the hardened image. The remaining ones are CVE-2025-27587,
covered by VEX below. Why the bump upgrades the system library rather than
compiling OpenSSL into nginx is explained in `docs/TRIAGE.md`.

### VEX statements (`vex/vex.openvex.json`)

| CVE | Flagged by | VEX status | Justification | Evidence |
|-----|-----------|------------|---------------|----------|
| CVE-2026-15176 | Grype | `fixed` | Backported (above). The version string is still 1.25.5, so scanners keep flagging it. | `reports/grype-vex-proof.txt` |
| CVE-2026-93479 | Grype | `not_affected` | `vulnerable_code_not_present`: the vulnerable code was added after 1.25.5 | `docs/TRIAGE.md`, `reports/grype-vex-proof.txt` |
| CVE-2025-27587 | Trivy | `not_affected` | `vulnerable_code_not_in_execute_path`: affects PowerPC only; this image is amd64 | `reports/vex-proof.txt` |

- **Grype with VEX:** findings on the `nginx` package drop from 8 to
  6; the two removed are exactly CVE-2026-15176 and CVE-2026-93479.
  This was run on the build made before the dynamic modules and `nginx-debug`
  were added. That build contains the same `nginx` package (same version, same
  patch) as the final image.
- **Trivy with VEX** (final image): CVE-2025-27587 drops from 2 to
  0.

### Scan totals and image size

| | Baseline (`nginx:1.25-bookworm`) | Hardened (`nginx-hardened:latest`) |
|---|---|---|
| Trivy findings (`--pkg-types os`, same database, final image) | 839 (785 CVE + 54 Debian TEMP/DLA/DSA) | 359 (316 CVE + 43 TEMP) |
| Grype findings | 789 (first scan of the day) | 216 (build before the modules were added) |
| Image size (`docker images`) | 276MB | 267MB |

Findings are counted as lines containing a CVE or GHSA ID in `reports/`.
Hardened counts are before VEX is applied. The Grype hardened count does not
include the libraries added later for the modules (libxml2, libxslt, libgd,
libGeoIP); the Trivy numbers are for the final image.

> **Attribution.** Most of the drop in the totals comes from building on a current
> `debian:bookworm-slim` base; the official image ships an older base. What this
> repo changes directly is the backport, the OpenSSL bump and the VEX statements.

## 2. Key triage finding: the two scanners disagree

- **Trivy** flags no CVEs against nginx. It relies on Debian security advisories,
  and the official image installs nginx from **nginx.org**, not from Debian.
- **Grype** flags nginx by its version string, so it does see the nginx CVEs.

A backport keeps the version at `1.25.5`, so Grype keeps flagging the patched CVE.
A VEX statement tells the scanner it is fixed. Full triage: `docs/TRIAGE.md`.

### Triage of every finding

Every baseline finding is triaged, not only the ones fixed above: `make triage`
(`scripts/triage.py`) records for each (CVE, package) the package it lives in, the
upstream fix status and version, and how this image handles it. One row per finding:
`reports/triage.csv`; per-package summary: `docs/TRIAGE-SUMMARY.md`.

| Outcome | Findings |
|---|---|
| Version bump: package installed at a version without the finding (explicit `libssl3`/`libpcre2-8-0`/`zlib1g` upgrade plus the current bookworm base) | 315 |
| Component removed: package not installed in this image (`curl`, `libcurl4`, Kerberos, LDAP, `libssh2`, `libnghttp2`, SASL) | 173 |
| Backport (`build/patches/`) | 1 |
| Not affected, VEX statement (`vex/vex.openvex.json`) | 3 |
| Open: Debian has no fixed version (`affected`, `fix_deferred`, `will_not_fix`) | 349 |
| Open: nginx CVEs not addressed (one is a backport candidate) | 6 |
| **Total** (839 Trivy + 8 Grype nginx findings) | **847** |

No open finding has a fixed Debian version that is not installed. The largest open
item is `libheif1` (69), which is present only as a dependency of `libgd3`, needed
by the `image_filter` module; removing it would break drop-in compatibility.
Trivy reports no findings for the nginx.org `nginx` package in the official image, but
reports 8 for the `nginx` package built here. These are the same nginx CVEs Grype
reports for the baseline, already triaged above; the cause was not investigated.

## 3. Build & container design

- **Sources.** `build/build.sh` downloads nginx 1.25.5 (nginx.org) and njs 0.8.4
  (GitHub) and checks both against `build/SHA256SUMS`. The build fails if a
  pinned hash is missing or does not match.
- **Patches.** `build/patches/*.patch` are applied to the nginx source in
  filename order; the build fails if there are none.
- **Four compiles, as nginx.org does.** `nginx` and `nginx-debug` are built with
  exactly the configure arguments of the official image, in the same order
  (including `--with-http_v3_module`), so `nginx -V` matches. The dynamic modules
  are built in separate trees (normal and `--with-debug`) and only their `.so`
  files are kept.
- **Packages.** One `.deb` per package of the official image: `nginx` (with
  `nginx-debug`), `nginx-module-njs`, `nginx-module-geoip`,
  `nginx-module-image-filter`, `nginx-module-xslt`. The `nginx` package ships the official `conf.d/default.conf` as a conffile,
  because the entrypoint relies on its md5. Binaries and modules are
  stripped, as in the official packages. `Depends` is computed from
  the shared libraries each binary links against (`ldd` + `dpkg -S`).
- **Containerfile.** Starts from `debian:bookworm-slim`, sets the same `ENV` as
  the official image (`NGINX_VERSION`, `NJS_VERSION`, `NJS_RELEASE`,
  `PKG_RELEASE`), creates the `nginx` user with uid/gid 101, applies the OpenSSL
  version bump (`apt-get install --only-upgrade`), installs the `.deb`s with apt
  (which resolves their library dependencies), and sets `EXPOSE 80`,
  `STOPSIGNAL SIGQUIT`, `ENTRYPOINT` and `CMD` as in the official image.
- **What `COPY --from=stock` copies.** The official image is used as a source of
  files in four paths:

  | Path | Contents |
  |------|----------|
  | `/etc/nginx` | configuration files (e.g. `nginx.conf`, `conf.d/default.conf`, `mime.types`, `*_params`) and the `modules` symlink |
  | `/usr/share/nginx` | static assets (default HTML pages) |
  | `/docker-entrypoint.sh` | entrypoint shell script |
  | `/docker-entrypoint.d/` | entrypoint hook shell scripts |

  Only configuration files, scripts and static assets are copied. Every regular
  file under these paths in the stock image was checked for an ELF header, and
  none was found (`reports/stock-copy-check.txt`). `nginx`, `nginx-debug` and
  every module come only from the `.deb`s compiled from source.
- **Package identity.** The package is named `nginx`, version
  `1.25.5-1~bookworm+hardened1`. An earlier build named it `nginx-hardened`;
  Grype then stopped recognising it as nginx and its CVEs disappeared from the
  report. That hid the findings instead of addressing them, so the name was
  changed back and the remaining findings are handled with VEX.

## 4. Compatibility test

**Definition of "working correctly":** for the same request, `nginx:1.25-bookworm`
and `nginx-hardened:latest` return the same status code, the same response
headers and the same body bytes. Beyond HTTP behaviour, the two images must have
the same build arguments, binaries, modules and image configuration.

**How it runs.** `test/conftest.py` starts both images as separate containers.
Docker chooses the host port; picking a free port ourselves failed with
`500 Server Error` on container start, which is consistent with Windows
reserving ports that look free inside WSL (not confirmed). The suite waits until
each container answers a real HTTP request, not just until the port opens.

**Default configuration** (`test/test_compat.py`):

| Test | Request | Checked |
|------|---------|---------|
| `test_root` | `GET /` | status, headers and body are equal |
| `test_not_found` | `GET /does-not-exist` | equal |
| `test_head` | `HEAD /` | equal |
| `test_bad_method` | `DELETE /` | equal |
| `test_server_header_same_version` | `GET /` | both send `Server: nginx/1.25.5` |
| `test_malformed_keeps_worker_alive` | raw request line with a NUL byte and a bogus protocol | same status line; a normal `GET /` afterwards still returns equal responses |

**Custom configuration** (`test/test_custom.py`, both images mount
`test/fixtures/nginx.conf`, which loads all six dynamic modules; if one is
missing, nginx does not start and these tests fail):

| Test | Request | Checked |
|------|---------|---------|
| `test_custom_root` | `GET /` | equal |
| `test_custom_add_header` | `GET /` | both send the configured `X-Compat-Test` header |
| `test_njs_module` | `GET /njs` (njs handler) | equal; body is `njs 0.8.4` |
| `test_large_response_body` | `GET /big.bin` (5 MiB file) | equal; full 5 MiB received |
| `test_range_request` | `GET /big.bin` with `Range: bytes=100-199` | equal |
| `test_large_request_body` | `POST /upload` with 2 MiB (njs returns the body size) | equal; size is 2097152 |
| `test_request_body_over_limit` | `POST /small` with 4 KiB over a 1 KiB limit | equal; status 413 |

**Image level** (`test/test_custom.py`):

| Test | Checked |
|------|---------|
| `test_configure_arguments_match` | `nginx -V` configure arguments are identical (only `--with-cc-opt` is excluded) |
| `test_nginx_debug_binary` | `nginx-debug -t` succeeds in both images |
| `test_dynamic_modules_present` | the same 12 module files (6 modules, normal and debug) in both images |
| `test_image_config_matches` | `User`, `WorkingDir`, `ExposedPorts`, `Entrypoint`, `Cmd`, `StopSignal`, `Env` are identical |
| `test_entrypoint_enables_ipv6` | the entrypoint enables `listen [::]:80` in both images (it does so only when `default.conf` matches the packaged version) |

**Headers excluded from comparison:** `Date` (time of the request), and
`Connection` / `Keep-Alive` (connection handling, not content). All other
headers are compared, including `ETag`, `Last-Modified`, `Content-Type`,
`Content-Length` and `Server`.

**Not covered:** HTTP/2, TLS, the stream module and HTTP/3 traffic; gzip; the
behaviour of the geoip, image-filter and xslt modules (only that they load);
the patched alias + rewrite path, where the behaviour is meant to differ, which
`poc/prove-cve-2026-15176.sh` tests separately.

**Exit status.** Each comparison is an `assert`; any mismatch fails that test and
pytest exits non-zero, which makes `make test` fail. Run it with `make test` or
`python3 -m pytest test/ -v`. Both images must be present locally.

## 5. Residual risk and known deviations

- **`nginx -V`.** Configure arguments are identical to the official image. The
  only differences are the compiler's Debian patch level (gcc 12.2.0-14 vs
  12.2.0-14+deb12u1, from the newer builder base), the OpenSSL version line (built against the current
  Debian OpenSSL 3.0) and the `-ffile-prefix-map` path inside `--with-cc-opt`,
  which only affects debug path names (`reports/nginx-V-diff.txt`).
- **Package versions.** Our packages are versioned `...+hardened1`. The `ENV`
  values (`PKG_RELEASE=1~bookworm` etc.) are kept identical to the official image
  so that scripts reading them behave the same.
- **Image size.** Binaries and modules are stripped, as in the official
  packages. The hardened image is 267MB; the official one is 276MB.
- **zlib.** CVE-2023-45853 (Critical) is marked `will_not_fix` by Debian, so no
  apt upgrade can close it. CVE-2026-85091 and CVE-2026-27171 also remain in
  `zlib1g`. Not addressed.
- **nginx findings still reported by Grype after VEX:** CVE-2026-97205 (Critical,
  AIO + SSI use-after-free), CVE-2026-97629 (High, TLS session ticket keys),
  CVE-2023-44487 (High, HTTP/2 rapid reset), CVE-2026-95101 (Medium, HTTP/3),
  CVE-2009-4487 and CVE-2013-0337 (Negligible). HTTP/3 is compiled in, as in the
  official image, so CVE-2026-95101 applies. The upstream fix for CVE-2026-97629
  applies cleanly to 1.25.5 (`git apply --check`) and is the natural next
  backport. The others have not been assessed.
- **Base image.** Most of the reduction in total findings comes from the newer
  base image, not from the changes in this repo (section 1).
- **Source checksums.** `build/SHA256SUMS` was recorded from the downloads
  (nginx.org over HTTPS, njs from a GitHub tag archive): trust on first use.
  Verifying the nginx release's PGP signature would be stronger.
- **Grype reports** come from earlier runs (section 1); the Trivy reports are
  for the final image.
- **Test scope.** See "Not covered" in section 4.

## 6. What surprised me

- nginx is invisible to Trivy but flagged by Grype, because the official image
  takes nginx from nginx.org.
- **CVE-2026-93479 is a false positive on 1.25.5.** The vulnerable reserved-area
  allocation was introduced after 1.25.5 (commits `b76754049` / `a8289aa69`,
  2026-07-15), so the upstream fix does not even apply. The right treatment is
  VEX, not a patch.
- Renaming the package to `nginx-hardened` made its CVEs disappear from Grype.
  That was hiding them, not fixing them.
- My first image was not a real drop-in. `docker inspect` and a module listing
  showed it lacked the official `ENV`, `nginx-debug` and all 12 module files, so
  any config with `load_module` would have failed. I had also dropped HTTP/3
  assuming it needed a QUIC-capable TLS library; the official image is built
  against Debian's OpenSSL 3.0, and so is this one now.
- The final comparison caught a difference my tests missed. It was not in
  `nginx -V` itself but in the entrypoint's log line, which the container prints
  before running `nginx -V`. The
  official entrypoint enables IPv6 (`listen [::]:80`) only if `default.conf`
  matches the md5 that dpkg records for the `nginx` package. My package did not
  ship that file as a conffile, so IPv6 was silently left off. The package now
  ships the official `default.conf` as a conffile, and a test covers it.
- An open port does not mean nginx is ready; the first test version failed with
  connection resets for that reason.
- Grype's own database download hung while `curl` fetched the same file in
  seconds. And the first `grype --vex` run inside its container could not find
  the VEX file because the working directory was not mounted; Grype logged an
  error, but I had sent stderr to `/dev/null`, so the result looked like "all
  findings suppressed".

## 7. How I used AI

I used Claude Code throughout, mainly as an accelerator for search and scaffolding.

- **Where it helped:** navigating the nginx git history to locate the upstream
  fix commits, checking which patches apply cleanly to 1.25.5, scaffolding the
  build script, Containerfile and test harness, and drafting documentation.
- **Where it hurt:**
  - Its first backport candidates (CVE-2024-7347, CVE-2025-23419) were not
    flagged by either scanner; I switched targets after the real baseline scan.
  - It named the package `nginx-hardened`, which made the nginx CVEs disappear
    from Grype. I caught it on rescan and renamed it back to `nginx` with VEX.
  - It dropped HTTP/3 on a wrong assumption, and its first image lacked the
    official `ENV`, `nginx-debug` and all 12 module files. A `docker inspect`
    and module comparison exposed this.
  - Its checksum gate failed open when the hash file was missing; fixed in review.
  - Its package didn't register `default.conf` as a conffile. The official
    entrypoint (`10-listen-on-ipv6-by-default.sh`) verifies that file against
    dpkg's conffile checksum, so it silently skipped enabling IPv6. A fail-closed
    diff of the two containers' startup logs caught it.
- **What I did myself:** made the call at each decision point (target CVEs,
  pushing for drop-in parity (modules, `nginx-debug`, `ENV`, HTTP/3) instead of
  a partial image, keeping the system-library bump), checked the reasoning
  behind each finding, and ran every build, test, scan and proof on my own
  machine.

## Layout

```
build/          Dockerfile, build.sh, SHA256SUMS, patches/
Containerfile   runtime image (drop-in, parity-matched)
scripts/        triage.py: classifies every baseline finding (make triage)
test/           pytest suite: test_compat.py, test_custom.py, fixtures/
poc/            PoC config + proof script for CVE-2026-15176
vex/            OpenVEX document
docs/TRIAGE.md  CVE triage and decisions
reports/        scans, proofs and checks
Makefile        deb / image / test / scan / all / clean
```
