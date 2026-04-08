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
        # Appears in stack_lock_acquire (lib/stack-lock.sh) and lib/pr-lifecycle.sh
        "29d4f34b703f44699237713cc8d8065b": "Structural end-of-while-loop+case (return 1, esac, done, closing brace)",
        # Forgejo org-creation API call pattern shared between forge-setup.sh and ops-setup.sh
        # Extracted from bin/disinto (not a .sh file, excluded from prior scans) into lib/forge-setup.sh
        "059b11945140c172465f9126b829ed7f": "Forgejo org-creation curl pattern (forge-setup.sh + ops-setup.sh)",
        # Docker compose environment block for agents service (generators.sh + hire-agent.sh)
        # Intentional duplicate - both generate the same docker-compose.yml template
        "8066210169a462fe565f18b6a26a57e0": "Docker compose environment block (generators.sh + hire-agent.sh) - old",
        "fd978fcd726696e0f280eba2c5198d50": "Docker compose environment block continuation (generators.sh + hire-agent.sh) - old",
        "e2760ccc2d4b993a3685bd8991594eb2": "Docker compose env_file + depends_on block (generators.sh + hire-agent.sh) - old",
        # The hash shown in output is 161a80f7 - need to match exactly what the script finds
        "161a80f7296d6e9d45895607b7f5b9c9": "Docker compose env_file + depends_on block (generators.sh + hire-agent.sh) - old",
        # New hash after explicit environment fix (#381)
        "83fa229b86a7fdcb1d3591ab8e718f9d": "Docker compose explicit environment block (generators.sh + hire-agent.sh) - #381",
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
