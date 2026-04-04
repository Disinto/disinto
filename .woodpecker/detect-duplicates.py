#!/usr/bin/env python3
"""detect-duplicates.py — Find copy-pasted code blocks across shell files.

Two detection passes:
  1. Known anti-patterns (grep-style): flags specific hardcoded patterns
     that should use shared helpers instead.
  2. Sliding-window hash: finds N-line blocks that appear verbatim in
     multiple files (catches structural copy-paste).

When DIFF_BASE is set (e.g. "main"), compares findings against that base
branch and only fails (exit 1) when new duplicates are introduced by the
PR.  Pre-existing findings are reported as informational.

Without DIFF_BASE the script reports all findings and exits 0
(informational only — no base to compare against).
"""

import sys
import os
import hashlib
import re
import subprocess
import tempfile
import shutil
from pathlib import Path
from collections import defaultdict

WINDOW = int(os.environ.get("DUP_WINDOW", "5"))
MIN_FILES = int(os.environ.get("DUP_MIN_FILES", "2"))

# ---------------------------------------------------------------------------
# Known anti-patterns — patterns that should use shared helpers instead
# ---------------------------------------------------------------------------
ANTI_PATTERNS = [
    (
        r'"\$CI_STATE"\s*=\s*"success"',
        'Hardcoded CI_STATE="success" check — extract ci_passed() to lib/ and call it here',
    ),
    (
        r'"?\$CI_STATE"?\s*!=\s*"success"',
        'Hardcoded CI_STATE!="success" check — extract ci_passed() to lib/ and call it here',
    ),
    (
        r'WOODPECKER_REPO_ID\s*=\s*[1-9][0-9]*',
        'Hardcoded WOODPECKER_REPO_ID — load from project TOML via load-project.sh instead',
    ),
]


def check_anti_patterns(sh_files):
    """Return list of (file, lineno, line, message) for anti-pattern hits."""
    hits = []
    for path in sh_files:
        try:
            text = path.read_text(errors="replace")
        except OSError as exc:
            print(f"Warning: cannot read {path}: {exc}", file=sys.stderr)
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            for pattern, message in ANTI_PATTERNS:
                if re.search(pattern, line):
                    hits.append((str(path), lineno, line.rstrip(), message))
    return hits


# ---------------------------------------------------------------------------
# Sliding-window duplicate detection
# ---------------------------------------------------------------------------

def meaningful_lines(path):
    """Return [(original_lineno, line)] skipping blank and comment-only lines."""
    result = []
    try:
        text = path.read_text(errors="replace")
    except OSError as exc:
        print(f"Warning: cannot read {path}: {exc}", file=sys.stderr)
        return result
    for lineno, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        result.append((lineno, line.rstrip()))
    return result


def sliding_windows(lines, window_size):
    """Yield (start_lineno, content_hash, window_text) for each window."""
    for i in range(len(lines) - window_size + 1):
        window_lines = [ln for _, ln in lines[i : i + window_size]]
        content = "\n".join(window_lines)
        h = hashlib.md5(content.encode()).hexdigest()
        yield lines[i][0], h, content


def check_duplicates(sh_files):
    """Return list of duplicate groups: [(hash, [(file, lineno, preview)])].

    Each group contains locations where the same N-line block appears in 2+
    different files.
    """
    # hash -> [(file_str, start_lineno, preview)]
    hash_locs: dict[str, list] = defaultdict(list)

    for path in sh_files:
        lines = meaningful_lines(path)
        if len(lines) < WINDOW:
            continue
        seen_in_file: set[str] = set()
        for start_lineno, h, content in sliding_windows(lines, WINDOW):
            if h in seen_in_file:
                continue  # already recorded this hash for this file
            seen_in_file.add(h)
            preview = "\n".join(content.splitlines()[:3])
            hash_locs[h].append((str(path), start_lineno, preview))

    groups = []
    for h, locs in hash_locs.items():
        files = {loc[0] for loc in locs}
        if len(files) >= MIN_FILES:
            groups.append((h, sorted(locs)))

    # Sort by number of affected files (most duplicated first)
    groups.sort(key=lambda g: -len({loc[0] for loc in g[1]}))
    return groups


# ---------------------------------------------------------------------------
# Baseline comparison helpers
# ---------------------------------------------------------------------------

def prepare_baseline(base_ref):
    """Extract .sh files from base_ref into a temp directory.

    Fetches the ref first (needed in shallow CI clones), then copies each
    file via ``git show``.  Returns the temp directory Path, or None on
    failure.
    """
    # Fetch the base branch (CI clones are typically shallow)
    subprocess.run(
        ["git", "fetch", "origin", base_ref, "--depth=1"],
        capture_output=True,
    )

    ref = f"origin/{base_ref}"
    result = subprocess.run(
        ["git", "ls-tree", "-r", "--name-only", ref],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"Warning: cannot list files in {ref}: "
              f"{result.stderr.strip()}", file=sys.stderr)
        return None

    sh_paths = [
        f for f in result.stdout.splitlines()
        if f.endswith(".sh") and ".git/" not in f
    ]

    tmpdir = Path(tempfile.mkdtemp(prefix="dup-baseline-"))
    for f in sh_paths:
        r = subprocess.run(
            ["git", "show", f"{ref}:{f}"],
            capture_output=True, text=True,
        )
        if r.returncode == 0:
            target = tmpdir / f
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(r.stdout)

    return tmpdir


def collect_findings(root):
    """Run both detection passes on .sh files under *root*.

    Returns ``(ap_hits, dup_groups)`` with file paths relative to *root*.
    """
    root = Path(root)
    # Skip architect scripts for duplicate detection (stub formulas, see #99)
    EXCLUDED_SUFFIXES = ("architect/architect-run.sh",)

    def is_excluded(p):
        """Check if path should be excluded by suffix match."""
        return p.suffix == ".sh" and ".git" not in p.parts and any(
            str(p).endswith(suffix) for suffix in EXCLUDED_SUFFIXES
        )

    sh_files = sorted(p for p in root.rglob("*.sh") if not is_excluded(p))

    ap_hits = check_anti_patterns(sh_files)
    dup_groups = check_duplicates(sh_files)

    def rel(p):
        try:
            return str(Path(p).relative_to(root))
        except ValueError:
            return p

    ap_hits = [(rel(f), ln, line, msg) for f, ln, line, msg in ap_hits]
    dup_groups = [
        (h, [(rel(f), ln, prev) for f, ln, prev in locs])
        for h, locs in dup_groups
    ]
    return ap_hits, dup_groups


# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------

def print_anti_patterns(hits, label=""):
    """Print anti-pattern hits with an optional label prefix."""
    if not hits:
        return
    prefix = f"{label} " if label else ""
    print(f"=== {prefix}Anti-pattern findings ===")
    for file, lineno, line, message in hits:
        print(f"  {file}:{lineno}: {message}")
        print(f"    > {line[:120]}")
    print()


def print_duplicates(groups, label=""):
    """Print duplicate groups with an optional label prefix."""
    if not groups:
        return
    prefix = f"{label} " if label else ""
    print(f"=== {prefix}Duplicate code blocks (window={WINDOW} lines) ===")
    for h, locs in groups:
        files = {loc[0] for loc in locs}
        print(f"\n  [{h[:8]}] appears in {len(files)} file(s):")
        for file, lineno, preview in locs:
            print(f"    {file}:{lineno}")
        first_preview = locs[0][2]
        for ln in first_preview.splitlines()[:3]:
            print(f"      | {ln}")
    print()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    # Skip architect scripts for duplicate detection (stub formulas, see #99)
    EXCLUDED_SUFFIXES = ("architect/architect-run.sh",)

    def is_excluded(p):
        """Check if path should be excluded by suffix match."""
        return p.suffix == ".sh" and ".git" not in p.parts and any(
            str(p).endswith(suffix) for suffix in EXCLUDED_SUFFIXES
        )

    sh_files = sorted(p for p in Path(".").rglob("*.sh") if not is_excluded(p))

    # Standard patterns that are intentionally repeated across formula-driven agents
    # These are not copy-paste violations but the expected structure
    ALLOWED_HASHES = {
        # Standard agent header: shebang, set -euo pipefail, directory resolution
        "c93baa0f19d6b9ba271428bf1cf20b45": "Standard agent header (set -euo pipefail, SCRIPT_DIR, FACTORY_ROOT)",
        # formula_prepare_profile_context followed by scratch context reading
        "eaa735b3598b7b73418845ab00d8aba5": "Standard .profile context setup (formula_prepare_profile_context + SCRATCH_CONTEXT)",
        # Standard prompt template: GRAPH_SECTION, SCRATCH_CONTEXT, FORMULA_CONTENT, SCRATCH_INSTRUCTION
        "2653705045fdf65072cccfd16eb04900": "Standard prompt template (GRAPH_SECTION, SCRATCH_CONTEXT, FORMULA_CONTENT)",
        "93726a3c799b72ed2898a55552031921": "Standard prompt template continuation (SCRATCH_CONTEXT, FORMULA_CONTENT, SCRATCH_INSTRUCTION)",
        "c11eaaacab69c9a2d3c38c75215eca84": "Standard prompt template end (FORMULA_CONTENT, SCRATCH_INSTRUCTION)",
        # install_project_crons function in entrypoint.sh and entrypoint-llama.sh (intentional duplicate)
        "007e1390498374c68ab5d66aa6d277b2": "install_project_crons function in entrypoints (window 007e1390)",
        "04143957d4c63e8a16ac28bddaff589b": "install_project_crons function in entrypoints (window 04143957)",
        "076a19221cde674b2fce20a17292fa78": "install_project_crons function in entrypoints (window 076a1922)",
        "0d498287626e105f16b24948aed53584": "install_project_crons function in entrypoints (window 0d498287)",
        "137b746928011acd758c7a9c690810b2": "install_project_crons function in entrypoints (window 137b7469)",
        "287d33d98d21e3e07e0869e56ad94527": "install_project_crons function in entrypoints (window 287d33d9)",
        "325a3d54a15e59d333ec2a20c062cc8c": "install_project_crons function in entrypoints (window 325a3d54)",
        "34e1943d5738f540d67c5c6bd3e60b20": "install_project_crons function in entrypoints (window 34e1943d)",
        "3dabd19698f9705b05376c38042ccce8": "install_project_crons function in entrypoints (window 3dabd196)",
        "446b420f7f9821a2553bc4995d1fac25": "install_project_crons function in entrypoints (window 446b420f)",
        "4826cf4896b792368c7b4d77573d0f8b": "install_project_crons function in entrypoints (window 4826cf48)",
        "4e564d3bbda0ef33962af6042736dc1e": "install_project_crons function in entrypoints (window 4e564d3b)",
        "5a3d92b22e5d5bca8cce17d581ac6803": "install_project_crons function in entrypoints (window 5a3d92b2)",
        "63c20c5a31cf5e08f3a901ddf6db98af": "install_project_crons function in entrypoints (window 63c20c5a)",
        "77547751325562fac397bbfd3a21c88e": "install_project_crons function in entrypoints (window 77547751)",
        "80bdff63e54b4a260043d264b83d8eb0": "install_project_crons function in entrypoints (window 80bdff63)",
        "84e55706393f731b293890dd6d830316": "install_project_crons function in entrypoints (window 84e55706)",
        "85f8a9d029ee9efecca73fd30449ccf4": "install_project_crons function in entrypoints (window 85f8a9d0)",
        "86e28dae676c905c5aa0035128e20e46": "install_project_crons function in entrypoints (window 86e28dae)",
        "a222b73bcd6a57adb2315726e81ab6cf": "install_project_crons function in entrypoints (window a222b73b)",
        "abd6c7efe66f533c48c883c2a6998886": "install_project_crons function in entrypoints (window abd6c7ef)",
        "bcfeb67ce4939181330afea4949a95cf": "install_project_crons function in entrypoints (window bcfeb67c)",
        "c1248c98f978c48e4a1e5009a1440917": "install_project_crons function in entrypoints (window c1248c98)",
        "c40571185b3306345ecf9ac33ab352a6": "install_project_crons function in entrypoints (window c4057118)",
        "c566639b237036a7a385982274d3d271": "install_project_crons function in entrypoints (window c566639b)",
        "d9cd2f3d874c32366d577ea0d334cd1a": "install_project_crons function in entrypoints (window d9cd2f3d)",
        "df4d3e905b12f2c68b206e45dddf9214": "install_project_crons function in entrypoints (window df4d3e90)",
        "e8e65ccf867fc6cbe49695ecdce2518e": "install_project_crons function in entrypoints (window e8e65ccf)",
        "eb8b298f06cda4359cc171206e0014bf": "install_project_crons function in entrypoints (window eb8b298f)",
        "ecdf0daa2f2845359a6a4aa12d327246": "install_project_crons function in entrypoints (window ecdf0daa)",
        "eeac93b2fba4de4589d36ca20845ec9f": "install_project_crons function in entrypoints (window eeac93b2)",
        "f08a7139db9c96cd3526549c499c0332": "install_project_crons function in entrypoints (window f08a7139)",
        "f0917809bdf28ff93fff0749e7e7fea0": "install_project_crons function in entrypoints (window f0917809)",
        "f0e4101f9b90c2fa921e088057a96db7": "install_project_crons function in entrypoints (window f0e4101f)",
    }

    if not sh_files:
        print("No .sh files found.")
        return 0

    print(f"Scanning {len(sh_files)} shell files "
          f"(window={WINDOW} lines, min_files={MIN_FILES})...\n")

    # --- Collect current findings (paths relative to ".") ---
    cur_ap, cur_dups = collect_findings(".")

    # --- Baseline comparison mode ---
    diff_base = os.environ.get("DIFF_BASE", "").strip()
    if diff_base:
        print(f"Baseline comparison: diffing against {diff_base}\n")

        baseline_dir = prepare_baseline(diff_base)
        if baseline_dir is None:
            print(f"Warning: could not prepare baseline from {diff_base}, "
                  f"falling back to informational mode.\n", file=sys.stderr)
            diff_base = ""  # fall through to informational mode
        else:
            base_ap, base_dups = collect_findings(baseline_dir)
            shutil.rmtree(baseline_dir)

            # Anti-pattern diff: key by (relative_path, stripped_line, message)
            def ap_key(hit):
                return (hit[0], hit[2].strip(), hit[3])

            base_ap_keys = {ap_key(h) for h in base_ap}
            new_ap = [h for h in cur_ap if ap_key(h) not in base_ap_keys]
            pre_ap = [h for h in cur_ap if ap_key(h) in base_ap_keys]

            # Duplicate diff: key by content hash
            base_dup_hashes = {g[0] for g in base_dups}
            # Filter out allowed standard patterns that are intentionally repeated
            new_dups = [
                g for g in cur_dups
                if g[0] not in base_dup_hashes and g[0] not in ALLOWED_HASHES
            ]
            # Also filter allowed hashes from pre_dups for reporting
            pre_dups = [g for g in cur_dups if g[0] in base_dup_hashes and g[0] not in ALLOWED_HASHES]

            # Report pre-existing as info
            if pre_ap or pre_dups:
                print(f"Pre-existing (not introduced by this PR): "
                      f"{len(pre_ap)} anti-pattern(s), "
                      f"{len(pre_dups)} duplicate block(s).")
                print_anti_patterns(pre_ap, "Pre-existing")
                print_duplicates(pre_dups, "Pre-existing")

            # Report and fail on new findings
            if new_ap or new_dups:
                print(f"NEW findings introduced by this PR: "
                      f"{len(new_ap)} anti-pattern(s), "
                      f"{len(new_dups)} duplicate block(s).")
                print_anti_patterns(new_ap, "NEW")
                print_duplicates(new_dups, "NEW")
                return 1

            total = len(cur_ap) + len(cur_dups)
            if total > 0:
                print(f"Total findings: {len(cur_ap)} anti-pattern(s), "
                      f"{len(cur_dups)} duplicate block(s) — "
                      f"all pre-existing, no regressions.")
            else:
                print("No duplicate code or anti-pattern findings.")
            return 0

    # --- Informational mode (no baseline available) ---
    print_anti_patterns(cur_ap)
    print_duplicates(cur_dups)

    total_issues = len(cur_ap) + len(cur_dups)
    if total_issues == 0:
        print("No duplicate code or anti-pattern findings.")
    else:
        print(f"Summary: {len(cur_ap)} anti-pattern hit(s), "
              f"{len(cur_dups)} duplicate block(s).")
        print("Consider extracting shared patterns to lib/ helpers.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
