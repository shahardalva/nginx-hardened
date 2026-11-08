# CVE Triage

This file covers the decisions on the selected CVEs. Every baseline finding is
classified in [`TRIAGE-SUMMARY.md`](TRIAGE-SUMMARY.md) and `reports/triage.csv`.

Baseline scans of `nginx:1.25-bookworm`: `reports/baseline-trivy.txt`,
`reports/baseline-grype.txt`. Hardened scans: `reports/hardened-*.txt`.

## Scanner divergence (key finding)

- **Trivy** flags no CVEs against nginx. It relies on Debian security advisories,
  and the official image installs nginx from **nginx.org**, not from Debian.
- **Grype** flags the `nginx` package by version string, so it sees the nginx CVEs.

A backport keeps the version at `1.25.5`, so Grype keeps flagging a patched CVE.
A VEX statement records that it is fixed.

## Decisions

| CVE | Component | Severity | Status in 1.25.5 | Treatment |
|-----|-----------|----------|------------------|-----------|
| CVE-2026-15176 | nginx `ngx_http_core_module` | Critical | vulnerable | **Backport** + VEX `fixed` |
| CVE-2026-31789 | `libssl3` / `openssl` | Critical | vulnerable | **Version bump** of the system library |
| CVE-2026-93479 | nginx `ngx_http_script` | Critical | not vulnerable | VEX `not_affected` |
| CVE-2025-27587 | `libssl3` / `openssl` | — | not reachable on amd64 | VEX `not_affected` |

### CVE-2026-15176: backport
- Buffer overflow in `ngx_http_map_uri_to_path()` when `alias` is combined with a
  `rewrite` that changes the URI (PoC in the upstream commit message).
- Fixed upstream in commit `f8a23425b`, released in **1.31.7**. The 1.25 branch
  is end-of-life, so no release of the version we ship contains the fix.
- The vulnerable check (`alias && !r->valid_location`) exists in 1.25.5 and the
  one-line fix applies cleanly. `poc/prove-cve-2026-15176.sh` runs the PoC
  against both images: the hardened one rejects the mapping and logs an alert.

### CVE-2026-31789: version bump
- `libssl3` 3.0.11-1~deb12u2 in the baseline. Debian fixed it in 3.0.19-1~deb12u2;
  the hardened image runs 3.0.22-1~deb12u2.
- **Why the system library and not OpenSSL built from source.** I considered
  building nginx against OpenSSL 3.0.22 from source (`--with-openssl=`) and
  rejected it. In the official image both nginx and the njs module link
  `libssl3` dynamically. A static OpenSSL would either remove njs's crypto
  support or load two copies of OpenSSL into the process, and it would change
  `nginx -V`. Debian already ships the fixed library at the same upstream
  version as the newest 3.0.x release (`openssl-3.0.22`), so upgrading the
  system library closes the CVEs and keeps the linkage identical to the
  official image.

### CVE-2026-93479: not affected (false positive)
- The upstream fix (`6aa4b3fdd`) changes a "reserved area" allocation
  (`n = len` → `n = 0`, `value->len = n` → `n + len`). Those lines do not exist
  in 1.25.5: the mechanism was added later by `b76754049` and `a8289aa69`
  (2026-07-15), after 1.25.5 was released (2024-04-16).
- 1.25.5 uses the simpler `value->len = len` allocation, which is not affected.
  VEX: `not_affected`, justification `vulnerable_code_not_present`.

### CVE-2025-27587: not affected
- The advisory scopes it to OpenSSL on the PowerPC architecture. This image is
  amd64. VEX: `not_affected`, justification `vulnerable_code_not_in_execute_path`.

## Considered, not addressed (residual)

- **CVE-2026-97629** (High, TLS session ticket keys): fix `1916f26e6` applies
  cleanly to 1.25.5 (`git apply --check`). The natural next backport.
- **CVE-2026-95101** (Medium, HTTP/3 frame handling): HTTP/3 is compiled in, as
  in the official image, so this applies. Fix `1c173a2d8`; not tested against 1.25.5.
- **CVE-2026-97205** (Critical, AIO + SSI use-after-free) and **CVE-2023-44487**
  (High, HTTP/2 rapid reset): not assessed.
- **CVE-2009-4487**, **CVE-2013-0337** (Negligible): not assessed.
- **zlib CVE-2023-45853** (Critical): Debian marks it `will_not_fix`, so no apt
  upgrade closes it. Per its description the bug is in MiniZip. Whether MiniZip
  is present in this image has not been verified, so it stays in residual risk.
