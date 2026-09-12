#!/usr/bin/env bash
# =============================================================================
# tools/cut-release.sh — cut a disinto release in one verifiable command (#1228)
#
# A release is: bump VERSION → commit → tag → push → wait for the tag-triggered
# Woodpecker pipeline (.woodpecker/publish-images.yml) to publish all four GHCR
# images → verify the packages are anonymously pullable → print the next steps
# (release smoke + runbook).
#
# Usage:
#   tools/cut-release.sh <version> [--dry-run] [--yes] [--main] [--skip-wait]
#
#   <version>      target version (0.5.0 or v0.5.0), must be newer than VERSION
#   --dry-run      print the full plan + pre-flight report; mutate nothing
#   --yes          execute stages 3-6 (tag, push, wait, visibility)
#   --main         bump on main instead of a short-lived release/v<version>
#   --skip-wait    skip the GHCR manifest wait (stage 4); visibility still runs
#
# Semantics (same convention as `disinto init --dry-run`):
#   - stage 1 (pre-flight) is always read-only and fail-fast
#   - stage 2 (bump + commit) runs without --yes
#   - stages 3-6 are gated behind --yes; without it the run stops and prints
#     the remaining plan
#   - the two-step flow resumes: stage 2 leaves you on release/v<version>
#     (or on main with --main), and re-running the same command with --yes
#     picks up where it left off — stage 1 accepts the release branch (with
#     an already-bumped VERSION as the expected state), stage 2 is a no-op
#     pass, and stages 3-6 proceed
#   - stage markers [N/6] PASS|FAIL|SKIP, same style as tests/release-smoke.sh
#
# Env overrides (used by tests):
#   GHCR_REGISTRY      (https://ghcr.io)
#   GHCR_OWNER         (disinto)
#   CUT_RELEASE_IMAGES (agents reproduce edge research)
#   WAIT_TIMEOUT_SECS  (1200)
#   POLL_INTERVAL_SECS (30)
#   PRIMARY_BRANCH     (main)
#   CUT_RELEASE_REMOTE (origin)
#   WOODPECKER_SERVER  (Woodpecker base URL, for the pipeline hint)
#   VERSION_FILE       (VERSION)
#
# Requires: git, curl, jq
# =============================================================================
set -euo pipefail

GHCR_REGISTRY="${GHCR_REGISTRY:-https://ghcr.io}"
GHCR_OWNER="${GHCR_OWNER:-disinto}"
CUT_RELEASE_IMAGES="${CUT_RELEASE_IMAGES:-agents reproduce edge research}"
WAIT_TIMEOUT_SECS="${WAIT_TIMEOUT_SECS:-1200}"
POLL_INTERVAL_SECS="${POLL_INTERVAL_SECS:-30}"
PRIMARY_BRANCH="${PRIMARY_BRANCH:-main}"
CUT_RELEASE_REMOTE="${CUT_RELEASE_REMOTE:-origin}"
VERSION_FILE="${VERSION_FILE:-VERSION}"
WOODPECKER_SERVER="${WOODPECKER_SERVER:-}"

CR_STAGES_TOTAL=6
CR_STAGE=0
CR_ISSUES=""
CR_WARNS=""
CR_CURRENT_VERSION=""

cr_pass() { printf '[%d/%d] PASS: %s\n' "$CR_STAGE" "$CR_STAGES_TOTAL" "$*"; }
cr_fail() { printf '[%d/%d] FAIL: %s\n' "$CR_STAGE" "$CR_STAGES_TOTAL" "$*" >&2; exit 1; }
cr_skip() { printf '[%d/%d] SKIP: %s\n' "$CR_STAGE" "$CR_STAGES_TOTAL" "$*" >&2; }

usage() {
  cat <<EOF
cut-release.sh — cut a disinto release in one verifiable command (#1228)

Usage:
  cut-release.sh <version> [--dry-run] [--yes] [--main] [--skip-wait]

Arguments:
  <version>            Target version: 0.5.0 or v0.5.0 (must be newer than VERSION)

Options:
  --dry-run            Print the full plan and pre-flight report; mutate nothing
  --yes                Execute stages 3-6: tag, push, wait for CI images,
                       check GHCR visibility. Without it, the bump commit is
                       made locally (on release/v<version>, or on main with
                       --main) and the run stops before tagging. Re-running
                       the same command with --yes resumes: stage 1 accepts
                       the release branch and stage 2 becomes a no-op.
  --main               Commit the VERSION bump on ${PRIMARY_BRANCH} instead of
                       a short-lived release/v<version> branch
  --skip-wait          Skip the GHCR manifest wait (stage 4). Visibility
                       still runs.

Stages ([N/6] PASS|FAIL|SKIP markers, like tests/release-smoke.sh):
  1. pre-flight   clean tree, on ${PRIMARY_BRANCH} (or on release/v<version>
                  when resuming a previous stage-2 run), VERSION < target, tag free
  2. bump         VERSION=<version>, commit 'release: v<version>'
                  (no-op when resuming — the bump is already committed)
  3. tag + push   git tag v<version>; git push ${CUT_RELEASE_REMOTE} v<version> <branch>
  4. wait CI      poll ${GHCR_REGISTRY%/}/v2/${GHCR_OWNER}/<img>/manifests/v<version>
                  for ${CUT_RELEASE_IMAGES} (timeout ${WAIT_TIMEOUT_SECS}s, backoff ${POLL_INTERVAL_SECS}s)
  5. visibility   anonymous pull must work for all packages (public on GHCR)
  6. next steps   tests/release-smoke.sh + docs/release-verification.md

Env overrides: GHCR_REGISTRY, GHCR_OWNER, CUT_RELEASE_IMAGES, WAIT_TIMEOUT_SECS,
  POLL_INTERVAL_SECS, PRIMARY_BRANCH, CUT_RELEASE_REMOTE, WOODPECKER_SERVER,
  VERSION_FILE
EOF
}

# cr_vercmp A B → prints -1 / 0 / 1 (A < B / == / >). Numeric core components
# are compared numerically; a release (no -suffix) sorts after its prerelease,
# and two prereleases are ordered by their -suffix per SemVer: dotted fields
# left to right, numeric fields compared numerically, numeric < alphanumeric,
# and a shorter (prefix) suffix sorts lower.
cr_vercmp() {
  awk -v a="$1" -v b="$2" '
    function suffix(v,   p) {
      p = index(v, "-")
      return (p > 0) ? substr(v, p + 1) : ""
    }
    BEGIN {
      n = split(a, A, /[.+-]/)
      m = split(b, B, /[.+-]/)
      for (i = 1; i <= 3; i++) {
        x = (i <= n && A[i] ~ /^[0-9]+$/) ? A[i] + 0 : 0
        y = (i <= m && B[i] ~ /^[0-9]+$/) ? B[i] + 0 : 0
        if (x < y) { print -1; exit }
        if (x > y) { print 1; exit }
      }
      # The prerelease is the optional -suffix (validation only allows that
      # form); the release core X.Y.Z never contains "-", so the first "-"
      # marks it. A bare release sorts after any prerelease of the same core.
      sa = suffix(a)
      sb = suffix(b)
      if (sa == sb) { print 0; exit }
      if (sa == "") { print 1; exit }
      if (sb == "") { print -1; exit }
      na = split(sa, FA, ".")
      nb = split(sb, FB, ".")
      lim = (na < nb) ? na : nb
      for (i = 1; i <= lim; i++) {
        an = (FA[i] ~ /^[0-9]+$/)
        bn = (FB[i] ~ /^[0-9]+$/)
        if (an && bn) {
          if (FA[i] + 0 < FB[i] + 0) { print -1; exit }
          if (FA[i] + 0 > FB[i] + 0) { print 1; exit }
        } else if (an != bn) {
          print (an ? -1 : 1)
          exit
        } else if (FA[i] < FB[i]) { print -1; exit }
        else if (FA[i] > FB[i]) { print 1; exit }
      }
      if (na != nb) { print (na < nb ? -1 : 1); exit }
      print 0
    }'
}

# cr_preflight_collect <version> <on_main> — sets CR_ISSUES / CR_WARNS
# (newline-separated), CR_CURRENT_VERSION, CR_CURRENT_BRANCH. Read-only.
#
# A run may resume where a previous stage-2 run left off: on
# release/v<version> (default flow) or, with --main, on ${PRIMARY_BRANCH}
# itself. In that state an already-bumped VERSION is the expected pre-state,
# not an issue.
cr_preflight_collect() {
  local version="$1" on_main="$2"
  CR_ISSUES=""
  CR_WARNS=""
  CR_CURRENT_VERSION=""
  CR_CURRENT_BRANCH=""
  local dirty cur curv rref ahead behind cmp line unpushed_msgs

  if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
    CR_ISSUES+="version '$version' is not semver (expected e.g. 0.5.0 or 0.5.0-rc.1)"$'\n'
  fi

  dirty="$(git status --porcelain)"
  if [ -n "$dirty" ]; then
    CR_ISSUES+="working tree is dirty (commit or stash before cutting a release):"$'\n'
    while IFS= read -r line; do
      CR_ISSUES+="  $line"$'\n'
    done <<<"$dirty"
  fi

  cur="$(git symbolic-ref --quiet --short HEAD || echo "")"
  CR_CURRENT_BRANCH="$cur"
  local resume_branch=""
  if [ "$on_main" != "1" ]; then
    resume_branch="release/v${version}"
  fi
  if [ "$cur" != "$PRIMARY_BRANCH" ] && [ "$cur" != "$resume_branch" ]; then
    if [ -n "$resume_branch" ]; then
      CR_ISSUES+="not on '$PRIMARY_BRANCH' or '$resume_branch' (current branch: ${cur:-detached HEAD})"$'\n'
    else
      CR_ISSUES+="not on '$PRIMARY_BRANCH' (current branch: ${cur:-detached HEAD})"$'\n'
    fi
  fi

  local resuming=0
  if [ "$on_main" = "1" ] && [ "$cur" = "$PRIMARY_BRANCH" ]; then
    resuming=1
  elif [ "$on_main" != "1" ] && [ "$cur" = "release/v${version}" ]; then
    resuming=1
  fi

  if [ -f "$VERSION_FILE" ]; then
    curv="$(tr -d '[:space:]' <"$VERSION_FILE")"
    CR_CURRENT_VERSION="$curv"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && [ -n "$curv" ]; then
      cmp="$(cr_vercmp "$curv" "$version")"
      if [ "$cmp" = "1" ]; then
        CR_ISSUES+="$VERSION_FILE ($curv) is newer than target $version — refusing to release an older version"$'\n'
      elif [ "$cmp" = "0" ] && [ "$resuming" -ne 1 ]; then
        CR_ISSUES+="$VERSION_FILE is already $version — nothing to release"$'\n'
      fi
    fi
  else
    CR_ISSUES+="$VERSION_FILE not found at repo root"$'\n'
  fi

  if git rev-parse -q --verify "refs/tags/v${version}" >/dev/null 2>&1; then
    CR_ISSUES+="tag v${version} already exists locally"$'\n'
  fi

  if [ "$cur" = "$PRIMARY_BRANCH" ]; then
    rref="refs/remotes/${CUT_RELEASE_REMOTE}/${PRIMARY_BRANCH}"
    if git rev-parse -q --verify "$rref" >/dev/null 2>&1; then
      ahead="$(git rev-list --count "${rref}..HEAD")"
      if [ "$ahead" -gt 0 ]; then
        # A --main resume carries exactly one unpushed commit — the bump
        # itself, which stage 3 pushes with the tag.
        unpushed_msgs="$(git log --format=%s "${rref}..HEAD")"
        if [ "$ahead" -eq 1 ] && [ "$unpushed_msgs" = "release: v${version}" ]; then
          :
        else
          CR_ISSUES+="$PRIMARY_BRANCH has $ahead unpushed commit(s) — they would be included in the tag; push or drop them first"$'\n'
        fi
      fi
      behind="$(git rev-list --count "HEAD..${rref}")"
      if [ "$behind" -gt 0 ]; then
        CR_WARNS+="$PRIMARY_BRANCH is $behind commit(s) behind ${CUT_RELEASE_REMOTE}/${PRIMARY_BRANCH} — consider git pull first"$'\n'
      fi
    fi
  fi
}

# cr_resume_state <version> <on_main> → true when stage 2 would be a no-op:
# VERSION already at <version> from an earlier run, on the branch that run
# left (release/v<version>, or ${PRIMARY_BRANCH} with --main).
cr_resume_state() {
  local version="$1" on_main="$2"
  if [ "$on_main" = "1" ]; then
    [ "$CR_CURRENT_BRANCH" = "$PRIMARY_BRANCH" ] && [ "$CR_CURRENT_VERSION" = "$version" ]
  else
    [ "$CR_CURRENT_BRANCH" = "release/v${version}" ] && [ "$CR_CURRENT_VERSION" = "$version" ]
  fi
}

# cr_preflight_pass <version> — the stage-1 PASS line, resume-aware.
cr_preflight_pass() {
  local version="$1"
  local resume_on=""
  if [ "$CR_CURRENT_BRANCH" = "release/v${version}" ]; then
    resume_on="release/v${version}"
  elif [ "$CR_CURRENT_BRANCH" = "$PRIMARY_BRANCH" ] && [ "$CR_CURRENT_VERSION" = "$version" ]; then
    resume_on="$PRIMARY_BRANCH"
  fi
  if [ -n "$resume_on" ]; then
    cr_pass "pre-flight (resuming on ${resume_on}, clean tree, VERSION already ${version}, no tag v${version})"
  else
    cr_pass "pre-flight (on ${PRIMARY_BRANCH}, clean tree, VERSION ${CR_CURRENT_VERSION:-?} < ${version}, no tag v${version})"
  fi
}

# cr_print_plan <version> <on_main> [resume] — the full release plan
# (stages 2-6). With resume=1, stage 2 is shown as a no-op (the bump is
# already committed from a previous run).
cr_print_plan() {
  local version="$1" on_main="$2" resume="${3:-0}"
  local branch="$PRIMARY_BRANCH"
  if [ "$on_main" != "1" ]; then
    branch="release/v${version}"
  fi
  local header="Release plan: v${CR_CURRENT_VERSION:-?} -> v${version}"
  local bump_line="write VERSION=${version}, commit 'release: v${version}' on branch ${branch}"
  if [ "$resume" = "1" ]; then
    header="Release plan: v${version} (VERSION already at target on ${branch} — resuming)"
    bump_line="no-op — bump already committed on ${branch}"
  fi
  cat <<EOF
${header}
  Stage 2  bump         ${bump_line}
  Stage 3  tag + push   git tag -a v${version}; git push ${CUT_RELEASE_REMOTE} v${version} ${branch}
  Stage 4  wait CI      poll ${GHCR_REGISTRY%/}/v2/${GHCR_OWNER}/<img>/manifests/v${version} for: ${CUT_RELEASE_IMAGES}
                        (timeout ${WAIT_TIMEOUT_SECS}s, backoff ${POLL_INTERVAL_SECS}s; triggers .woodpecker/publish-images.yml)
  Stage 5  visibility   anonymous pull (GHCR token exchange, no auth) must succeed for every image — packages must be public
  Stage 6  next steps   VERSION=v${version} bash tests/release-smoke.sh; runbook: docs/release-verification.md
EOF
}

# cr_bump <version> <on_main> — makes the VERSION bump commit and records it
# in CR_BUMP_BRANCH (the branch it landed on). Sets CR_RESUME=1 when no new
# commit was needed — VERSION already at <version> from an earlier stage-2
# run — so stage 2 is a no-op pass. (Not run in a subshell: the globals
# must survive into main.)
cr_bump() {
  local version="$1" on_main="$2"
  local branch="$PRIMARY_BRANCH" cur curv
  CR_RESUME=0
  CR_BUMP_BRANCH="$branch"
  if [ "$on_main" != "1" ]; then
    branch="release/v${version}"
    cur="$(git symbolic-ref --quiet --short HEAD || echo "")"
    if [ "$cur" != "$branch" ]; then
      if git show-ref --verify --quiet "refs/heads/${branch}"; then
        # A previous stage-2 run left the branch (and usually the bump
        # commit) — resume on it instead of failing on `checkout -b`.
        git checkout -q "$branch"
      else
        git checkout -q -b "$branch"
      fi
    fi
  fi
  curv="$(tr -d '[:space:]' <"$VERSION_FILE")"
  if [ "$curv" = "$version" ]; then
    CR_RESUME=1
    CR_BUMP_BRANCH="$branch"
    return 0
  fi
  printf '%s\n' "$version" >"$VERSION_FILE"
  git add "$VERSION_FILE"
  git commit -q -m "release: v${version}"
  CR_BUMP_BRANCH="$branch"
}

cr_tag_push() {
  local version="$1" branch="$2"
  git tag -a "v${version}" -m "Release v${version}"
  git push "$CUT_RELEASE_REMOTE" "v${version}"
  git push "$CUT_RELEASE_REMOTE" "$branch"
}

# cr_get_pull_token <image> → prints an anonymous GHCR pull token (empty return
# means the token exchange failed — the package may be private/denied).
cr_get_pull_token() {
  local image="$1"
  local url="${GHCR_REGISTRY%/}/token?scope=repository:${GHCR_OWNER}/${image}:pull"
  local tmp code token
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  token="$(jq -r '.token // empty' "$tmp" 2>/dev/null)" || token=""
  rm -f "$tmp"
  if [ "$code" = "200" ] && [ -n "$token" ]; then
    printf '%s' "$token"
    return 0
  fi
  return 1
}

# cr_manifest_status <image> <tag> → prints the HTTP code of the manifest GET
# (200 = published, 404/401 = not yet, 000 = network error).
cr_manifest_status() {
  local image="$1" tag="$2"
  local url="${GHCR_REGISTRY%/}/v2/${GHCR_OWNER}/${image}/manifests/${tag}"
  local token="" code
  token="$(cr_get_pull_token "$image")" || token=""
  local auth=()
  if [ -n "$token" ]; then
    auth=(-H "Authorization: Bearer $token")
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' \
    -H "Accept: application/vnd.oci.image.index.v1+json" \
    "${auth[@]}" "$url" 2>/dev/null)" || code="000"
  printf '%s' "$code"
}

# cr_probe_anonymous_pull <image> → prints pullable / denied (HTTP n) /
# unreachable and returns 0 / 1 / 2. The single source of truth for the
# "is the GHCR package public" check (see #606).
cr_probe_anonymous_pull() {
  local image="$1"
  local url="${GHCR_REGISTRY%/}/token?scope=repository:${GHCR_OWNER}/${image}:pull"
  local tmp code token
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null)" || code="000"
  token="$(jq -r '.token // empty' "$tmp" 2>/dev/null)" || token=""
  rm -f "$tmp"
  if [ "$code" = "200" ] && [ -n "$token" ]; then
    echo "pullable"
    return 0
  fi
  if [ "$code" = "000" ]; then
    echo "unreachable"
    return 2
  fi
  echo "denied (HTTP ${code})"
  return 1
}

cr_wait_images() {
  local tag="$1"
  local images=()
  read -r -a images <<<"$CUT_RELEASE_IMAGES"
  local deadline now round code img pending
  deadline=$(( $(date +%s) + WAIT_TIMEOUT_SECS ))
  round=0
  while :; do
    round=$((round + 1))
    pending=""
    for img in "${images[@]}"; do
      code="$(cr_manifest_status "$img" "$tag")"
      case "$code" in
        200) : ;;
        404 | 401 | 000) pending+="${img} " ;;
        *)
          cr_fail "registry returned HTTP ${code} for ${GHCR_OWNER}/${img}:${tag} (not a transient state)"
          ;;
      esac
    done
    if [ -z "$pending" ]; then
      cr_pass "all ${#images[@]} images published ${tag} (after ${round} poll round(s))"
      return 0
    fi
    now="$(date +%s)"
    if [ "$now" -ge "$deadline" ]; then
      break
    fi
    echo "  waiting: ${pending}— next poll in ${POLL_INTERVAL_SECS}s"
    sleep "$POLL_INTERVAL_SECS"
  done
  if [ -n "$WOODPECKER_SERVER" ]; then
    cr_fail "no manifest for ${tag} after ${WAIT_TIMEOUT_SECS}s (still missing: ${pending% } ) — the tag-triggered CI build may have failed. Check the Woodpecker pipeline (.woodpecker/publish-images.yml) for tag ${tag} at ${WOODPECKER_SERVER%/}/"
  fi
  cr_fail "no manifest for ${tag} after ${WAIT_TIMEOUT_SECS}s (still missing: ${pending% } ) — the tag-triggered CI build may have failed. Check the Woodpecker pipeline (.woodpecker/publish-images.yml) for tag ${tag} (set WOODPECKER_SERVER to get the exact URL)"
}

cr_check_visibility() {
  local images=()
  read -r -a images <<<"$CUT_RELEASE_IMAGES"
  local img status rc
  for img in "${images[@]}"; do
    rc=0
    status="$(cr_probe_anonymous_pull "$img")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      cr_pass "${GHCR_OWNER}/${img}: anonymously pullable"
    elif [ "$rc" -eq 2 ]; then
      cr_fail "${GHCR_OWNER}/${img}: ${GHCR_REGISTRY} unreachable (${status}) — network failure, not a visibility verdict. Check connectivity to ${GHCR_REGISTRY} and re-run; the package may be fine. Probed: GET ${GHCR_REGISTRY%/}/token?scope=repository:${GHCR_OWNER}/${img}:pull (no auth)"
    else
      cr_fail "${GHCR_OWNER}/${img}: anonymous pull ${status} — the package is private. Fix: GitHub → Packages → ${GHCR_OWNER}/${img} → Settings → Visibility → Public (see #606). Probed: GET ${GHCR_REGISTRY%/}/token?scope=repository:${GHCR_OWNER}/${img}:pull (no auth)"
    fi
  done
}

cr_next_steps() {
  local version="$1"
  cat <<EOF
Next steps (images are published — verify the release):
  1. Run the release smoke (compose + Nomad stages, #1227):
       VERSION=v${version} bash tests/release-smoke.sh
  2. Record the result, then follow the runbook:
       docs/release-verification.md
  3. Announce the release (notes + any vault actions) per the runbook.
EOF
}

main() {
  local version="" dry_run=0 yes=0 on_main=0 skip_wait=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry_run=1 ;;
      --yes) yes=1 ;;
      --main) on_main=1 ;;
      --skip-wait) skip_wait=1 ;;
      -h | --help) usage; exit 0 ;;
      -*)
        echo "error: unknown flag: $a" >&2
        usage >&2
        exit 2
        ;;
      *)
        if [ -z "$version" ]; then
          version="$a"
        else
          echo "error: unexpected argument: $a" >&2
          exit 2
        fi
        ;;
    esac
  done
  if [ -z "$version" ]; then
    usage >&2
    exit 2
  fi
  version="${version#v}"

  local repo_root
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "error: not inside a git repository" >&2
    exit 1
  }
  cd "$repo_root"

  # ── Stage 1: pre-flight (read-only) ────────────────────────────────────
  CR_STAGE=1
  cr_preflight_collect "$version" "$on_main"
  if [ "$dry_run" -eq 1 ]; then
    if [ -n "$CR_ISSUES" ]; then
      while IFS= read -r line; do
        if [ -n "$line" ]; then
          echo "  pre-flight ISSUE: ${line}"
        fi
      done <<<"$CR_ISSUES"
    else
      cr_preflight_pass "$version"
    fi
    while IFS= read -r line; do
      if [ -n "$line" ]; then
        echo "  pre-flight WARN: ${line}"
      fi
    done <<<"$CR_WARNS"
    echo ""
    local plan_resume=0
    if cr_resume_state "$version" "$on_main"; then
      plan_resume=1
    fi
    cr_print_plan "$version" "$on_main" "$plan_resume"
    echo ""
    echo "DRY RUN — no changes made (no branch, no commit, no tag, no push)."
    return 0
  fi
  if [ -n "$CR_ISSUES" ]; then
    while IFS= read -r line; do
      if [ -n "$line" ]; then
        cr_fail "$line"
      fi
    done <<<"$CR_ISSUES"
  fi
  while IFS= read -r line; do
    if [ -n "$line" ]; then
      echo "  note: ${line}"
    fi
  done <<<"$CR_WARNS"
  cr_preflight_pass "$version"

  # ── Stage 2: bump + commit (local, no push) ────────────────────────────
  CR_STAGE=2
  cr_bump "$version" "$on_main"
  local branch
  branch="$CR_BUMP_BRANCH"
  if [ "$CR_RESUME" -eq 1 ]; then
    cr_pass "VERSION already ${version} on ${branch} (resuming — stage 2 no-op, no new commit)"
  else
    cr_pass "bumped VERSION ${CR_CURRENT_VERSION:-?} -> ${version} on ${branch} (commit: release: v${version})"
  fi

  if [ "$yes" -ne 1 ]; then
    echo ""
    cr_print_plan "$version" "$on_main" 1
    echo ""
    echo "STOP: stages 3-6 (tag, push, wait, visibility) are gated behind --yes."
    if [ "$on_main" -eq 1 ]; then
      echo "Re-run: tools/cut-release.sh ${version} --yes --main"
    else
      echo "You are now on ${branch} — the re-run resumes from there."
      echo "Re-run: tools/cut-release.sh ${version} --yes"
    fi
    return 0
  fi

  # ── Stage 3: tag + push (triggers the CI pipeline) ─────────────────────
  CR_STAGE=3
  cr_tag_push "$version" "$branch"
  cr_pass "tagged v${version} and pushed tag + ${branch} to ${CUT_RELEASE_REMOTE}"

  # ── Stage 4: wait for the CI build to publish the images ───────────────
  CR_STAGE=4
  if [ "$skip_wait" -eq 1 ]; then
    cr_skip "manifest wait skipped (--skip-wait)"
  else
    cr_wait_images "v${version}"
  fi

  # ── Stage 5: GHCR package visibility (anonymous pull) ──────────────────
  CR_STAGE=5
  cr_check_visibility

  # ── Stage 6: next steps ────────────────────────────────────────────────
  CR_STAGE=6
  cr_next_steps "$version"
  cr_pass "next steps printed"
  echo ""
  echo "=== CUT-RELEASE v${version}: DONE ==="
}

# Allow `source tools/cut-release.sh` to pick up the functions (e.g. the
# acceptance test's anonymous visibility probe) without running main.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  return 0 2>/dev/null || true
fi

main "$@"
