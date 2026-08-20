#!/usr/bin/env bash
# weave-gate.sh — decide whether a Chromium rebase can auto-publish or needs a human
# hardware eyeball (browser#37, decision #2 on browser#33).
#
# THE RULE
#   PATCHED  = existing Chromium files our patch series MODIFIES
#   UPSTREAM = files Chromium changed between the old and new tag
#   RISK     = PATCHED ∩ UPSTREAM
#   RISK empty  -> AUTO-PASS. Upstream touched nothing we patch, so after re-applying the
#                  series our weave-bearing code is byte-identical to the build that was
#                  last validated on hardware. A green build cannot have broken the weave.
#   RISK nonempty -> HOLD. Our edits landed on code upstream moved; a human eyeballs the
#                  weave on real hardware before this ships.
#
# WHY THE PATCH SERIES AND NOT docs/integration-points.md:
#   The doc's `⚠ Edit` lists are prose (nested brace-expansion, line-wrapped, sometimes
#   partial paths). Mis-parsing it would silently SHRINK the risk set and fail OPEN — the
#   one failure mode a safety gate must not have. The patch series is authoritative (it IS
#   what we edit), self-maintaining (a new patch updates the set for free), and needs no
#   prose parsing. Files our patches ADD are excluded automatically: upstream doesn't have
#   them, so they can never appear in UPSTREAM.
#
# FAIL-SAFE: any error, empty input, or unknown state exits HOLD (2), never PASS.
#
# NOT a substitute for scripts/verify-series.sh (browser#106): this gate classifies risk from
# upstream diffs and never actually applies the series, so it cannot detect internal series drift
# (a patch's pre-image no longer matching what earlier patches produce). Run verify-series.sh at
# capture time (rebase-runbook.md §4); run this gate at rebase-decision time.
#
# Usage:
#   scripts/weave-gate.sh --old 150.0.7871.24 --new 150.0.7871.129 [--src C:/cr/src]
#   scripts/weave-gate.sh --old X --new Y --changed-file <precomputed-list>   # for tests/CI
#
# Exit: 0 = AUTO-PASS · 2 = HOLD (human eyeball) · 3 = usage/internal error (treat as HOLD)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
PATCH_DIR="${PATCH_DIR:-$REPO/patches}"
SRC=""; OLD=""; NEW=""; CHANGED_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --old) OLD="${2:-}"; shift 2;;
    --new) NEW="${2:-}"; shift 2;;
    --src) SRC="${2:-}"; shift 2;;
    --changed-file) CHANGED_FILE="${2:-}"; shift 2;;
    --patch-dir) PATCH_DIR="${2:-}"; shift 2;;
    *) echo "weave-gate: unknown arg $1" >&2; exit 3;;
  esac
done

hold() { echo; echo "RESULT: HOLD — $*"; exit 2; }
[ -n "$OLD" ] && [ -n "$NEW" ] || { echo "usage: weave-gate.sh --old TAG --new TAG [--src DIR]" >&2; exit 3; }
[ -d "$PATCH_DIR" ] || hold "patch dir not found: $PATCH_DIR (cannot compute the patched set)"

# ── 1. PATCHED: files the series touches, per the patch headers ──────────────────────
# Take the "+++ b/<path>" side; /dev/null means a delete. Additions are filtered out in
# step 3 by intersecting with upstream's changed set (upstream can't change a file it
# doesn't have), so we deliberately do not try to classify add-vs-modify here.
PATCHED="$(mktemp)"
grep -h '^+++ ' "$PATCH_DIR"/*.patch 2>/dev/null \
  | sed -e 's#^+++ b/##' -e 's#^+++ ##' -e 's/[[:space:]].*$//' \
  | grep -v '^/dev/null$' | sort -u > "$PATCHED"
PATCHED_N=$(wc -l < "$PATCHED" | tr -d ' ')
[ "$PATCHED_N" -gt 0 ] || hold "patch series yielded 0 files — parse failed or empty series"
echo "weave-gate: patch series touches $PATCHED_N files ($PATCH_DIR)"

# ── 2. UPSTREAM: what Chromium changed between the tags ──────────────────────────────
UPSTREAM="$(mktemp)"
if [ -n "$CHANGED_FILE" ]; then
  [ -f "$CHANGED_FILE" ] || hold "--changed-file not found: $CHANGED_FILE"
  sort -u < "$CHANGED_FILE" > "$UPSTREAM"
  echo "weave-gate: upstream changes read from $CHANGED_FILE"
else
  [ -n "$SRC" ] || hold "need --src (Chromium checkout) or --changed-file"
  [ -d "$SRC/.git" ] || hold "not a git checkout: $SRC"
  git -C "$SRC" diff --name-only "$OLD" "$NEW" 2>/dev/null | sort -u > "$UPSTREAM" || \
    hold "git diff $OLD..$NEW failed (are both tags fetched?)"
fi
UPSTREAM_N=$(wc -l < "$UPSTREAM" | tr -d ' ')
[ "$UPSTREAM_N" -gt 0 ] || hold "upstream diff $OLD..$NEW is empty — suspicious, refusing to auto-pass"
echo "weave-gate: upstream changed $UPSTREAM_N files between $OLD and $NEW"

# ── 3. RISK = intersection ───────────────────────────────────────────────────────────
RISK="$(comm -12 "$PATCHED" "$UPSTREAM")"
if [ -z "$RISK" ]; then
  echo
  echo "RESULT: AUTO-PASS — upstream touched none of the $PATCHED_N files the patch series"
  echo "        modifies, so the weave-bearing code is byte-identical to the last"
  echo "        hardware-validated build."
  exit 0
fi
echo
echo "weave-bearing files upstream also changed:"
echo "$RISK" | sed 's/^/  - /'
hold "$(echo "$RISK" | wc -l | tr -d ' ') patched file(s) moved upstream — eyeball the weave on hardware before publishing"
