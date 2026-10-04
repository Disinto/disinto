#!/usr/bin/env python3
"""detect-duplicates.py — Find copy-pasted code blocks across shell files.

Two detection passes:
  1. Known anti-patterns (grep-style): flags specific hardcoded patterns
     that should use shared helpers instead.
  2. Sliding-window hash: finds N-line blocks that appear verbatim in
     multiple files (catches structural copy-paste).  A window is only
     reportable when it carries at least three non-scaffolding lines
     (scaffolding = pure shell control-flow tokens such as `;;` / `esac`);
     a window made up of less is punctuation, not duplicated logic
     (issue #1134).

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
# A window is reportable only when it carries at least this many
# non-scaffolding lines; a window made up of less is punctuation, not
# duplicated logic (issue #1134).
MIN_REAL_LINES = 3

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


# Pure shell scaffolding: control-flow tokens the language leaves no
# alternative spelling for. Any two files that both close a `case` (or a
# for/if) agree on these lines, so they must not count toward the real
# lines that make a window reportable. Unlike blank and comment-only
# lines, scaffolding lines stay in the meaningful-line list: window spans
# and hashes are unchanged, so pre-existing findings keep their hashes
# (issue #1134).
SHELL_SCAFFOLDING = frozenset(
    (";;", "esac", "fi", "done", "}", ")", "*)", "else", "do", "then")
)


def sliding_windows(lines, window_size):
    """Yield (start_lineno, content_hash, window_text) for each window."""
    for i in range(len(lines) - window_size + 1):
        window_lines = [ln for _, ln in lines[i : i + window_size]]
        content = "\n".join(window_lines)
        h = hashlib.md5(content.encode()).hexdigest()
        yield lines[i][0], h, content


# The mandatory bootstrap header every tests/acceptance/*.sh must carry.
# It is boilerplate, not copy-paste, so it is masked out of the
# meaningful-line list *before* windowing: header lines never take part in
# any sliding window, at any window size. (A whole-window exemption cannot
# work once WINDOW exceeds the header's line count — issue #1126.)
ACCEPTANCE_TEST_PREFIX = ("tests", "acceptance")
# Safety bound: a header is short; never mask more than this many leading
# lines even if they all match a bootstrap shape.
MAX_BOOTSTRAP_LINES = 10
# Patterns fullmatch the stripped line, so reindentation cannot defeat the
# check; the trailing .* on assignments allows any right-hand side.
# Covers both the current header (set -euo pipefail / SCRIPT_DIR / REPO_ROOT
# / source of acceptance-helpers.sh) and the legacy header that inserts
# `cd "$REPO_ROOT"` between REPO_ROOT and the source line.
BOOTSTRAP_LINE_PATTERNS = (
    re.compile(r"set\s+-euo\s+pipefail"),
    re.compile(r"SCRIPT_DIR\s*=.*"),
    re.compile(r"REPO_ROOT\s*=.*"),
    re.compile(r'cd\s+["\']?\$REPO_ROOT["\']?'),
    re.compile(r"source\s+.*lib/acceptance-helpers\.sh.*"),
)


def is_acceptance_test(rel_path):
    """True for tests/acceptance/*.sh paths relative to the scan root."""
    parts = Path(rel_path).parts
    return len(parts) >= 3 and parts[:2] == ACCEPTANCE_TEST_PREFIX


def bootstrap_header_length(lines):
    """Number of leading *lines* forming the mandatory acceptance-test
    bootstrap header: the longest prefix in which every line matches a
    bootstrap shape. Only a leading prefix is ever masked, so a later line
    that happens to look like one (e.g. a REPO_ROOT reassignment in the
    body) is left alone.
    """
    n = 0
    for _lineno, line in lines:
        if n >= MAX_BOOTSTRAP_LINES:
            break
        stripped = line.strip()
        if not any(p.fullmatch(stripped) for p in BOOTSTRAP_LINE_PATTERNS):
            break
        n += 1
    return n


def check_duplicates(sh_files, root):
    """Return list of duplicate groups: [(hash, [(file, lineno, preview)])].

    Each group contains locations where the same N-line block appears in 2+
    different files. Paths in the groups are relative to *root*.
    """
    root = Path(root)
    # hash -> [(rel_file_str, start_lineno, preview)]
    hash_locs: dict[str, list] = defaultdict(list)

    for path in sh_files:
        try:
            rel_path = str(path.relative_to(root))
        except ValueError:
            rel_path = str(path)
        lines = meaningful_lines(path)
        if is_acceptance_test(rel_path):
            # Mask the mandatory bootstrap header (see issue #1126).
            lines = lines[bootstrap_header_length(lines):]
        if len(lines) < WINDOW:
            continue
        seen_in_file: set[str] = set()
        for start_lineno, h, content in sliding_windows(lines, WINDOW):
            real_lines = sum(
                1 for ln in content.split("\n")
                if ln.strip() not in SHELL_SCAFFOLDING
            )
            if real_lines < MIN_REAL_LINES:
                continue  # punctuation, not duplicated logic (issue #1134)
            if h in seen_in_file:
                continue  # already recorded this hash for this file
            seen_in_file.add(h)
            preview = "\n".join(content.splitlines()[:3])
            hash_locs[h].append((rel_path, start_lineno, preview))

    groups = []
    for h, locs in hash_locs.items():
        files = {loc[0] for loc in locs}
        if len(files) < MIN_FILES:
            continue
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
    dup_groups = check_duplicates(sh_files, root)

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
        # Same template family — post #1477, planner no longer has ${MEMORY_BLOCK}
        # between CONTEXT_BLOCK and formula_lessons_block, so planner and predictor
        # share an identical 5-line context window.
        "831dcf16d261efabb5d54254bc5e8e58": "Standard prompt template context (CONTEXT_BLOCK, GRAPH_SECTION, SCRATCH_CONTEXT, FORMULA_CONTENT)",
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
        # Verification mode helper functions - intentionally duplicated in dispatcher and entrypoint
        # These functions check if bug-report parent issues have all sub-issues closed
        "b783d403276f78b49ad35840845126a1": "Verification helper: sub_issues variable declaration",
        "4b19b9a1bdfbc62f003fc237ed270ed9": "Verification helper: python3 -c invocation",
        "cc1d0a9f85dfe0cc32e9ef6361cb8c3a": "Verification helper: Python imports and args",
        "768926748b811ebd30f215f57db5de40": "Verification helper: json.load from /dev/stdin",
        "4c58586a30bcf6b009c02010ed8f6256": "Verification helper: sub_issues list initialization",
        "53ea3d6359f51d622467bd77b079cc88": "Verification helper: iterate issues in data",
        "21aec56a99d5252b23fb9a38b895e8e8": "Verification helper: check body for Decomposed from pattern",
        "60ea98b3604557d539193b2a6624e232": "Verification helper: append sub-issue number",
        "9f6ae8e7811575b964279d8820494eb0": "Verification helper: for loop done pattern",
        # Standard lib source block shared across formula-driven agent run scripts
        "330e5809a00b95ade1a5fce2d749b94b": "Standard lib source block (env.sh, formula-session.sh, worktree.sh, guard.sh, agent-sdk.sh)",
        # Test data for duplicate service detection tests (#850)
        # Intentionally duplicated TOML blocks in smoke-init.sh and test-duplicate-service-detection.sh
        "334967b8b4f1a8d3b0b9b8e0912f3bfb": "Test TOML: [agents.llama] block header (smoke-init.sh + test-duplicate-service-detection.sh)",
        "d82f30077e5bb23b5fc01db003033d5d": "Test TOML: [agents.llama] block body (smoke-init.sh + test-duplicate-service-detection.sh)",
        # Common vault-seed script patterns: logging helpers + flag parsing
        # Used in tools/vault-seed-woodpecker.sh + lib/init/nomad/wp-oauth-register.sh
        "843a1cbf987952697d4e05e96ed2b2d5": "Logging helpers + DRY_RUN init (vault-seed-woodpecker + wp-oauth-register)",
        "ee51df9642f2ef37af73b0c15f4d8406": "Logging helpers + DRY_RUN loop start (vault-seed-woodpecker + wp-oauth-register)",
        "9a57368f3c1dfd29ec328596b86962a0": "Flag parsing loop + case start (vault-seed-woodpecker + wp-oauth-register)",
        "9d72d40ff303cbed0b7e628fc15381c3": "Case loop + dry-run handler (vault-seed-woodpecker + wp-oauth-register)",
        "5b52ddbbf47948e3cbc1b383f0909588": "Help + invalid arg handler end (vault-seed-woodpecker + wp-oauth-register)",
        # forgejo-bootstrap.sh follows wp-oauth-register.sh pattern (issue #1069)
        "2b80185e4ae2b54e2e01f33e5555c688": "Standard header (set -euo pipefail, SCRIPT_DIR, REPO_ROOT) (forgejo-bootstrap + wp-oauth-register)",
        "38a1f20a60d69f0d6bfb06a0532b3bd7": "Logging helpers + DRY_RUN init (forgejo-bootstrap + wp-oauth-register)",
        "4dd3c526fa29bdaa88b274c3d7d01032": "Flag parsing loop + case start (forgejo-bootstrap + wp-oauth-register)",
        # Common vault-seed script preamble + precondition patterns
        # Shared across tools/vault-seed-{forgejo,agents,woodpecker}.sh
        "dff3675c151fcdbd2fef798826ae919b": "Vault-seed preamble: set -euo + path setup + source hvault.sh + KV_MOUNT",
        "1cd9f0d083e24e6e6b2071db9b6dae09": "Vault-seed preconditions: binary check loop + VAULT_ADDR guard",
        "63bfa88d71764c95c65a9a248f3e40ab": "Vault-seed preconditions: binary check end + VAULT_ADDR die",
        "34873ad3570b211ce1d90468ab6ac94c": "Vault-seed preconditions: VAULT_ADDR die + hvault_token_lookup",
        "71a52270f249e843cda48ad896d9f781": "Vault-seed preconditions: VAULT_ADDR + hvault_token_lookup + die",
        # Common vault-seed script flag parsing patterns
        # Shared across tools/vault-seed-{forgejo,ops-repo,runner}.sh
        "6906b7787796c2ccb8dd622e2ad4e7bf": "vault-seed DRY_RUN init + case pattern (forgejo + ops-repo + runner)",
        "a0df5283b616b964f8bc32fd99ec1b5a": "vault-seed case pattern start (forgejo + ops-repo + runner)",
        "e15e3272fdd9f0f46ce9e726aea9f853": "vault-seed case pattern dry-run handler (forgejo + ops-repo + runner)",
        "c9f22385cc49a3dac1d336bc14c6315b": "vault-seed DRY_RUN assignment (forgejo + ops-repo + runner)",
        "106f4071e88f841b3208b01144cd1c39": "vault-seed case pattern dry-run end (forgejo + ops-repo + runner)",
        "c15506dcb6bb340b25d1c39d442dd2e6": "vault-seed help text + invalid arg handler (forgejo + ops-repo + runner)",
        "1feecd3b3caf00045fae938ddf2811de": "vault-seed invalid arg handler (forgejo + ops-repo + runner)",
        "919780d5e7182715344f5aa02b191294": "vault-seed invalid arg + esac pattern (forgejo + ops-repo + runner)",
        "8dce1d292bce8e60ef4c0665b62945b0": "vault-seed esac + binary check loop (forgejo + ops-repo + runner)",
        "ca043687143a5b47bd54e65a99ce8ee8": "vault-seed binary check loop start (forgejo + ops-repo + runner)",
        "aefd9f655411a955395e6e5995ddbe6f": "vault-seed binary check pattern (forgejo + ops-repo + runner)",
        "60f0c46deb5491599457efb4048918e5": "vault-seed VAULT_ADDR + hvault_token_lookup check (forgejo + ops-repo + runner)",
        "f6838f581ef6b4d82b55268389032769": "vault-seed VAULT_ADDR + hvault_token_lookup die (forgejo + ops-repo + runner)",
        # Common vault-seed flag parsing: help text + esac pattern
        # Shared across tools/vault-seed-{ops-repo,runner}.sh
        "e42f14335a1236b9c5ea8e0b370898cb": "vault-seed help text + exit + invalid arg (ops-repo + runner)",
        # Common shell control-flow: if → return 1 → fi → fi (env.sh + register.sh)
        "a8bdb7f1a5d8cbd0a5921b17b6cf6f4d": "Common shell control-flow (return 1 / fi / fi / return 0 / }) (env.sh + register.sh)",
        # vault-seed-voice.sh mirrors vault-seed-runner.sh for .env quoting +
        # preconditions (issue #664). Intentional duplication: both seeders
        # must agree on _strip_quote semantics and the precondition guard
        # block so .env → KV writes stay consistent.
        "41c132e129c262b36ebc80b36853326b": "_strip_quote helper start (vault-seed-runner + vault-seed-voice)",
        "fedceb1c601c549ff2726155666ced8c": "_strip_quote helper body (vault-seed-runner + vault-seed-voice)",
        "78c10c8b6f5cfdcd25498ddd258af885": "_strip_quote case pattern (vault-seed-runner + vault-seed-voice)",
        "4752f5b7efb44353932535f587939a1c": "_strip_quote quote-strip case (vault-seed-runner + vault-seed-voice)",
        "e8fbb8f714cc938529c5155326f82b46": "_strip_quote esac + printf (vault-seed-runner + vault-seed-voice)",
        "993f5701a8e02959974f12fe319d4520": "_strip_quote close + DRY_RUN init (vault-seed-runner + vault-seed-voice)",
        "02cfda183e483efb61cf6b17f88f4f3b": "_strip_quote close + DRY_RUN + case (vault-seed-runner + vault-seed-voice)",
        "0a981d7d1b71db0c948e2d51394388f4": "Precondition binary check loop (vault-seed-runner + vault-seed-voice)",
        "33746afae6ef9b929b28f35196430043": "Precondition binary check body (vault-seed-runner + vault-seed-voice)",
        "440be711c8dacb6d38a0596e5837f135": "Precondition binary check + _hvault_default_env (vault-seed-runner + vault-seed-voice)",
        "d83556898ab0dc34a2596258af74d06c": "Precondition done + _hvault_default_env + VAULT_ADDR (vault-seed-runner + vault-seed-voice)",
        "efaa2b9d9e444ec9173d40a0c20d5b9b": "Precondition _hvault_default_env + VAULT_ADDR die (vault-seed-runner + vault-seed-voice)",
        # chat-init.sh + vault-seed-chat.sh KV merge/payload building (issue #678)
        "d95e807c86be214ce0ca251701074214": "KV merge: payload build start with forge_pat (chat-init + vault-seed-chat)",
        "04304b32f5a3fd08f557d565d85fa6e9": "KV merge: forge_pat jq assignment (chat-init + vault-seed-chat)",
        "27996456928c36ca239d730e5cbd64d1": "KV merge: forge_pat end + nomad_token start (chat-init + vault-seed-chat)",
        "38fd55ad487ef042d8def123a1c94ccd": "KV merge: nomad_token jq assignment (chat-init + vault-seed-chat)",
        "2a082ff8bb20d74731b73fdcf6859208": "KV merge: nomad_token end + oauth_client_id start (chat-init + vault-seed-chat)",
        "3d732e7400de6f5bfb45907557df7001": "KV merge: oauth_client_id jq assignment (chat-init + vault-seed-chat)",
        "c8b15cc834b0e5f16382d1a4b46e10b8": "KV merge: oauth_client_id end + oauth_client_secret start (chat-init + vault-seed-chat)",
        "866c69dd155dbdb7486dcd81ec0e6f59": "KV merge: oauth_client_secret jq assignment (chat-init + vault-seed-chat)",
        "a622d3d27f4dfe9f61977423d6921dd6": "KV merge: oauth_client_secret end + forward_auth_secret start (chat-init + vault-seed-chat)",
        "8a8e3c3ddb8fdf0c062f20358c0077bc": "KV merge: forward_auth_secret jq assignment (chat-init + vault-seed-chat)",
        "eb507da1eee0edd9c2463b8ca2f8d76c": "KV merge: forward_auth_secret end + generation check (chat-init + vault-seed-chat)",
        "d6523ac02cc30556164af4c5c903788f": "KV merge: forward_auth_secret generation block (chat-init + vault-seed-chat)",
        "79a50d21e1f73914cb03dbd593c5d42f": "KV merge: data wrap + _hvault_request POST (chat-init + vault-seed-chat)",
        "4c4bd162b4fed39ceae1dab1fbe5e914": "KV merge: data wrap + _hvault_request POST (chat-init + vault-seed-chat)",
        "c1a8098cc746fc7b6a01abb455f7d293": "KV merge: generation block start (chat-init + vault-seed-chat)",
        "34db504293973ffc8ac4b3ec59575604": "KV merge: generation block body (chat-init + vault-seed-chat)",
        "35f27d9d5467d10592618a4a4458901c": "KV merge: generation block end (chat-init + vault-seed-chat)",
        "53824d870799cf8bd7b19418e3466729": "KV merge: data wrap (chat-init + vault-seed-chat)",
        "79f7dd039fcfd455d21b9c2a41ea47de": "KV merge: data wrap + POST (chat-init + vault-seed-chat)",
        # Snapshot collector main() — identical merge pattern across forge + nomad
        # Both collectors follow the same architecture: check state.json, build data,
        # merge with jq, write atomically, log result. Intentional duplication.
        "f92b93f26ab2adc223b3919b78c8c44f": "Snapshot main() start: closing brace + main() + state.json check (snapshot-forge + snapshot-nomad)",
        "5f81cc4d353bbf9f23f34eaf38b2b60e": "Snapshot main() body: main() + state.json check + skip message (snapshot-forge + snapshot-nomad)",
        # TMPFILES / mktemp_safe / cleanup live in lib/snapshot-tmp.sh since #1096;
        # the three collectors that resolve FACTORY_ROOT inline (rather than
        # inheriting it from an earlier source) repeat the resolution lines.
        "ee2a3d72cece650e1ee0822c7844c9c7": "Snapshot FACTORY_ROOT resolution + source of lib/snapshot-tmp.sh (snapshot-agents + snapshot-forge + snapshot-nomad, #1096)",
        # snapshot-inbox.sh shares standard env-var header with other snapshot collectors
        "816df0fd43ba5676531c08e63ea1c4f8": "Snapshot env-var header (set -euo + FACTORY_FORGE_PAT + FORGE_URL + FORGE_REPO + SNAPSHOT_PATH) (snapshot-forge + snapshot-inbox)",
        # Standard --help heredoc closing + flag-parser tail (cluster-up.sh + sync-nomad-client-config.sh, #789)
        "2882d287343e26a4d8d6499e4bd38c26": "Help heredoc EOF + exit 0 + unknown-flag die + esac (cluster-up + sync-nomad-client-config)",
        "8f6432aafe427171507274ef71c1b612": "Help exit 0 + unknown-flag die + esac + done (cluster-up + sync-nomad-client-config)",
        # forge_api_all inlined into lib/env.sh while still present in lib/forge-paginate.sh
        "6ca76cb74139771aca2df9cf2f858e9a": "forge_api_all signature (env.sh + forge-paginate.sh)",
        "01c1445d61d56be67ca41173d3f9bb1b": "forge_api_all local vars (env.sh + forge-paginate.sh)",
        "3bf71e9a1b5dc079ab2418cd22e1e5be": "forge_api_all case start (env.sh + forge-paginate.sh)",
        "3884eb90560e8466e18345a0bbffb18b": "forge_api_all path_prefix check (env.sh + forge-paginate.sh)",
        "e92d12d91a35dce42bb7fa0297b18f00": "forge_api_all separator logic (env.sh + forge-paginate.sh)",
        "8dbb47d62365219b5e8a0418c443b8ac": "forge_api_all esac (env.sh + forge-paginate.sh)",
        "1e83d159e5e3244b98219fef890d4142": "forge_api_all window env.sh:241 + forge-paginate.sh (inlined function)",
        "f3b6f7521eb616bfa9dbeb2985b50077": "forge_api_all window env.sh:242 + forge-paginate.sh (inlined function)",
        "c2c1df8184b838251b4c0ed39a7a0860": "forge_api_all window env.sh:243 + forge-paginate.sh (inlined function)",
        "9276d71ea72d9dbcd8bb1f91eb87942f": "forge_api_all window env.sh:244 + forge-paginate.sh (inlined function)",
        "2b5a82793a819934b53e6f42e4aa7f4a": "forge_api_all window env.sh:245 + forge-paginate.sh (inlined function)",
        # Per-issue acceptance tests each embed the same self-contained
        # fake-curl HTTP stub (test-harness boilerplate; one copy per issue
        # keeps each acceptance test isolated). Intentional duplication, not
        # copy-paste — issue-1469.sh <-> issue-1471.sh.
        "db1a3733eafe76e0d23f371a17f1bb7d": "Fake-curl stub bootstrap (set -u) issue-1469.sh + issue-1471.sh",
        "f970e060b0b5b8514b5ed8be636caca3": "Fake-curl stub STUB_INVOKED_FILE check issue-1469.sh + issue-1471.sh",
        "507491e372adae5ec187d4c396ff5d78": "Fake-curl stub STUB_INVOKED_FILE touch issue-1469.sh + issue-1471.sh",
        "f1ea96893e9d4d5a22cbc8b05b4887b3": "Fake-curl stub closing fi issue-1469.sh + issue-1471.sh",
        "84083c503ada1be26cbf2d883472643c": "Fake-curl stub args capture issue-1469.sh + issue-1471.sh",
        "d603d2ed5c50dabc59c915a27167152d": "Fake-curl stub arg count issue-1469.sh + issue-1471.sh",
        "c6dd49b2e34797fffe4401d5544aa723": "Fake-curl stub index init issue-1469.sh + issue-1471.sh",
        "b763b708e92c4a819fb26ca30cc7a499": "Fake-curl stub payload init issue-1469.sh + issue-1471.sh",
        "8f372ed5f3e253945a05fc6bcf4b4711": "Fake-curl stub auth init issue-1469.sh + issue-1471.sh",
        "d47cc6e003cdd6dd42c3c67d2fbf5a9f": "Fake-curl stub else issue-1469.sh + issue-1471.sh",
        # issue-1635.sh: dev-proposal test with a custom fake-curl stub (it must
        # return a specific issue title/body for the payload test). Like the
        # 1469/1471 stubs above, each acceptance test embeds its own isolated
        # stub; the shared header/footer windows match the existing issue-1443.sh
        # stub and the shared ac_write_curl_stub() in acceptance-helpers.sh.
        # Intentional duplication, not copy-paste.
        "843d770640be4c8a26e94043c3574688": "Fake-curl stub header url=$*+AC_STUB_FAIL+exit22 (issue-1635.sh + acceptance-helpers.sh)",
        "648b60705cf337225e5b864e695f2b08": "Fake-curl stub footer esac+STUB+chmod (issue-1635.sh + issue-1443.sh)",
        # issue-1536.sh: a self-contained *counting*, per-attempt stub plus its
        # throwaway ledger fixture. Like the 1469/1471 stubs above, each
        # acceptance test is deliberately isolated (no network, own tmp dir,
        # own stub), so its per-attempt run_jev mirrors fake-typesafe.sh's shape
        # and its ledger fixture mirrors issue-1471.sh's. Intentional
        # duplication, not copy-paste.
        #
        # Ledger fixture (issue-1471.sh <-> issue-1536.sh): mktemp +
        # ACCOUNTS_FILE init + trap + the approve_row() helper.
        "08bcb9f5a82b685670efdd40a33f7e4f": "Fixture TMP_DIR+ACCOUNTS_FILE+trap (issue-1471.sh + issue-1536.sh)",
        "c4bb9f895c7c3883640b0a2dc881ffb9": "Fixture ACCOUNTS_FILE+trap+accounts.json init (issue-1471.sh + issue-1536.sh)",
        "08c81e7dfaf4b8f22ea2bf9a791df56a": "Fixture trap+init+approve_row() (issue-1471.sh + issue-1536.sh)",
        "5899985e8370a006a3fc5f5550333a8b": "Fixture init+approve_row()+local fp (issue-1471.sh + issue-1536.sh)",
        "b29d18f31cf6da8f7249c4897805e6fc": "Fixture approve_row()+local fp+jq flip (issue-1471.sh + issue-1536.sh)",
        "792b634117c929cbfed82cde41c3bdd9": "Fixture local fp+jq flip+tmp write (issue-1471.sh + issue-1536.sh)",
        # Counting per-attempt run_jev (issue-1536.sh <-> tests/lib/fake-typesafe.sh):
        # 1536 needs a *different* code/body per attempt plus an invocation counter,
        # so it reuses the same run_jev shape, passing STUB_CODES/STUB_BODIES/
        # STUB_INVOKED_FILE.
        "69f4237da94b9abe8512694e45f73922": "Counting run_jev RC=0+OUT subshell+key guard (issue-1536.sh + fake-typesafe.sh)",
        "1553934c17986e1ce8590de465c6e8d3": "Counting run_jev OUT subshell+key guard (issue-1536.sh + fake-typesafe.sh)",
        "882551614692afca2f8f0edd950c0a75": "Counting run_jev key guard if/else (issue-1536.sh + fake-typesafe.sh)",
        "660df288b64a8a95a585a9bbd0eae1f6": "Counting run_jev TYPESAFE_API_KEY export/unset (issue-1536.sh + fake-typesafe.sh)",
        "3914f2e0d3bbd8fc65b894f7f623e83c": "Counting run_jev jev invocation+ERR capture (issue-1536.sh + fake-typesafe.sh)",
        # issue-1559.sh: Caddy-stub acceptance test for the revoke verb, kept
        # deliberately isolated (one self-contained throwaway-root / caddy-stub /
        # run_* / no_dns_request / ledger fixture per issue) like the other
        # per-issue edge tests (issue-1558.sh approve). Intentional duplication,
        # not copy-paste.
        # (a) issue-1557.sh <-> issue-1559.sh: JSON ledger row (created_at+pubkey+close).
        # (b) issue-1558.sh <-> issue-1559.sh: porter-dns source check,
        #     cleanup+trap, ac_caddy_stub, new_root(), the run_* envs array,
        #     and no_dns_request.
        "b1f0952a3b66119a29842a6b1450bd2a": "Ledger JSON row (created_at/pubkey) issue-1557.sh + issue-1559.sh",
        "6de1b411275d8e73b12fbf2f13d51945": "porter-dns source check (if grep header) issue-1558.sh + issue-1559.sh",
        "9025fae0708ad60a46bc41808498f137": "porter-dns source check (if grep + ac_fail) issue-1558.sh + issue-1559.sh",
        "219ecd98ced396dc8a2b25446d66569f": "cleanup() head (rm -rf TMP_DIR) issue-1558.sh + issue-1559.sh",
        "b10f981336e40ee8f81e5ea38641fadb": "cleanup() tail + trap cleanup EXIT issue-1558.sh + issue-1559.sh",
        "7a052f89066a9a491598f78c763cda58": "cleanup close + trap + ac_caddy_stub issue-1558.sh + issue-1559.sh",
        "93108ad8a8e5d6931bbc577c67c5a2e5": "trap + ac_caddy_stub + new_root() issue-1558.sh + issue-1559.sh",
        "66502becedf992284369767b425513a3": "ac_caddy_stub + new_root() + local issue-1558.sh + issue-1559.sh",
        "06577562f12a90ac0b35d750cb1fe57d": "new_root() + local name + ROOT issue-1558.sh + issue-1559.sh",
        "e0f30c5b3f7c237a9a5be1de0c37ca6f": "new_root() local + ROOT + mkdir issue-1558.sh + issue-1559.sh",
        "eb2a78f7149fed574248b161c2bc41f6": "run_* envs: local + PATH + ACCOUNTS_FILE issue-1558.sh + issue-1559.sh",
        "b930bbd8df2822d3f035a0820810d9bd": "run_* envs: PATH + ACCOUNTS_FILE + REGISTRY_DIR issue-1558.sh + issue-1559.sh",
        "10673888bff26ebb8e49da185ad11c72": "run_* envs: ACCOUNTS_FILE + REGISTRY_DIR + PORTER_ROOT issue-1558.sh + issue-1559.sh",
        "d3105d5dd09a93c7492dc672fd400856": "run_* envs: REGISTRY_DIR + PORTER_ROOT + CADDY_ADMIN_URL issue-1558.sh + issue-1559.sh",
        "42fb4798b8d5b0425759d820a054c10c": "run_* envs: PORTER_ROOT + CADDY_ADMIN_URL + DOMAIN_SUFFIX issue-1558.sh + issue-1559.sh",
        "21d0ad4b606da27338e423659c050d65": "no_dns_request() head issue-1558.sh + issue-1559.sh",
        "7b6f778ac9d29488bec37787a2ff4e17": "no_dns_request() if + ac_fail issue-1558.sh + issue-1559.sh",
        # issue-1561.sh (stripe webhook: add_webhook_route) vs issue-1555.sh
        # (adopt/install): both are per-issue Caddy-stub edge tests, kept
        # deliberately isolated (own throwaway root, own caddy-stub, own
        # run_webhook_route / run_route helper, and the same ac_require_cmd +
        # PORTER_CADDY/CADDY_LIB file asserts). The shared 5-line setup + run_*
        # windows are intentional duplication, not copy-paste — the same
        # convention as issue-1558.sh <-> issue-1559.sh above.
        "8d59b1943824b6e13d761460ff07dd97": "caddy-stub source + ac_require_cmd setup (issue-1555.sh + issue-1561.sh)",
        "15424bc30ad7ab8bae7c9310bcfe3adc": "ac_require_cmd + PORTER_CADDY setup (issue-1555.sh + issue-1561.sh)",
        "7c2b556bb7f17224c4743dffa421c591": "PORTER_CADDY + ac_assert_file setup (issue-1555.sh + issue-1561.sh)",
        "18d4d2b26f904a1097dc60cbd32ceb31": "run_* head: local + out_file + err_file (issue-1555.sh + issue-1561.sh)",
        "c78ed193bad81acd79ceb86ee6008daa": "run_* out_file + err_file + rc init (issue-1555.sh + issue-1561.sh)",
        "77f7aad58b618b67a5b04eb9d4bd54b5": "run_* err_file + rc + err init (issue-1555.sh + issue-1561.sh)",
        "afa17e7361941758805d0defaf69d204": "run_* rc + err + block open (issue-1555.sh + issue-1561.sh)",
        "90f6a1edce24225ef84e3ce18d6dc676": "run_* block open + PATH export (issue-1555.sh + issue-1561.sh)",
        "916ac222b6cc0a1ac3d116eb31f5d8d7": "run_* PATH + CADDY_ADMIN_URL export (issue-1555.sh + issue-1561.sh)",
        # issue-1571.sh (fresh Caddy wildcard cert) vs issue-1555.sh / issue-1556.sh /
        # issue-1561.sh: same family of per-issue Caddy-stub edge tests, kept
        # deliberately isolated (own throwaway root, own caddy/systemctl stubs).
        # The shared PORTER_CADDY/CADDY_LIB file-assert + install.sh sanity window,
        # the rc=0/cleanup()/trap boilerplate, and the systemd-enable / env.GANDI_API_KEY
        # source checks are intentional duplication, not copy-paste — same convention as
        # issue-1555.sh <-> issue-1561.sh above.
        "8bf760fb109d2e467f281e314bc3c11b": "PORTER_CADDY/CADDY_LIB asserts + install.sh check (issue-1555.sh + issue-1571.sh)",
        "c756f85cce92fdefbdf959979b25a9d4": "CADDY_LIB assert + install.sh check head (issue-1555.sh + issue-1571.sh)",
        "02fe0e12105ba3573f1018b8f863de1a": "install.sh check if/grep/ac_fail (issue-1555.sh + issue-1571.sh)",
        "09a839ef2f72e4d3158beae7dc0879a0": "install.sh check grep+ac_fail+fi (issue-1555.sh + issue-1571.sh)",
        "02ab539d7441c68b87f714f3bcd8f870": "cleanup() head (rm -rf + } + trap) (issue-1556.sh + issue-1571.sh)",
        "9bde44682bdc27bf9c7258286649208b": "cleanup() tail + trap cleanup EXIT (issue-1556.sh + issue-1571.sh)",
        "8a094008e3c39f88ec7e8fbc38709d93": "rc=0 + cleanup head (issue-1561.sh + issue-1571.sh)",
        # issue-1578.sh (porter-dns LiveDNS records API fix) vs issue-1556.sh
        # (porter-dns ensure-once): both are per-issue acceptance tests for
        # tools/edge-control/porter-dns.sh, kept deliberately isolated (own
        # throwaway root, own Gandi LiveDNS curl stub, own fixture helpers
        # make_root / write_token_file / run_dns, own assertion helpers). The
        # shared cleanup/trap/stub-dir setup, the embedded fake-curl stub, the
        # fixture helpers, and the bad_url / token assertions are intentional
        # duplication, not copy-paste. These hashes are computed against the
        # CURRENT content of both acceptance tests (post-fix LiveDNS stubs) and
        # are refreshed whenever 1556/1578 share-code changes.
        "0a02a6b5bc3ea15b808717c52dc4b586": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "0baf6e15e2fec39bfb4d8e51a54f869c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "0e25f897f78d6d83c21117086d7dcc5b": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "1296e6a0664083ac9510f68303bc169e": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "13710b54711ae75d423765f7377e2b08": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "144834a9605141222d567d23b21092e8": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "17dc8fbcee80da6560fc00d3d72543c9": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "18c5529529a64bb5c394b5ca031ab978": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "1a425d842122f1e551b88c1aaa7e2781": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "2107a0a18ea3acc85acd0c1e17a7e065": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "237619290867a73eb217bad61c442e4d": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "289106350f203a794f142c400118897c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "2c31766aa6669fdbfc6ef93da1617a6a": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "2fb8587550c477797af2b3ebb33923cb": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "3054306ceee643fb4b05cc7055feef3a": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "32294da9d170a8ebf22fa5ad768caa70": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "329594edc52b44d7669376f3a38afe9c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "399e39477aae84f9197bce023764f871": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "3faba9f832dac1a71156e214d85a1dd0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "427daf36ae74fb945396a031b035bccf": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "4408460afae8aa1e7f91e2fa12a86471": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "44994f1464a5b8d4df9c2d2d3acb9c14": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "4901511250f7eeba2874a2c50d284f87": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "4935e10f101955b062b8598397194de8": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "4d97cdec2acd2d8d58bb9bf32a0fb928": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "4f2d09f282ab76e402526ea5294bc651": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "536f0fad56a55225cc0f0dd4e2a9719c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "5c3a50712333f9f2c59b3c2b77a09eb0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "60f3211802865fb2459033c20710a9ed": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "648bc6b265d64ee4b7312c837e585f4b": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "66b9317760b002434fe3323b2042cf68": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "68c71c1b77763b1c05fa2a5d6342e2da": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "6f998515280be965bf6b3cee042356bb": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "74e3d7fa9ca8e7ae3ff95d62add1105e": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "7a448c8ca98875603e353da18e2c1e7c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "7ad204587028d5debfe7719f0099d504": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "816500ab114a693894680e082c01bded": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "857344bbf61942b87efe37777a44a674": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8786b35d915aea91c9eaea44f51c704a": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8a1ea693756c69cc2aa3411d1f620ac0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8aa3825347f0f4554ba715f926d8a2e0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8ac8ca9e6917a17d47833a24549449de": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8b71d372fa0dcd1f009997ad0aa0a635": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8cc3d46a69dee48e834dc34ade788da9": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8e09a3a64a6342d96981656d495722d9": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "8ff24e09fcfc920215c0ec250142cc75": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "9586a39a24d60e3a9a3fd588c9fc12c7": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "97c947550aa592b91898b134372f3ca3": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "97f1f7cd32841843ac07ddc8e75f86a0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "99d6e39b85b2368e877f7f6fd9e0483c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "9b36c96c05d6dc0b1211a9cd96ca9dea": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "9f822a40ed7963476d0600788ff67fd6": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "a05fb9c21884650d23e5cb24a210835e": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "a247b0b9928450fce88e0edfcc1d64f1": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "ae55ab50ded8f6041cae30eb3b893aa8": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "b2d2f98b8390bc74c93fa6ef31331894": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "b6cfbe3dc2616a3c78dd46f47521ff96": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "bfaa265a920f6fba9e2732599734a860": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "c41c1b337311f3343040599abe80765c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "c4ca289dd27e95c0c73abb7d9799b006": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "cd4792e33dfff3febf5751359088509e": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "cf8fef6c53f6038fd6a7ddce248ab625": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d24ad23779c46f27437f19b192087562": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d25d49b3dd79ed7a12f7392756c930d9": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d592c97ca8f8b7981c7545d08005d435": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d703b33fccc753a7ec9b23a2f88d6448": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d7678d1752675820c1403d0f6f798717": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "d798a633f01fa85a1bf9d3a78e2d4c4f": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "daa019f148572194de55b00b98d4d73f": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "de87c4544fa2e5eda049f6c908da377c": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "dfd23f33d35aceadcc56d30da608ebc0": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "e5cf3bed80dffdd0b467a46666938644": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "eebd49ac27e848803ece8ec657c763c2": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f462e4088085632f77fbd35be5ad99cb": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f4b75378df7781f3665b067155e2f9bd": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f59160050b847108b2775d284743f05b": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f6049264d1de40d6d14a7a2a1189a45a": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f66b50d1ae9c27b9717d8589b1f75cc7": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f67588b8f67144cb89210d0d658d7e67": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "f77bdd183dc8f2273d21e2ad40976bd5": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "fa3f1957271102fc870ab0f5e94d494b": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "fd1b7f6766a376467194bc1959118581": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "fded45133f80e3ff210abf34338e25cc": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",
        "fe7cc9852342e2ba425d4d5cf5a88342": "LiveDNS stub shared block (issue-1556.sh + issue-1578.sh)",

        # --- 1555 <-> 1579 (Caddy stub / self.disinto.ai fixture) -------------------
        # issue-1555.sh (adopt) and issue-1579.sh (wildcard cert / #1579) both seed
        # the same `self.disinto.ai { reverse_proxy 127.0.0.1:20000 }` Caddyfile
        # fixture for their AC3b/AC2 no-op checks — intentional per-test isolation
        # (same family as 1555 <-> 1561 / 1555 <-> 1571), not copy-paste.
        "25ccdd590a4596ef3f12b22e3e014e86": "self.disinto.ai Caddyfile fixture (issue-1555.sh + issue-1579.sh)",
        "c9cf6f3c7dd364a3f73eb5d06a93333e": "self.disinto.ai Caddyfile fixture (issue-1555.sh + issue-1579.sh)",

        # --- 1571 <-> 1579 (Caddy stub / caddy + systemd) ---------------------------
        # issue-1571.sh (fresh, caddy + systemd) and issue-1579.sh (fresh, caddy +
        # systemd) both run the same portable caddy/systemctl call-recording stub
        # (PORTER_ROOT + run_install/systemctl stub + env PATH=...), the run_install()
        # driver, and the same AC1 fresh-install checks (rc / CADDYFILE / extra.d).
        # The 19 windows below are the sliding 5-line pieces of that shared driver.
        # Intentional per-test isolation (issue-1571.sh <-> issue-1579.sh), not
        # copy-paste.
        "1ca75ad7ec54fc8135d5e8607ec61322": "caddy/systemctl stub end + run_install() head (issue-1571.sh + issue-1579.sh)",
        "d5a74137b167dba603e25f2382c1564f": "run_install() local vars (issue-1571.sh + issue-1579.sh)",
        "408cecb0c153b65afbbb5b6bbe41ecc1": "run_install() local vars (issue-1571.sh + issue-1579.sh)",
        "8215ce11907e362cac76dbedefe14bed": "run_install() env PATH + run (issue-1571.sh + issue-1579.sh)",
        "0cbc9d8b73086c954cb4ae1b280c3f14": "run_install() env PATH + run (issue-1571.sh + issue-1579.sh)",
        "eaf910a6f69a21ac40759130d6133a53": "run_install() env PATH + run (issue-1571.sh + issue-1579.sh)",
        "9bf9497eeaa844b34317630ebf69a46e": "run_install() env PATH + run (issue-1571.sh + issue-1579.sh)",
        "b714fa75ae31bd2a10eec4d8a603ac1f": "run_install() env PATH + run (issue-1571.sh + issue-1579.sh)",
        "2066abd2d43b24cbc0af1b9cc8ad6fbe": "run_install() env PATH + run + redirect (issue-1571.sh + issue-1579.sh)",
        "a9870b725f1123c9703425ffd6a7cde1": "run_install() env PATH + run + redirect (issue-1571.sh + issue-1579.sh)",
        "ff08d87e2231ad13deb29bc9b0ddaeb5": "run_install() end + ROOT1 + run (issue-1571.sh + issue-1579.sh)",
        "20fac03970bd7ce17fe7f7f650644d08": "run_install() end + ROOT1 + run (issue-1571.sh + issue-1579.sh)",
        "748880b8c50d0e128b7ae0a07941f670": "run_install + rc check + ac_fail (issue-1571.sh + issue-1579.sh)",
        "723a555ad530dcd8ca270fbcec418107": "run_install + rc check + ac_fail (issue-1571.sh + issue-1579.sh)",
        "348bea2e1937235f835c06f56cd734c1": "run_install + rc check + ac_fail (issue-1571.sh + issue-1579.sh)",
        "95066cef7e247701a025b0e9f936ce3b": "run_install + rc check + ac_fail (issue-1571.sh + issue-1579.sh)",
        "ff23279c3f66bae2348097562d0b255c": "run_install + ac_fail + CADDYFILE (issue-1571.sh + issue-1579.sh)",
        "fa5222594ec22a825a19e129c06f288f": "CADDYFILE + ac_fail missing (issue-1571.sh + issue-1579.sh)",
        "64bb5cdad731ee3960038739c1a532c1": "CADDYFILE + ac_fail missing (issue-1571.sh + issue-1579.sh)",
    # --- 1560 <-> 1581 (porter-dns / sshd-gate acceptance tests) -------------------
    # issue-1581.sh (#1581) and issue-1560.sh (#1560) are per-issue edge acceptance tests
    # kept deliberately isolated (own throwaway root, own GANDI fake-curl stub, systemd/sshd
    # stubs, make_root / run_install drivers, AC subshells) per the per-test-isolation convention
    # used by 1555 <-> 1559 / 1556 <-> 1578 / 1571 <-> 1579. Shared 5-line windows are intentional
    # isolation, not copy-paste. Hashes computed against CURRENT content of both tests; refresh if
    # their shared boilerplate changes.
        "48fab60e8ca0a42f49924b5e865c8112": "cleanup head (rm -rf TMP_DIR + }) issue-1560.sh + issue-1581.sh",
        "41ddc79154b8599acbbe7f29be72cc3f": "cleanup tail + trap cleanup EXIT issue-1560.sh + issue-1581.sh",
        "5203592baee76a7b1edca82b7228795a": "trap + STUB_DIR + mkdir -p issue-1560.sh + issue-1581.sh",
        "90f54955f9b2b762e6f92e73e12999ff": "STUB_DIR + mkdir + curl heredoc open issue-1560.sh + issue-1581.sh",
        "e35ce339aa83eff05a5e879dc0a49748": "mkdir + curl heredoc + state= issue-1560.sh + issue-1581.sh",
        "dccc81b96dcb4a834f96bec8c0b47d8f": "curl heredoc + state + log= issue-1560.sh + issue-1581.sh",
        "5f106460733c5b70f50ba4494047ffb7": "state + log + method=GET issue-1560.sh + issue-1581.sh",
        "169553cc3341a7fb4c3d9834926d2f2e": "log + method + url="" issue-1560.sh + issue-1581.sh",
        "b037d37b4e5f440ed25d782ae53ecc42": "method + url + body="" issue-1560.sh + issue-1581.sh",
        "6e280c415360d1539739fd4e26f2a511": "url + body + auth="" issue-1560.sh + issue-1581.sh",
        "7bcb43cc4fcd9ed67932b4a4d37820bf": "body + auth + while loop start issue-1560.sh + issue-1581.sh",
        "b2146ef1fb9c00c82314897b97332e6c": "body + auth + while [[ $# -gt 0 ]]; do issue-1560.sh + issue-1581.sh",
        "9b5eeb38d732351aecc65b070bfd7a31": "curl stub arg case (-d/-o/-f) issue-1560.sh + issue-1581.sh",
        "97e0e2c3c1484a5afd9bb678c1539ed7": "curl stub arg case (-o/--max-time) issue-1560.sh + issue-1581.sh",
        "5b0d0d8998eab11c54a59dd8b9e92d60": "curl stub arg case (-f/--*|-*) issue-1560.sh + issue-1581.sh",
        "0a30c09328abd3ca4a87559a77c0a384": "curl stub arg case (--max-time/--*) issue-1560.sh + issue-1581.sh",
        "84923bc48560db3f24b2f53323f35e0b": "curl stub arg case (--*) + url parse issue-1560.sh + issue-1581.sh",
        "7b0386c9c134627bf9c011af9cf5be2d": "case esac + done + url check issue-1560.sh + issue-1581.sh",
        "d2d328e2e613ab49b26d2482f403f8e6": "done + url + state check issue-1560.sh + issue-1581.sh",
        "1b8f3c0ee937eaac5959b14bd55d0d4d": "url + state + log-if open issue-1560.sh + issue-1581.sh",
        "b8422c61bae8097e36ce5c76721cc8d6": "state + log-if + printf json issue-1560.sh + issue-1581.sh",
        "a6d4552676ea7d4a37e22435284a2ffa": "log-if + printf + log append issue-1560.sh + issue-1581.sh",
        "5fb6f72cf9f95c535a0b2ec08cfe7d1f": "printf + log append + fi issue-1560.sh + issue-1581.sh",
        "1fdcfa9e880eb1f46b154a3272429da7": "log append + fi + case open issue-1560.sh + issue-1581.sh",
        "66daf55d39500c0bde06dc28910a18d9": "fi + case + records pattern issue-1560.sh + issue-1581.sh",
        "5026fca1e0c0fd7744ce87f9b6e5208d": "case + records + jq state issue-1560.sh + issue-1581.sh",
        "32f448d968bbb95416c61f9e509b0513": "jq --argjson b + A-record jq issue-1560.sh + issue-1581.sh",
        "fef69941556fc7b2ba22a1f0cbc371b3": "A-record jq + atomic state mv issue-1560.sh + issue-1581.sh",
        "3b094b98462f96485c7cc3594d22e416": "case *) + echo [] + esac (curl tail) issue-1560.sh + issue-1581.sh",
        "90986882b735b8e5d529398c7fdf4fa7": "chmod sshd + systemctl stub printf issue-1560.sh + issue-1581.sh",
        "d2a1e8d07480e6950659e5df19886089": "make_root() head issue-1560.sh + issue-1581.sh",
        "38d04e585416e12e74f77af73524be5c": "make_root() local + mkdir porter issue-1560.sh + issue-1581.sh",
        "1e43b4d719763f8e039cca6741861f3a": "make_root() mkdir + gandi.env printf issue-1560.sh + issue-1581.sh",
        "c6c65486337e0ffcb0b6502399c9037d": "make_root() gandi.env printf + chmod 600 issue-1560.sh + issue-1581.sh",
        "e9d6b560c19d3fde25a4a6ce3eddc59d": "run_install() local vars issue-1560.sh + issue-1581.sh",
        "f12aca78aa45b0cdb5c89da7552e95c0": "run_install() arg + PORTER_ROOT/PUB_IP export issue-1560.sh + issue-1581.sh",
        "7e454574ccf01027c0f7ecdec231cadf": "AC subshell open + set -u issue-1560.sh + issue-1581.sh",
        "c4bcc0c246c62f814b7f4e0372947772": "AC subshell set -u + PATH issue-1560.sh + issue-1581.sh",
        "04b9731d4af280e29c748c0a52bbd274": "AC subshell PATH + SSHD_RC + sctl log issue-1560.sh + issue-1581.sh",
        "000e8e8acddf3d483def43bc4479b9a2": "sctl log + rc=0 + subshell open issue-1560.sh + issue-1581.sh",
        "cb316a1f809e126a09e8b818eed77ee5": "AC subshell PATH + SSHD_RC + sctl (AC2) issue-1560.sh + issue-1581.sh",
        "a213d2740705c98a5a1f5607ac180614": "AC subshell SSHD_RC + sctl + source reload-fn (AC2) issue-1560.sh + issue-1581.sh",
        "6460981c77636aa59af8aa5d6fe3a3e2": "source reload-fn + reload + subshell close (AC2) issue-1560.sh + issue-1581.sh",
        "803addb7f66c5d04d1c0e7dbdb5162c2": "sctl log + rc=0 + subshell open (AC3) issue-1560.sh + issue-1581.sh",
        "2efb98bac5ebe396d3bde2bc3d54cb48": "AC subshell PATH + SSHD_RC (AC3) issue-1560.sh + issue-1581.sh",
        "8573efd6496b1fb77b3f73939eaf82a2": "AC subshell SSHD_RC + sctl + source (AC3) issue-1560.sh + issue-1581.sh",
        "6409951b0ce992766dd95e69abbe636e": "AC subshell sctl + source + reload (AC3) issue-1560.sh + issue-1581.sh",
        "cfde7c99a55373e695e991c4564dbc8d": "source + reload + subshell close (AC3) issue-1560.sh + issue-1581.sh",
        "d2d547119cca47baf43483e19315231a": "reload + subshell close + rc assert (AC3) issue-1560.sh + issue-1581.sh",
        "10f5e53ed1c75ff04eb3df8c7ad2ea35": "subshell close + rc assert + grep reload ssh (AC3) issue-1560.sh + issue-1581.sh",
        # --- 1581 <-> 1595 (porter-install / sshd-gate acceptance tests) --------------
        # issue-1595.sh (#1595) and issue-1581.sh (#1581) are per-issue edge acceptance
        # tests of the same lib/edge-control/porter-install.sh, kept deliberately isolated
        # (own throwaway root, own GANDI fake-curl stub, systemd/sshd stubs, make_root /
        # run_install drivers, AC subshells) per the per-test-isolation convention used by
        # 1555 <-> 1559 / 1556 <-> 1578 / 1571 <-> 1579 / 1557 <-> 1582 / 1560 <-> 1581.
        # Shared 5-line windows are intentional isolation, not copy-paste.  Hashes computed
        # against CURRENT content of both tests; refresh if their shared boilerplate changes.
        "ffa9ab14d2c70dbc8a3a0e87a480d5d2": "auth= + while arg-parse head (curl stub) issue-1581.sh + issue-1595.sh",
        "b0a1f570bb8477e2c8388c9092fe2e09": "while $# loop + case $1 (curl stub) issue-1581.sh + issue-1595.sh",
        "978962655ea3a6d013e233f289afdd9a": "case $1 + -X (curl stub arg parse) issue-1581.sh + issue-1595.sh",
        "764eda9964894d5e480d4b8609ae95bc": "-X method + -u url (curl stub arg parse) issue-1581.sh + issue-1595.sh",
        "61e54aeb64d38ded21c1a17db3ea8a8c": "-u url + -H auth + -d body (curl stub arg parse) issue-1581.sh + issue-1595.sh",
        "80b707feed1a4c6626248feaaed572f3": "-H auth + -d body + -o shift (curl stub arg parse) issue-1581.sh + issue-1595.sh",
        "31fddb3a0386ccd3f6390fa6485b8b06": "echo [] + esac + AC_GANDI_STUB (curl heredoc end) issue-1581.sh + issue-1595.sh",
        "00346186ff3b5c3705221b15760f7dc0": "printf GANDI_API_KEY + chmod 600 (make_root gandi.env) issue-1581.sh + issue-1595.sh",
        "a706a325fc05cc1df5b93e6cda95d59f": "chmod 600 + } + state-agree printf (make_root end) issue-1581.sh + issue-1595.sh",
        "65a8b0ebc0b598186b72b75ada7eb6ad": "local out err rc (run_install head) issue-1581.sh + issue-1595.sh",
        "3949502b727a6a56c3afe28ec640dd97": "out/err + rc=0 + run (run_install) issue-1581.sh + issue-1595.sh",
        "e57c40aeb409eccd24633db24e1b5e72": "rc=0 + run + unset -v (run_install) issue-1581.sh + issue-1595.sh",
        "9204573809a71ff00e68d0cd3e25b237": "run + unset -v envs (run_install end) issue-1581.sh + issue-1595.sh",

        # --- 1557 <-> 1582 (authorized_keys / reverse-tunnel acceptance tests)#######
        # issue-1582.sh (#1582) and issue-1557.sh (#1557) are per-issue edge acceptance
        # tests for the same lib/edge-control/authorized_keys.sh.  They are kept
        # deliberately isolated (own throwaway root, own accounts.json +
        # registry.json fixtures, own FP_A/FP_B/FP_C, run_rebuild driver) per the
        # per-test-isolation convention used by 1555 <-> 1559 / 1556 <-> 1578 /
        # 1571 <-> 1579 / 1560 <-> 1581.  Shared 5-line windows are intentional
        # isolation, not copy-paste.  The 64 hashes below are the sliding 5-line pieces
        # of that shared fixture.  Hashes computed against CURRENT content of both
        # tests; refresh if their shared boilerplate changes.
        "01566e147059eb108990528a31ef2e1f": "'pubkey': '$ACME_PUBKEY' issue-1557.sh + issue-1582.sh",
        "04fe950e989bb7a413427b5b13eed261": "'fingerprint': '$FP_B', issue-1557.sh + issue-1582.sh",
        "0576571d22edf3a6455488d0c6edd786": "'$FP_B': { issue-1557.sh + issue-1582.sh",
        "06d5c72260bdc909a0fa01ae18980804": "'acme':    { 'port': 20000, 'fqdn': 'acme.dis… issue-1557.sh + issue-1582.sh",
        "0a0f9d95c19b64dc099d8be9d327a359": "'$FP_C': { issue-1557.sh + issue-1582.sh",
        "14a83ccf98c665c4668e478648038c4d": "if grep -qF 'permitlisten='127.0.0.1:20002'' … issue-1557.sh + issue-1582.sh",
        "1a8435ea110dfb78f9564ca9b512418a": "'status': 'approved', 'credits': 0, 'name': '… issue-1557.sh + issue-1582.sh",
        "1c26e1502a24b910e35456bb3dd045ea": "EOF issue-1557.sh + issue-1582.sh",
        "1ceda1abc5f97358b3e43635a4f0fe53": "'created_at': '2026-01-01T00:00:00Z' issue-1557.sh + issue-1582.sh",
        "227f8e9a6fda16debf082b7768dff54d": "ACCOUNTS_FILE='$ROOT/var/lib/disinto/accounts… issue-1557.sh + issue-1582.sh",
        "2ad3e0ae9d19025ac826dbd42b3c45d2": "}, issue-1557.sh + issue-1582.sh",
        "335a50f409bf595d0f398950fe0144cb": "if grep -qF '$FP_C' '$TUNNEL_AUTH_KEYS' 2>/de… issue-1557.sh + issue-1582.sh",
        "35196a7c0710a93e1bb3ac454c09ab05": "rm -rf '$TMP_DIR' 2>/dev/null || true issue-1557.sh + issue-1582.sh",
        "4172a6b5fbeb97a87c31566d3718d10e": "source '$AUTH_KEYS_LIB' issue-1557.sh + issue-1582.sh",
        "424091a3d496015a7b3069d277be3c38": "{ issue-1557.sh + issue-1582.sh",
        "4326b41bdc2404e435d88ee2cf23d61b": "local err_file issue-1557.sh + issue-1582.sh",
        "46f911e4df15ed274202a1b6f0fa8b50": "ROOT='$TMP_DIR/root' issue-1557.sh + issue-1582.sh",
        "479842b6c60503b40043273ee7a57c1d": "if [ '$rc' -ne 0 ]; then issue-1557.sh + issue-1582.sh",
        "4f86f6d0208114f0320305a5412c6409": "'$FP_A': { issue-1557.sh + issue-1582.sh",
        "504c836015afdf74126667068ab8b2a2": "if grep -qF 'permitlisten='127.0.0.1:20002'' … issue-1557.sh + issue-1582.sh",
        "57f7e15d80b6714367fc8098bbb8e86e": "cat > '$REGISTRY_FILE' <<EOF issue-1557.sh + issue-1582.sh",
        "5db2a798f80f59e26d7b4545ce2865c9": "export REGISTRY_DIR='$REGISTRY_DIR' issue-1557.sh + issue-1582.sh",
        "5db4059e3aca650d4f7810fb5548d1d6": "EOF issue-1557.sh + issue-1582.sh",
        "5e142973905e0bb39513b697cd4d676f": "EOF issue-1557.sh + issue-1582.sh",
        "613a5206b5b4921b4b9dc635c9197a04": "'accounts': { issue-1557.sh + issue-1582.sh",
        "6193004ea631f8f31f0d82a0e1278a1f": "REGISTRY_DIR='$ROOT/var/lib/disinto' issue-1557.sh + issue-1582.sh",
        "668b03a1dc7eea83a8b62a4c26fc1cbb": "ac_fail 'AC2: the ledger fingerprint was writ… issue-1557.sh + issue-1582.sh",
        "6996d6f8e7880c68c5cb01f532757279": "'fakekey': { 'port': 20002, 'fqdn': 'fakekey.… issue-1557.sh + issue-1582.sh",
        "6e398e39d86261227c422fc8dcc3859c": "'norkey':  { 'port': 20001, 'fqdn': 'norkey.d… issue-1557.sh + issue-1582.sh",
        "6f84de71d5577e8d9f022d231b7b64bf": "{ issue-1557.sh + issue-1582.sh",
        "720af677bf2c956d1a9319932bf15d50": "mkdir -p '$ROOT/var/lib/disinto' '$ROOT/home' issue-1557.sh + issue-1582.sh",
        "72c93d5a98e56eec479ac16ac0cd5b7b": "} 2>'$err_file' || rc=$? issue-1557.sh + issue-1582.sh",
        "75624205a113a8d918cbbdab90bd3a24": "run_rebuild issue-1557.sh + issue-1582.sh",
        "7bc333856f417d5a54e27d9d0cb92c5d": "EOF issue-1557.sh + issue-1582.sh",
        "7cc91f8195978a45282d3d0997642e3f": "ac_fail 'AC2: norkey (ledger row has no pubke… issue-1557.sh + issue-1582.sh",
        "83b2462f3dfa8b6e73153e44a7c15158": "'version': 1, issue-1557.sh + issue-1582.sh",
        "889beb3dba9b36ecb5256102524dee2c": "if grep -qF 'ssh-ed25519 XREGISTRY' '$TUNNEL_… issue-1557.sh + issue-1582.sh",
        "936b193da47e4933fb57085384184730": "EOF issue-1557.sh + issue-1582.sh",
        "943ebf361c0c4a79825948b63551096c": "rebuild_authorized_keys issue-1557.sh + issue-1582.sh",
        "94e81bc1f817739b538f5247195c947e": "'projects': { issue-1557.sh + issue-1582.sh",
        "9534b969c25b1c64f6e74c3fad59f556": "if grep -qF '$FP_C' '$TUNNEL_AUTH_KEYS' 2>/de… issue-1557.sh + issue-1582.sh",
        "96d775058c3877d5927273041eaef9ba": "'status': 'approved', 'credits': 0, 'name': '… issue-1557.sh + issue-1582.sh",
        "98566bea61deffd7717202f761134292": "ac_fail 'AC2: the registry's copied acme pubk… issue-1557.sh + issue-1582.sh",
        "98ef0e8e898ae872e85225034c10ee94": "ac_fail 'AC2: fakekey (ledger pubkey is a fin… issue-1557.sh + issue-1582.sh",
        "9b8a8df925639daf3049efd0a7064588": "}, issue-1557.sh + issue-1582.sh",
        "9e60d98b0c1b05b4f01e0a3609ed99c5": "REGISTRY_FILE='$ROOT/var/lib/disinto/registry… issue-1557.sh + issue-1582.sh",
        "a4d1cb18bf23ab0f44dcff00137bb314": "'version': 1, issue-1557.sh + issue-1582.sh",
        "a99d040c3196e819ab1786e62930bf6c": "trap cleanup EXIT issue-1557.sh + issue-1582.sh",
        "a9ad3dc0c97e8251b2f2ad29ddd3926c": "cleanup() { issue-1557.sh + issue-1582.sh",
        "af3dc9ec28ecaa10c8823b9b8f0bf1cf": "{ issue-1557.sh + issue-1582.sh",
        "ba1a08ef1d6279a1aff9d5f04155d9bc": "EOF issue-1557.sh + issue-1582.sh",
        "c22b446c401ea72b5f4d757c8681f3f5": "export ACCOUNTS_FILE='$ACCOUNTS_FILE' issue-1557.sh + issue-1582.sh",
        "c8fe0568e7b4f5779eef66cdcbfa67c0": "trap cleanup EXIT issue-1557.sh + issue-1582.sh",
        "cd53bc1f9c6e22817ff2188771b40267": "err='$(cat '$err_file' 2>/dev/null || true)' issue-1557.sh + issue-1582.sh",
        "d26383f35947a2bc116519d00827b83a": "err_file='$TMP_DIR/rebuild.err' issue-1557.sh + issue-1582.sh",
        "d4c841305a58167f38c4ed6f49ec91a0": "if grep -qF 'permitlisten='127.0.0.1:20001'' … issue-1557.sh + issue-1582.sh",
        "d649f5aefc780e22fc665af493ba3f58": "run_rebuild issue-1557.sh + issue-1582.sh",
        "d829ca79e060ea461809b2840d7f3c95": "if grep -qF 'ssh-ed25519 XREGISTRY' '$TUNNEL_… issue-1557.sh + issue-1582.sh",
        "dc1fd9cadecc7eebfac547abe1190b18": "ac_fail 'precondition: rebuild_authorized_key… issue-1557.sh + issue-1582.sh",
        "e81d5cc08c85e1b10fbd99b7ab2874a2": "export PORTER_ROOT='$ROOT' issue-1557.sh + issue-1582.sh",
        "ef35be39a4d1aaa0a7f7773b69682077": "rc=0 issue-1557.sh + issue-1582.sh",
        "f12c4380c44f0d5a548f48424c156afe": "cat > '$ACCOUNTS_FILE' <<EOF issue-1557.sh + issue-1582.sh",
        "f8651b698c1b0996f9ab07a62a64cb9d": "'fingerprint': '$FP_A', issue-1557.sh + issue-1582.sh",
        "fe697bec9f20c7fa602459c50afc4e33": "run_rebuild() { issue-1557.sh + issue-1582.sh",
        # --- #1608: dev-agent.sh outcome emission mirrors dev-poll.sh (#1609) ---
        # Two independent dev-loop outcome paths (dev-agent.sh close_dev_tape_outcome()
        # and dev-poll.sh emit_tape_outcome()) that must agree on the 5-arg vs 6-arg
        # tape_outcome() (signature) call. lib/tape.sh is out of scope for this change,
        # so the near-identical 5-line window is intentional, not copy-paste.
        "1c236de2e43e7e1027286e3d8143d465": "dev-agent.sh + dev-poll.sh: if sig nonempty / rc=0 / tape_outcome 6-arg (#1608)",
        "e634274f40a5b13d940ee3a86075d759": "dev-agent.sh + dev-poll.sh: rc=0 / tape_outcome 6-arg / else (#1608)",
        "c855704a5ea61721d882f7c80969f8e4": "dev-agent.sh + dev-poll.sh: tape_outcome 6-arg / else / rc=0 (#1608)",
        "32a11885ac27207c592325238e179df7": "dev-agent.sh + dev-poll.sh: else / rc=0 / tape_outcome 5-arg (#1608)",
        # --- #1608: tests/acceptance/issue-1608.sh boilerplate vs issue-1609.sh/issue-1613.sh ---
        # Per-test-isolation stubs (mktemp + RUBRICS_DIR, issue_post_refusal, the
        # forge_api method dispatch, last_json) are deliberately identical across
        # isolated per-issue tests, per the per-test-isolation convention.
        "c60a24735b112d892ca9b249b9e25248": "issue-1608.sh + issue-1609.sh: TMP_DIR/RUBRICS_DIR/mkdir stub (#1608)",
        "61cd00710b6ea8fa769c7fc3c95a3bd2": "issue-1608.sh + issue-1613.sh: CALLS=()/REFUSALS=()/issue_post_refusal() { (#1608)",
        "51887f0eb72aa5ce7503cb1da0de15dc": "issue-1608.sh + issue-1613.sh: REFUSALS=()/issue_post_refusal()/REFUSALS+= (#1608)",
        "c92a273884ae9d67184d9b02236023f6": "issue-1608.sh + issue-1613.sh: issue_post_refusal()/REFUSALS+=/CALLS+= (#1608)",
        "e28b9189288fbe6731fe94455f73d148": "issue-1608.sh + issue-1613.sh: REFUSALS+=/CALLS+=/} (#1608)",
        "484466af43aae0e1452444cdd65a9413": "issue-1608.sh + issue-1613.sh: forge_api case / GET labels / printf (#1608)",
        "314d41bb04d3c04119f9778c8c487c51": "issue-1608.sh + issue-1613.sh: GET labels / printf / ;; (#1608)",
        "3f554baebe264aaea903a056f70dd263": "issue-1608.sh + issue-1613.sh: printf / ;; / POST issues labels (#1608)",
        "0ba18c98be739990f64ec0344da72a48": "issue-1608.sh + issue-1613.sh: ;; / POST issues labels / for i in extra (#1608)",
        "f94c89a1fcdef4f435afa623a37c332a": "issue-1608.sh + issue-1613.sh: POST issues labels / for i in extra / -d data test (#1608)",
        "7851ff7d85338dfcad011a95c4de8741": "issue-1608.sh + issue-1613.sh: for i in extra / -d data test / done (#1608)",
        "c87ebd7f083ce0f36709807e3c39327d": "issue-1608.sh + issue-1613.sh: -d data test / done / CALLS+= POST labels (#1608)",
        "a52d56bc2996665e79483cb8ef41c5f8": "issue-1608.sh + issue-1613.sh: done / CALLS+= POST labels / printf null (#1608)",
        "5db14b483f110bbaeb1237ccc5a74056": "issue-1608.sh + issue-1613.sh: CALLS+= POST labels / printf null / ;; (#1608)",
        "5c07afa83b3ff1626e6ce0faeaf3ccec": "issue-1608.sh + issue-1613.sh: printf null / ;; / DELETE labels (#1608)",
        "b9de288f574a065da350568be85cd5bb": "issue-1608.sh + issue-1613.sh: ;; / DELETE labels / local lid (#1608)",
        "6ad3982913b4e193c6c9cb4d705a83fc": "issue-1608.sh + issue-1613.sh: DELETE labels / local lid / CALLS+= DELETE (#1608)",
        "e46349231f2a1d5939a13ca1851ec069": "issue-1608.sh + issue-1613.sh: local lid / CALLS+= DELETE / printf null (#1608)",
        "629fa80f55e9b1509e007547707ac21f": "issue-1608.sh + issue-1613.sh: CALLS+= DELETE / printf null / ;; (#1608)",
        "b4fe665dea93f1171ea7f438b4ffda6d": "issue-1608.sh + issue-1609.sh: } / last_json() { (#1608)",
        "80a21053da9907fa691a61b638cec77e": "issue-1608.sh + issue-1609.sh: } / last_json() / tail tape.jsonl (#1608)",
    # --- issue-1475.sh <-> issue-1633.sh: shared proposal-driver boilerplate (#1633) ---
    # Per-test-isolation convention: each acceptance test is a self-contained,
    # standalone script.  issue-1475.sh and issue-1633.sh both drive
    # lib/formula-session.sh through an identical prop_driver() (ac_require_cmd
    # batch, mktemp TMP_DIR + trap, export/unset TAPE_PROPOSAL_ID, source
    # formula-session.sh, formula_session_start/end) and an identical awk-based
    # formula_session_start body extractor.  The shared 5-line windows are
    # intentional per-test isolation, not copy-paste.
    "5269fdde36af48c8d28be3daf3bf8ff0": "issue-1475.sh + issue-1633.sh: ac_require_cmd batch + TARGET + ac_assert_file (#1633)",
    "2ceaaa825c00f745a27254bc212521c3": "issue-1475.sh + issue-1633.sh: TMP_DIR/mktemp + trap EXIT + prop_driver() { (#1633)",
    "7b6b6b983a80c6ac196f2689c1677f45": "issue-1475.sh + issue-1633.sh: trap EXIT + prop_driver() { + local proposal (#1633)",
    "04c6ee18e5ec76bca066401063134ea1": "issue-1475.sh + issue-1633.sh: prop_driver() { + local proposal + local driver (#1633)",
    "0acaad08f26169d18c7d63aa600794bb": "issue-1475.sh + issue-1633.sh: local proposal + local driver + driver=mktemp (#1633)",
    "eba09785bf03ec6adee39d6e1f03ce7b": "issue-1475.sh + issue-1633.sh: local driver + driver=mktemp + if [ -n '$proposal' ]; then (#1633)",
    "08c0a0d7ddedfa73a52fcabe9de9080c": "issue-1475.sh + issue-1633.sh: driver=mktemp + if [ -n '$proposal' ] + prop_line=export (#1633)",
    "27f3e6bdcabd3cf00c8e52716f8871c3": "issue-1475.sh + issue-1633.sh: if [ -n '$proposal' ] + prop_line=export + else (#1633)",
    "1ea178413eb31b7fde8a228e77ede5a8": "issue-1475.sh + issue-1633.sh: prop_line=export + else + prop_line=unset (#1633)",
    "1436d3701b99f87a886ce96d1f99efdd": "issue-1475.sh + issue-1633.sh: else + prop_line=unset + fi (#1633)",
    "0b35372799b52dd60056a67b2d37fcf8": "issue-1475.sh + issue-1633.sh: prop_line=unset + fi + cat > '$driver' <<EOF (#1633)",
    "a2da36a7cee71efdf83df0a943c38966": "issue-1475.sh + issue-1633.sh: fi + cat > '$driver' <<EOF + set -euo pipefail (#1633)",
    "7aa62c232f7abab2eb9a69df21e735c4": "issue-1475.sh + issue-1633.sh: cat > '$driver' <<EOF + set -euo pipefail + log() { (#1633)",
    "e97bc1583e1c1c508a111697ab9999d5": "issue-1475.sh + issue-1633.sh: set -euo pipefail + log() + unset TAPE_PROPOSAL_ID (#1633)",
    "02630975b29ca655eb63189a249b853d": "issue-1475.sh + issue-1633.sh: log() + unset TAPE_PROPOSAL_ID + export AGENT_HARNESS (#1633)",
    "e0470b52026df581a038af724ed310ad": "issue-1475.sh + issue-1633.sh: unset TAPE_PROPOSAL_ID + export AGENT_HARNESS + source formula-session.sh (#1633)",
    "23b6e26272f16b4b110a594d82865f48": "issue-1475.sh + issue-1633.sh: export AGENT_HARNESS + source formula-session.sh + export TAPE_DIR (#1633)",
    "1bedb20837ef2dbb52665d9a6f1808cd": "issue-1475.sh + issue-1633.sh: source formula-session.sh + export TAPE_DIR + $prop_line (#1633)",
    "a60020d83ed5fbb72098ecc3a1ef0a67": "issue-1475.sh + issue-1633.sh: export TAPE_DIR + $prop_line + formula_session_start (#1633)",
    "12eb8ce912fabb35b40047e28c310507": "issue-1475.sh + issue-1633.sh: $prop_line + formula_session_start + formula_session_end $rc (#1633)",
    "68ef0281d4d380fba8d3e926899ea722": "issue-1475.sh + issue-1633.sh: formula_session_start + formula_session_end $rc + EOF (#1633)",
    "4bbcf9ef9f014affb688e25b4bcd0809": "issue-1475.sh + issue-1633.sh: fn_body=awk ' + $0=='formula_session_start() {' { infn=1;next } + infn&&/^}$/ {exit} (#1633)",
    "bdcd0c63dbf1a03c24bb8c67c6ea8a97": "issue-1475.sh + issue-1633.sh: $0=='formula_session_start() {' { infn=1;next } + infn&&/^}$/ {exit} + infn {print} (#1633)",
        # --- #1636: repair-tape acceptance tests share the in-process harness ---
        # issue-1408.sh, issue-1533.sh, and issue-1636.sh each extract the
        # supervisor repair-tape functions and run them in an isolated subshell
        # (ac_extract_fn + eval, temp factory root, source lib/tape.sh). The
        # shared 5-line windows are per-test isolation, not copy-paste.
        "cd99a638b034774b32590f226b50e7a1": "issue-1408.sh + issue-1533.sh + issue-1636.sh: source tape.sh + eval STATEFILE + eval UPD (#1636)",
        "826f6f1b4d2ac9f9c61929411b8e7899": "issue-1408.sh + issue-1533.sh: extract emit_repair_proposal + repair_state_put (#1636)",
        "05e9a558a1e90b7f65cb6c409845a447": "issue-1408.sh + issue-1533.sh: extract emit_repair_proposal fail + repair_state_put (#1636)",
        "da0ae9d096def04c6aafce0c729f705a": "issue-1408.sh + issue-1636.sh: extract repair_state_put + _repair_state_update (#1636)",
        "dac7e0b70e72a00673073e1c4bfbd0ae": "issue-1408.sh + issue-1636.sh: extract repair_state_put fail + _repair_state_update (#1636)",
        "db0f1017b1095bd666a8370567b61ce6": "issue-1408.sh + issue-1636.sh: extract _repair_state_update + repair_tape_state_file (#1636)",
        "394a1af5e4f8bf6718c23ed8762222b2": "issue-1408.sh + issue-1636.sh: extract _repair_state_update fail + repair_tape_state_file (#1636)",
        "e80b7e7410795a0ea9c8e31aa768d404": "issue-1408.sh + issue-1636.sh: eval STATEFILE + UPD + STATE (#1636)",
        "7e90b59b2ca7cca84ee79751f3daea44": "issue-1408.sh + issue-1636.sh: eval UPD + STATE + PROP (#1636)",
        "00b6180908569f4f5082d6a0ff2fd28e": "issue-1533.sh + issue-1636.sh: TMP_DIR + trap + FACTORY_ROOT (#1636)",
        "95f14d51016ab844f2c888f1771f4780": "issue-1533.sh + issue-1636.sh: trap + FACTORY_ROOT + MARKER_DIR (#1636)",
        "3f58490aba80ed2a5f389bca422e77e7": "issue-1533.sh + issue-1636.sh: run subshell locals + set -euo pipefail (#1636)",
        "16ee31507d301d0d844061c711172bc9": "issue-1533.sh + issue-1636.sh: export FACTORY_ROOT + PROJECT_TOML + source tape.sh (#1636)",
        "b5a1b758cd6af653b59b03e0f09180df": "issue-1533.sh + issue-1636.sh: export PROJECT_TOML + source tape.sh + eval STATEFILE (#1636)",
        # --- #1649: stuck-calibration acceptance tests share the #1648 fixture ---
        # issue-1649.sh (#1649) and issue-1648.sh (#1648) are sibling per-issue
        # acceptance tests for the same tape-stuck / calibration tooling. Each builds
        # its own throwaway fixture (TMP_DIR + trap, PACKS dir, the stuck.toml and
        # stuck-bad.toml packs) per the per-test-isolation convention; the shared
        # 5-line windows are intentional isolation, not copy-paste. Hashes computed
        # against CURRENT content of both tests; refresh if their shared boilerplate
        # changes.
        "0437e9cbb0787367214d1eee24f6da9d": "issue-1649.sh + issue-1648.sh: tape-stuck assert + TMP_DIR/mktemp + trap EXIT (#1649)",
        "f27468e991763727f9293f98cd7d9c6d": "issue-1649.sh + issue-1648.sh: TMP_DIR/mktemp + trap EXIT + PACKS (#1649)",
        "93e6f9f97b237e0dcc50cf9023cabcaf": "issue-1649.sh + issue-1648.sh: loops dev=merged + EOF + stuck.toml heredoc open (#1649)",
        "7975b55bf8d172adbd4341f7300cb4e4": "issue-1649.sh + issue-1648.sh: EOF + stuck.toml heredoc open + dev=48 (#1649)",
        "507128932ac5a55af890c89095029d7c": "issue-1649.sh + issue-1648.sh: stuck.toml heredoc open + dev=48 + EOF (#1649)",
        "a1407105fe824e184b28d9ead5feb8e8": "issue-1649.sh + issue-1648.sh: stuck.toml dev=48 + EOF + stuck-bad heredoc open (#1649)",
        # --- #1713: repair-tape (eval-gate) acceptance test shares the in-process harness ---
        # issue-1713.sh (#1713) and issue-1637.sh (#1637) both extract the same set of
        # supervisor repair-tape functions and run them in an isolated subshell (ac_extract_fn
        # + eval, temp factory root, source lib/tape.sh, stub_remedy, judge/outcome_rec, and a
        # jq outcome assertion). Each is kept deliberately isolated (own throwaway root, own
        # stub) per the per-test-isolation convention; the shared 5-line windows are intentional
        # isolation, not copy-paste. Hashes computed against CURRENT content of both tests;
        # refresh if their shared boilerplate changes.
        "7403f50e59a8caa631a8a2919f868f2c": "issue-1713.sh + issue-1637.sh: REPAIR_FNS init + for _fn extract list (#1713)",
        "11f1bbc64340071173d679593e3bf039": "issue-1713.sh + issue-1637.sh: REPAIR_FNS append + done + WORK mktemp (#1713)",
        "698a5baced3dd0f17fd29acb0fe80d9f": "issue-1713.sh + issue-1637.sh: WORK mktemp + trap EXIT (#1713)",
        "82a46b4c10454fef748b7d2fcd3af691": "issue-1713.sh + issue-1637.sh: WORK mktemp + trap EXIT + ROOT factory (#1713)",
        "0f86987a453aac16710855aa01b8bd5c": "issue-1713.sh + issue-1637.sh: stub_remedy open + local code + printf cleanup-worktrees (#1713)",
        "fee5e4ece370219190785d07f555ffa9": "issue-1713.sh + issue-1637.sh: stub_remedy local code + printf + redirect cleanup-worktrees (#1713)",
        "442ec4fc62a40bcc6120d09bac3a7971": "issue-1713.sh + issue-1637.sh: stub_remedy printf + redirect + close (#1713)",
        "3247898e54a6b1ed3a3eb22ec92ff02b": "issue-1713.sh + issue-1637.sh: judge close + outcome_rec open (#1713)",
        "01bfbab78fe27184c756183717f7d5ff": "issue-1713.sh + issue-1637.sh: outcome_rec open + local file (#1713)",
        "edf02b1cc8fcf1afc596cbacbe9d7bcd": "issue-1713.sh + issue-1637.sh: outcome_rec open + local file + [ -f ] return (#1713)",
        "b11d2ec2d1b152eb26b501189aad343c": "issue-1713.sh + issue-1637.sh: ac_assert_jq open + outcome type + proposal_id (#1713)",
        "08fd3373d76fd68bb8c21b1f94cf7b55": "issue-1713.sh + issue-1637.sh: jq outcome type + proposal_id + acted/cleared (#1713)",
        "7d7acc5bacebecfe7314259aa988c739": "issue-1713.sh + issue-1637.sh: jq proposal_id + acted/cleared + numbers (#1713)",
        "21ee62dd6475f0deef5d10822920d61b": "issue-1713.sh + issue-1637.sh: jq acted/cleared + numbers + children (#1713)",
        "db6546c36e21a9df0bdf331615ae375d": "issue-1713.sh + issue-1637.sh: jq numbers + children + payloads (#1713)",
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
