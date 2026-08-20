#!/usr/bin/env bash
# verify-series.sh — verify the captured patches/ series two independent ways
# (docs/rebase-runbook.md §4; browser#106). Run on the build box, in $CHROMIUM_SRC,
# right after step 4's `git format-patch` — before build.sh, before publishing.
#
#   1. REPRODUCTION (pre-existing check, now scripted): apply the series with
#      `git apply --cached --binary` onto a throwaway index seeded from
#      $CHROMIUM_TAG. The resulting tree must equal $FORK_BRANCH's tree exactly.
#      This catches a bad `format-patch` capture (dropped/reordered/truncated
#      patches) but nothing else — see #2.
#
#   2. FRESH-CLONE APPLY GATE (browser#106, new): apply the series with a PLAIN
#      `git am --keep-non-patch --no-3way` onto a `git worktree` of $CHROMIUM_TAG,
#      then require its resulting tree to equal $FORK_BRANCH's tree.
#
#      Why a worktree is safe here even though it shares this repo's object DB:
#      plain (non-3way) `git am` never looks up ancestor blobs — it applies each
#      patch's literal diff hunks textually against the files on disk, exactly
#      like `patch`/`git apply` would. It has no way to "reach into" objects that
#      only exist in $FORK_BRANCH's history, shared object DB or not. That is
#      precisely what --3way does NOT do and plain am DOES: --3way, on a conflict,
#      reconstructs a fake pre-image ("ancestor") from whatever blob the patch's
#      SHA1 line names IF that blob happens to be reachable in the local object
#      DB (e.g. because this checkout has built displayxr-inline-3d before, or
#      because $FORK_BRANCH's own history is right here) and then 3-way-merges
#      against it. On a genuine fresh clone none of those blobs exist, so --3way
#      degrades to the same textual apply plain am does. A worktree of the tag
#      reproduces that "no such blob" reality for plain am while still being
#      cheap (no network fetch, no second checkout of Chromium). This was
#      cross-checked against a true fresh clone in #106: plain am failed
#      identically there.
#
#      TELL: if step 2 fails with "sha1 information is lacking or useless" that
#      means you ran WITH --3way (or the caller changed this script) and it just
#      built a fake ancestor from history this repo happens to have lying around
#      — i.e. the exact masking bug #106 was filed about. That string is not a
#      generic warning here; it means the gate was bypassed, not merely tripped.
#      "patch does not apply" / "patch failed: <file>:<line>" is the real,
#      unmasked failure: some patch's declared pre-image does not match what the
#      patches before it actually produce (internal series drift) — recapture
#      the series per §4 step 1-3, do not hand-splice patch 0022-style.
#
# Usage:
#   scripts/verify-series.sh [--tag TAG] [--branch BRANCH] [--src DIR] [--patch-dir DIR]
# All flags default from scripts/config.env / the fork convention; override for testing.
#
# Exit: 0 = both checks pass · 1 = a check failed (see stderr for which) · 2 = usage/env error
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
[ -f "$HERE/config.env" ] && source "$HERE/config.env"

TAG="${CHROMIUM_TAG:-}"
SRC="${CHROMIUM_SRC:-}"
BRANCH="${FORK_BRANCH:-displayxr-inline-3d}"
PATCH_DIR="${PATCH_DIR:-$REPO/patches}"

while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:-}"; shift 2;;
    --branch) BRANCH="${2:-}"; shift 2;;
    --src) SRC="${2:-}"; shift 2;;
    --patch-dir) PATCH_DIR="${2:-}"; shift 2;;
    *) echo "verify-series: unknown arg $1" >&2; exit 2;;
  esac
done

fail() { echo; echo "RESULT: FAIL — $*" >&2; exit 1; }
[ -n "$TAG" ]   || { echo "usage: verify-series.sh --tag TAG [--branch BRANCH] [--src DIR] [--patch-dir DIR]" >&2; exit 2; }
[ -n "$SRC" ]   || { echo "verify-series: need --src (Chromium checkout) or CHROMIUM_SRC in config.env" >&2; exit 2; }
[ -d "$SRC/.git" ] || { echo "verify-series: not a git checkout: $SRC" >&2; exit 2; }
[ -d "$PATCH_DIR" ] || { echo "verify-series: patch dir not found: $PATCH_DIR" >&2; exit 2; }

PATCHES=("$PATCH_DIR"/*.patch)
[ -e "${PATCHES[0]}" ] || { echo "verify-series: no *.patch files in $PATCH_DIR" >&2; exit 2; }
echo "verify-series: tag=$TAG branch=$BRANCH src=$SRC patches=${#PATCHES[@]} ($PATCH_DIR)"

git -C "$SRC" rev-parse --verify "$TAG^{commit}" >/dev/null 2>&1 || fail "tag not found in $SRC: $TAG (fetch it first)"
WANT_TREE="$(git -C "$SRC" rev-parse "$BRANCH^{tree}" 2>/dev/null)" || fail "branch not found in $SRC: $BRANCH"

# Windows git-bash has no reliable /tmp; use $TEMP/$TMPDIR, falling back to /tmp elsewhere.
TMP_BASE="${TMPDIR:-${TEMP:-/tmp}}"
mkdir -p "$TMP_BASE"

# ── 1. REPRODUCTION: series applied onto TAG (cached, no working tree touched) ──────────
echo
echo "[1/2] reproduction check — series onto a throwaway index seeded from $TAG"
IDX="$(mktemp "$TMP_BASE/dxr-verify-idx.XXXXXX")"
rm -f "$IDX"
REPRO_OK=1
if ! GIT_INDEX_FILE="$IDX" git -C "$SRC" read-tree "$TAG"; then
  echo "  read-tree $TAG failed" >&2
  REPRO_OK=0
else
  for p in "${PATCHES[@]}"; do
    if ! GIT_INDEX_FILE="$IDX" git -C "$SRC" apply --cached --binary "$p"; then
      echo "  FAIL applying $p" >&2
      REPRO_OK=0
      break
    fi
  done
fi
if [ "$REPRO_OK" = 1 ]; then
  GOT_TREE="$(GIT_INDEX_FILE="$IDX" git -C "$SRC" write-tree)"
  if [ "$GOT_TREE" = "$WANT_TREE" ]; then
    echo "  OK — reproduces $BRANCH's tree ($GOT_TREE)"
  else
    echo "  tree mismatch: got $GOT_TREE, want $WANT_TREE" >&2
    REPRO_OK=0
  fi
fi
rm -f "$IDX"
[ "$REPRO_OK" = 1 ] || fail "reproduction check failed — series does not reproduce $BRANCH (bad capture: dropped/reordered/truncated patch?)"

# ── 2. FRESH-CLONE APPLY GATE (#106): plain am onto a worktree of TAG ───────────────────
echo
echo "[2/2] fresh-clone apply gate — plain 'git am --no-3way' onto a worktree of $TAG"
WT="$(mktemp -d "$TMP_BASE/dxr-verify-wt.XXXXXX")"
rmdir "$WT"   # let `git worktree add` create it; avoids "already exists" on strict platforms
cleanup_wt() { git -C "$SRC" worktree remove --force "$WT" >/dev/null 2>&1 || rm -rf "$WT"; }

if ! git -C "$SRC" worktree add --detach "$WT" "$TAG" >/dev/null; then
  fail "could not create worktree at $TAG"
fi

FRESH_OK=1
if ! git -C "$WT" am --keep-non-patch --no-3way "${PATCHES[@]}"; then
  echo "  plain am FAILED — see the 'patch failed' / 'does not apply' output above." >&2
  echo "  (If you instead see 'sha1 information is lacking or useless', this script" >&2
  echo "  is not calling --no-3way — that message means the gate got bypassed, not that it caught something.)" >&2
  git -C "$WT" am --abort >/dev/null 2>&1 || true
  FRESH_OK=0
else
  GOT_TREE="$(git -C "$WT" rev-parse HEAD^{tree})"
  if [ "$GOT_TREE" = "$WANT_TREE" ]; then
    echo "  OK — plain am on a fresh $TAG worktree reproduces $BRANCH's tree ($GOT_TREE)"
  else
    echo "  am succeeded but tree mismatch: got $GOT_TREE, want $WANT_TREE" >&2
    FRESH_OK=0
  fi
fi
cleanup_wt
[ "$FRESH_OK" = 1 ] || fail "fresh-clone apply gate failed — a genuine fresh clone of $TAG cannot apply this series (browser#106 class)"

echo
echo "RESULT: PASS — series reproduces $BRANCH both from the fork's own history and from a fresh clone of $TAG"
exit 0
