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
        # snapshot-agents.sh shares temp-file tracking pattern with snapshot-forge.sh
        "a7e19281d631d7bd1252029b661d6b31": "Snapshot temp-file tracking start (snapshot-agents + snapshot-forge)",
        "7ccce86c6bbc77eb1b4cd13c29b3be81": "Snapshot temp-file tracking (snapshot-agents + snapshot-forge)",
        "152a7f9ea51a0f80703f58ea2a0a5af1": "Snapshot mktemp_safe (snapshot-agents + snapshot-forge)",
        "14dc98e549b3263b08a0c63b49846c3b": "Snapshot mktemp_safe body (snapshot-agents + snapshot-forge)",
        "e0f85b3b2a8abf79e98cd998aeaadfc7": "Snapshot mktemp_safe + TMPFILES (snapshot-agents + snapshot-forge)",
        "f4ee900d52b701eb7050355c05ba4ecd": "Snapshot TMPFILES + printf (snapshot-agents + snapshot-forge)",
        "5f62ad0ed0fb0c919db212d1667e1a29": "Snapshot closing brace + cleanup (snapshot-agents + snapshot-forge)",
        "1f783c0f648d56972c99488c313e45a6": "Snapshot cleanup function (snapshot-agents + snapshot-forge)",
        # snapshot-inbox.sh shares standard env-var header with other snapshot collectors
        "816df0fd43ba5676531c08e63ea1c4f8": "Snapshot env-var header (set -euo + FACTORY_FORGE_PAT + FORGE_URL + FORGE_REPO + SNAPSHOT_PATH) (snapshot-forge + snapshot-inbox)",
        # Snapshot mktemp_safe / TMPFILES / cleanup pattern after #849 fix:
        # mktemp_safe must assign through a global (_TMPFILE) instead of printing
        # to stdout — command substitution forks a subshell, so TMPFILES+=()
        # inside $(…) is lost. The fix made all 5 snapshot collectors
        # (snapshot-agents, snapshot-daemon, snapshot-forge, snapshot-inbox,
        # snapshot-nomad) share the identical helper body verbatim. Intentional
        # duplication: each collector runs as its own process and needs its own
        # trap-bound TMPFILES array.
        "22334695968d905d02e8e4d1dbac3cc1": "Snapshot mktemp_safe block start (TMPFILES=() + mktemp_safe + _TMPFILE) (all 5 snapshot collectors, #849)",
        "27a6b7f735e325d349acced8fc46234b": "Snapshot mktemp_safe body (mktemp_safe + _TMPFILE + TMPFILES+=) (all 5 snapshot collectors, #849)",
        "254ebe187922c94793cc00589ab7ac6a": "Snapshot mktemp_safe end (_TMPFILE + TMPFILES+= + closing brace) (all 5 snapshot collectors, #849)",
        "d536875ce1465069a5495b67167d8658": "Snapshot mktemp_safe → cleanup (TMPFILES+= + closing brace + cleanup) (all 5 snapshot collectors, #849)",
        "c006fde2bfb8b04ad39a0b48eca2edb2": "Snapshot pre-mktemp_safe boundary (closing brace + TMPFILES=() + mktemp_safe) (snapshot-agents + snapshot-forge + snapshot-inbox + snapshot-nomad, #849)",
        # Standard --help heredoc closing + flag-parser tail (cluster-up.sh + sync-nomad-client-config.sh, #789)
        "2882d287343e26a4d8d6499e4bd38c26": "Help heredoc EOF + exit 0 + unknown-flag die + esac (cluster-up + sync-nomad-client-config)",
        "8f6432aafe427171507274ef71c1b612": "Help exit 0 + unknown-flag die + esac + done (cluster-up + sync-nomad-client-config)",
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
