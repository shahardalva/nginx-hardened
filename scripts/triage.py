#!/usr/bin/env python3
"""Classify every finding in the baseline scan by how this repo handles it.

For each (CVE, package) that Trivy reports for nginx:1.25-bookworm, and for each
CVE that Grype reports for the nginx package, record the package it lives in,
whether Debian/upstream has a fix and in which version, and the outcome in
nginx-hardened: version bump, component removed, backport, VEX, or still open.

Inputs:  reports/baseline-trivy.json, reports/hardened-trivy.json
         (Trivy JSON, --pkg-types os --list-all-pkgs), reports/baseline-grype.txt
Outputs: reports/triage.csv, reports/triage-summary.json, docs/TRIAGE-SUMMARY.md
"""
import collections
import csv
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
REPORTS = ROOT / "reports"

# Packages upgraded explicitly by the Containerfile (the dependency version bump).
EXPLICIT_BUMP = {"libssl3", "libpcre2-8-0", "zlib1g"}

# OS-package findings covered by a VEX not_affected statement (vex/vex.openvex.json).
VEX_NOT_AFFECTED = {("CVE-2025-27587", "libssl3"), ("CVE-2025-27587", "openssl")}

# nginx findings come from Grype only (Trivy does not flag the nginx.org package).
# CVE -> (method, upstream fix, notes)
NGINX = {
    "CVE-2026-15176": ("backport", "nginx 1.31.7 (f8a23425b)", "patch applied to 1.25.5; VEX fixed"),
    "CVE-2026-93479": ("not affected (VEX)", "nginx 1.31.7 (6aa4b3fdd)", "vulnerable code was added after 1.25.5"),
    "CVE-2026-97629": ("open: backport candidate", "nginx 1.31.7 (1916f26e6)", "fix applies cleanly to 1.25.5; not applied"),
    "CVE-2026-95101": ("open", "nginx 1.31.7 (1c173a2d8)", "HTTP/3; patch not tested on 1.25.5"),
    "CVE-2026-97205": ("open", "nginx 1.31.7", "AIO + SSI; not assessed"),
    "CVE-2023-44487": ("open", "not checked", "HTTP/2 rapid reset; not assessed"),
    "CVE-2009-4487": ("open", "not checked", "negligible; not assessed"),
    "CVE-2013-0337": ("open", "not checked", "negligible; not assessed"),
}


def load_trivy(path):
    data = json.loads(path.read_text())
    packages, findings = {}, {}
    for result in data.get("Results") or []:
        for p in result.get("Packages") or []:
            pid = p.get("ID", "")
            packages[p["Name"]] = pid.split("@", 1)[1] if "@" in pid else p.get("Version", "")
        for v in result.get("Vulnerabilities") or []:
            findings[(v["VulnerabilityID"], v["PkgName"])] = v
    return packages, findings


def grype_nginx(path):
    rows = {}
    for line in path.read_text().splitlines():
        tok = line.split()
        if not tok or tok[0] != "nginx":
            continue
        for i, t in enumerate(tok):
            if t.startswith(("CVE-", "GHSA-")):
                rows[t] = (tok[1], tok[i + 1] if i + 1 < len(tok) else "")
                break
    return rows


def classify(key, hard_pkgs, hard_findings):
    """Return (outcome, method, notes) for one baseline finding."""
    cve, pkg = key
    if pkg not in hard_pkgs:
        return "closed", "component removed", "package is not installed in the hardened image"
    if key not in hard_findings:
        source = "explicit bump in Containerfile" if pkg in EXPLICIT_BUMP else "current Debian base image"
        return "closed", "version bump", f"hardened has {hard_pkgs[pkg]} ({source})"
    if key in VEX_NOT_AFFECTED:
        return "vex", "not affected (VEX)", "see vex/vex.openvex.json"
    h = hard_findings[key]
    if h.get("FixedVersion"):
        return "open", "version bump available", f"Debian fixed in {h['FixedVersion']}; hardened has {hard_pkgs[pkg]}"
    return "open", "no Debian fix", f"Debian status in hardened image: {h.get('Status', 'unknown')}"


def main():
    base_pkgs, base = load_trivy(REPORTS / "baseline-trivy.json")
    hard_pkgs, hard = load_trivy(REPORTS / "hardened-trivy.json")

    rows = []
    for key in sorted(base, key=lambda k: (k[1], k[0])):
        v = base[key]
        outcome, method, notes = classify(key, hard_pkgs, hard)
        fixed = v.get("FixedVersion") or ""
        rows.append({
            "cve": key[0], "package": key[1], "severity": v.get("Severity", ""),
            "baseline_version": v.get("InstalledVersion", ""),
            "upstream_status": v.get("Status", ""),
            "fix_available_in": f"Debian {fixed}" if fixed else "none",
            "outcome": outcome, "method": method, "notes": notes, "scanner": "trivy",
        })
    for cve, (version, severity) in sorted(grype_nginx(REPORTS / "baseline-grype.txt").items()):
        method, upstream, notes = NGINX.get(cve, ("open", "not checked", "not assessed"))
        outcome = "open" if method.startswith("open") else ("vex" if "VEX" in method else "closed")
        rows.append({
            "cve": cve, "package": "nginx", "severity": severity.upper(),
            "baseline_version": version, "upstream_status": "nginx.org package",
            "fix_available_in": upstream, "outcome": outcome, "method": method,
            "notes": notes, "scanner": "grype",
        })
    new_in_hardened = sorted(k for k in hard if k not in base)

    with open(REPORTS / "triage.csv", "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)

    by_method = collections.Counter(r["method"] for r in rows)
    by_pkg = collections.defaultdict(collections.Counter)
    for r in rows:
        by_pkg[r["package"]][r["method"]] += 1
    open_rows = [r for r in rows if r["outcome"] == "open"]
    open_by_pkg = collections.defaultdict(collections.Counter)
    for r in open_rows:
        open_by_pkg[r["package"]][r["method"] + (": " + r["notes"].split(": ", 1)[-1] if r["method"] == "no Debian fix" else "")] += 1

    summary = {
        "total": len(rows),
        "trivy_baseline_findings": len(base),
        "grype_nginx_findings": len(rows) - len(base),
        "by_method": dict(by_method),
        "open": len(open_rows),
        "new_in_hardened": len(new_in_hardened),
        "new_in_hardened_untriaged": sum(1 for c, p in new_in_hardened if not (p == "nginx" and c in NGINX)),
    }
    (REPORTS / "triage-summary.json").write_text(json.dumps(summary, indent=2) + "\n")

    methods = ["version bump", "component removed", "backport", "not affected (VEX)",
               "open: backport candidate", "version bump available", "no Debian fix", "open"]
    md = ["# Triage of every baseline finding", "",
          "Generated by `scripts/triage.py` (`make triage`) from `reports/baseline-trivy.json`,",
          "`reports/hardened-trivy.json` and `reports/baseline-grype.txt`. One row per",
          "finding: `reports/triage.csv`. Decisions on the selected CVEs: `docs/TRIAGE.md`.", "",
          "For each (CVE, package) in the baseline the CSV records the package it lives in,",
          "the upstream fix status and version (Debian for OS packages, nginx.org for nginx),",
          "and the outcome in the hardened image:", "",
          "- **version bump**: the package is installed at a version that no longer has the finding",
          "- **component removed**: the package is not installed in the hardened image",
          "- **backport**: fixed by a patch in `build/patches/`",
          "- **not affected (VEX)**: covered by `vex/vex.openvex.json`",
          "- **version bump available**: a fixed Debian version exists but is not installed",
          "- **no Debian fix**: still present; Debian has no fixed version (`will_not_fix`, `affected`, ...)",
          "- **open / open: backport candidate**: nginx findings not addressed", "",
          "## Outcome of all baseline findings", "",
          "| Method | Findings |", "|---|---|"]
    for m in methods:
        if by_method.get(m):
            md.append(f"| {m} | {by_method[m]} |")
    md.append(f"| **total** | **{len(rows)}** |")
    md += ["", "## By package", "",
           "| Package | Findings | Version bump | Removed | Backport | VEX | Open |",
           "|---|---|---|---|---|---|---|"]
    for pkg, c in sorted(by_pkg.items(), key=lambda x: -sum(x[1].values())):
        opened = sum(n for m, n in c.items() if m.startswith("open") or m in ("version bump available", "no Debian fix"))
        md.append(f"| `{pkg}` | {sum(c.values())} | {c['version bump']} | {c['component removed']} "
                  f"| {c['backport']} | {c['not affected (VEX)']} | {opened} |")
    md += ["", "## Still open in the hardened image", "",
           "| Package | Findings | Reason |", "|---|---|---|"]
    for pkg, c in sorted(open_by_pkg.items(), key=lambda x: -sum(x[1].values())):
        for reason, n in c.most_common():
            md.append(f"| `{pkg}` | {n} | {reason} |")
    md += ["", "## Findings present only in the hardened image", "",
           "Trivy reports no findings for the nginx.org `nginx` package in the official image,",
           "but does report findings for the `nginx` package built here (cause not investigated).",
           "Each one should be an nginx CVE that Grype reports for the baseline and is triaged above;",
           "anything else is marked NOT TRIAGED.", ""]
    if new_in_hardened:
        md += ["| CVE | Package | Triage |", "|---|---|---|"] + [
            f"| {c} | `{p}` | {NGINX[c][0] if p == 'nginx' and c in NGINX else 'NOT TRIAGED'} |"
            for c, p in new_in_hardened]
    else:
        md.append("None.")
    (ROOT / "docs" / "TRIAGE-SUMMARY.md").write_text("\n".join(md) + "\n")

    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
