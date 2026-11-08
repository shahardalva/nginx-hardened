# CVE Triage

Baseline scans: `reports/baseline-trivy.txt`, `reports/baseline-grype.txt`
(image: `nginx:1.25-bookworm`).

## Scanner divergence (key finding)

The two scanners disagree about nginx itself:

- **Trivy** reports 839 CVEs but flags **none against nginx** — it keys on
  Debian security advisories, and the official image installs nginx from
  **nginx.org**, not Debian, so nginx falls outside Trivy's advisory source.
- **Grype** reports 789 CVEs and **does** flag `nginx 1.25.5-1~bookworm`
  directly, by matching the version string against vulnerability ranges.

Consequence: nginx-level CVEs are only visible via Grype, and because a
backport keeps the version string at `1.25.5`, Grype keeps flagging them even
after the source is patched — which is exactly why a VEX document is needed.

## Selected items

| CVE | Component | Severity | 1.25.5 status | Treatment |
|-----|-----------|----------|---------------|-----------|
| CVE-2026-15176 | nginx `ngx_http_core_module` | Critical | genuinely vulnerable | **Backport** patch from 1.31.7 |
| CVE-2026-93479 | nginx `ngx_http_script` | Critical | **not** vulnerable | **VEX** `not_affected` |
| OpenSSL cluster | `libssl3` (OS package) | up to Critical | vulnerable | **Version bump** |

### CVE-2026-15176 — backport
- Buffer overflow in `ngx_http_map_uri_to_path()` when `alias` is combined
  with a `rewrite` that changes the URI (PoC in the upstream commit message).
- Fixed upstream in commit `f8a23425b`, released in **1.31.7** (2026-10-14).
  The 1.25.x branch is EOL, so there is **no upstream release** carrying the
  fix for the version we ship — the assignment's "port a fix back" case.
- The vulnerable code (`alias && !r->valid_location`) is present in 1.25.5,
  and the fix applies cleanly. We backport it and reproduce the PoC to prove
  the fix.

### CVE-2026-93479 — VEX not_affected (false positive)
- Grype flags 1.25.5, but the vulnerability does **not exist** in 1.25.5.
- The upstream fix (`6aa4b3fdd`) edits a "reserved area" allocation
  (`n = len` → `n = 0`, `value->len = n` → `n + len`). Those lines do not
  exist in 1.25.5 — the whole mechanism was introduced later by `b76754049`
  and `a8289aa69` (both 2026-07-15), **after** 1.25.5 shipped (2024-04-16).
- 1.25.5 uses the simpler `value->len = len` form, which is not affected.
- Correct treatment is therefore a VEX statement with status `not_affected`
  and justification `vulnerable_code_not_present`, not a patch.

### OpenSSL cluster — version bump
- `libssl3 3.0.11-1~deb12u2` carries ~50 CVEs, headlined by
  **CVE-2026-31789** (Critical) and **CVE-2024-6119** (High).
- Debian ships fixed versions (the "Fixed Version" column in the Trivy
  report), so these close via a **dependency version bump** — upgrading the
  OS package in the final image.

## Noted for residual risk
- **zlib CVE-2023-45853** (Critical) is marked `will_not_fix` by Debian — no
  apt upgrade can close it. Closing it requires building zlib from source
  (candidate bonus; see README residual risk).
