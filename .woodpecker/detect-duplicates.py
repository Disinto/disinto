#!/usr/bin/env python3
"""detect-duplicates.py — Find copy-pasted code blocks across shell files.

Two detection passes:
  1. Known anti-patterns (grep-style): flags specific hardcoded patterns
     that should use shared helpers instead.
  2. Sliding-window hash: finds N-line blocks that appear verbatim in
     multiple files (catches structural copy-paste).

Exit 0 = clean. Exit 1 = findings (CI step is set to failure: ignore,
so overall CI stays green while findings are visible in logs).
"""

import sys
import os
import hashlib
import re
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
        'Hardcoded CI_STATE="success" check — use ci_passed() from dev-poll.sh instead',
    ),
    (
        r'\$CI_STATE\s*!=\s*"success"',
        'Hardcoded CI_STATE!="success" check — use ci_passed() from dev-poll.sh instead',
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
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    sh_files = sorted(
        p for p in Path(".").rglob("*.sh") if ".git" not in p.parts
    )

    if not sh_files:
        print("No .sh files found.")
        return 0

    print(f"Scanning {len(sh_files)} shell files "
          f"(window={WINDOW} lines, min_files={MIN_FILES})...\n")

    # --- Pass 1: anti-patterns ---
    ap_hits = check_anti_patterns(sh_files)
    if ap_hits:
        print("=== Anti-pattern findings ===")
        for file, lineno, line, message in ap_hits:
            print(f"  {file}:{lineno}: {message}")
            print(f"    > {line[:120]}")
        print()

    # --- Pass 2: sliding-window duplicates ---
    dup_groups = check_duplicates(sh_files)
    if dup_groups:
        print(f"=== Duplicate code blocks (window={WINDOW} lines) ===")
        for h, locs in dup_groups:
            files = {loc[0] for loc in locs}
            print(f"\n  [{h[:8]}] appears in {len(files)} file(s):")
            for file, lineno, preview in locs:
                print(f"    {file}:{lineno}")
            # Show first 3 lines of the duplicated block
            first_preview = locs[0][2]
            for ln in first_preview.splitlines()[:3]:
                print(f"      | {ln}")
        print()

    # --- Summary ---
    total_issues = len(ap_hits) + len(dup_groups)
    if total_issues == 0:
        print("No duplicate code or anti-pattern findings.")
        return 0

    print(f"Summary: {len(ap_hits)} anti-pattern hit(s), "
          f"{len(dup_groups)} duplicate block(s).")
    print("Consider extracting shared patterns to lib/ helpers.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
