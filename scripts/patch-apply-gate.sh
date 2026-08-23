#!/usr/bin/env bash
# patch-apply-gate.sh — prove patches/ applies to a FRESH clone of $CHROMIUM_TAG,
# without a Chromium checkout (browser#111; the class of failure is browser#106).
#
# ── What this is and why it is not verify-series.sh ────────────────────────────────────────
# scripts/verify-series.sh answers the same question but needs a 20 GB Chromium checkout
# and the fork branch, so it only ever runs on the build box, by hand, after a recapture.
# This script answers it on a stock GitHub-hosted runner in minutes, so it can run on
# every PR that touches patches/ or scripts/config.env.
#
# It does that by building a SYNTHETIC checkout: the ~100 files the series touches that
# actually exist at the pinned tag, fetched from gitiles, committed as one baseline commit
# in a scratch repo. Every other Chromium file is irrelevant — a patch can only fail on a
# file it names.
#
# The synthetic checkout reproduces the fresh-clone condition *exactly* where it matters:
# its object database holds the tag's blobs for the touched files and NOTHING ELSE. No fork
# blobs, no `displayxr-inline-3d` history. That is what makes `git am --3way` honest here —
# on the fork's home box --3way silently reconstructs a "fake ancestor" from leftover fork
# objects and content-merges real drift away (browser#106). With no such objects present,
# --3way degrades to a plain textual apply, which is what a new contributor, a new build
# box, or the Android builder actually gets.
#
# ── HARNESS fault vs PATCH fault (the whole point — read this) ──────────────────────────────
# browser#132 is the cautionary tale: a rebase tool overflowed the Windows command line,
# `git am` never ran at all, and the tooling reported the result as patch drift. A gate that
# can blame the patches for its own breakage is worse than no gate.
#
# So this script has exactly three exit codes and never conflates them:
#
#   0  PASS         — the whole series applied, zero rejects, commit count == patch count.
#   1  PATCH FAULT  — the baseline was assembled and `git am` DID run and DID reject a patch.
#                     The run names the patch, the file, and the rejected hunk.
#   2  HARNESS FAULT— the baseline could not be assembled (network, gitiles 429/5xx, bad
#                     base64, missing tool, no patches found). This says NOTHING about the
#                     patches. Re-run it.
#
# A gitiles 404 is NOT a transient: it is the definitive answer "this path does not exist at
# the tag", which is the normal case for the 70-odd files the series CREATES. Transients
# (429, 5xx, curl failure, undecodable body) are retried with backoff and, if they survive
# the retries, become a HARNESS fault — never a patch fault.
#
# ── Usage ──────────────────────────────────────────────────────────────────────────────────
#   scripts/patch-apply-gate.sh [--tag TAG] [--patch-dir DIR] [--cache-dir DIR]
#                               [--work-dir DIR] [--keep] [--delay SECONDS]
#                               [--list-files]
#
#   --tag        Chromium tag to fetch the baseline from. Default: $CHROMIUM_TAG from
#                scripts/config.env — the single source of truth for the pin.
#   --patch-dir  Series to test. Default: <repo>/patches. Point it at a scratch copy to
#                test a hypothetical break without committing one.
#   --cache-dir  Where fetched gitiles blobs live, namespaced by tag. Safe to keep forever:
#                a git tag is immutable, so a cached blob can never go stale.
#   --keep       Leave the scratch repo on disk for post-mortem poking.
#   --delay      Seconds to sleep between gitiles requests (default 0).
#   --list-files Print the derived touched-file list and exit 0. CI hashes this for the
#                baseline cache key, so the key derives from the same code that does the
#                fetching and can never disagree with it.
#
# ── Why fetching is SERIAL ─────────────────────────────────────────────────────────────────
# The browser#110 dry run fetched 8-way parallel and got HTTP 429'd by gitiles. ~100 files
# serially is a couple of minutes cold and ~zero warm, because the cache is keyed on the tag
# and a tag never moves. Do not "optimise" this back into parallel fetching.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
# shellcheck source=/dev/null
[ -f "$HERE/config.env" ] && source "$HERE/config.env"

TAG="${CHROMIUM_TAG:-}"
PATCH_DIR="$REPO/patches"
TMP_BASE="${TMPDIR:-${TEMP:-/tmp}}"
CACHE_DIR="${DXR_GATE_CACHE:-$TMP_BASE/dxr-gitiles-cache}"
WORK_DIR=""
KEEP=0
LIST_ONLY=0
DELAY="${DXR_GATE_DELAY:-0}"
GITILES_BASE="https://chromium.googlesource.com/chromium/src/+"
MAX_ATTEMPTS=5

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)       TAG="${2:-}"; shift 2;;
    --patch-dir) PATCH_DIR="${2:-}"; shift 2;;
    --cache-dir) CACHE_DIR="${2:-}"; shift 2;;
    --work-dir)  WORK_DIR="${2:-}"; shift 2;;
    --delay)     DELAY="${2:-}"; shift 2;;
    --keep)      KEEP=1; shift;;
    --list-files) LIST_ONLY=1; shift;;
    -h|--help)   sed -n '2,66p' "${BASH_SOURCE[0]}"; exit 0;;
    *) echo "patch-apply-gate: unknown arg $1" >&2; exit 2;;
  esac
done

# Every early exit goes through one of these two, so the log can never be ambiguous about
# which kind of failure it is reporting.
harness_fault() {
  echo
  echo "=============================================================================="
  echo "RESULT: HARNESS FAULT — the gate could not run. This is NOT a patch failure."
  echo "  $*"
  echo
  echo "  Nothing here says anything about patches/. The baseline checkout could not be"
  echo "  assembled, so 'git am' was never given a fair chance to run. Re-run the job;"
  echo "  if it keeps failing the same way, the gate itself needs fixing (browser#111)."
  echo "=============================================================================="
  exit 2
}
patch_fault() {
  echo
  echo "=============================================================================="
  echo "RESULT: PATCH FAULT — the series does not apply to a fresh clone of $TAG."
  echo "  $*"
  echo "=============================================================================="
  exit 1
}

[ -n "$TAG" ] || harness_fault "no CHROMIUM_TAG (pass --tag or fix scripts/config.env)"
[ -d "$PATCH_DIR" ] || harness_fault "patch dir not found: $PATCH_DIR"
for tool in git curl base64 awk sort; do
  command -v "$tool" >/dev/null 2>&1 || harness_fault "required tool not on PATH: $tool"
done

shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
[ "${#PATCHES[@]}" -gt 0 ] || harness_fault "no *.patch files in $PATCH_DIR"
# Series order is filename order — that is what build.sh's `patches/*.patch` glob means.
IFS=$'\n' PATCHES=($(printf '%s\n' "${PATCHES[@]}" | LC_ALL=C sort)); unset IFS

if [ -z "$WORK_DIR" ]; then
  WORK_DIR="$(mktemp -d "$TMP_BASE/dxr-patch-gate.XXXXXX")" || harness_fault "cannot create work dir under $TMP_BASE"
  TRAP_WORK=1
else
  mkdir -p "$WORK_DIR" || harness_fault "cannot create work dir: $WORK_DIR"
  TRAP_WORK=0
fi
cleanup() { [ "$KEEP" = 1 ] && return 0; [ "${TRAP_WORK:-0}" = 1 ] && rm -rf "$WORK_DIR"; return 0; }
trap cleanup EXIT

# In --list-files mode stdout is the machine-readable list, so chatter goes nowhere.
say() { [ "$LIST_ONLY" = 1 ] || echo "$@"; }

say "patch-apply-gate: tag=$TAG patches=${#PATCHES[@]} ($PATCH_DIR)"
say "                  cache=$CACHE_DIR/$TAG  work=$WORK_DIR"

# ══ 1. Derive the touched-file set FROM THE SERIES ═══════════════════════════════════════
# Never from a hand-maintained list — the gate has to self-update as patches are added.
#
# Both sides of every `diff --git a/X b/Y` are collected. For a rename they differ; taking
# both means the baseline is a strict restriction of the real tag tree, never a lossy one.
# Scanning starts only after format-patch's `---` separator so that a commit message
# quoting a diff header cannot inject a phantom path.
say
say "[1/4] deriving touched files from the series"
awk '
  FNR == 1        { indiff = 0 }
  !indiff && /^---$/ { indiff = 1; next }
  !indiff         { next }
  /^diff --git /  { a = $3; b = $4; sub(/^a\//, "", a); sub(/^b\//, "", b)
                    print "T\t" a; print "T\t" b; cur = b; next }
  /^new file mode / { if (cur != "") print "N\t" cur; next }
  /^--- /         { cur = "" }
' "${PATCHES[@]}" > "$WORK_DIR/scan.tsv" || harness_fault "failed to scan the series for touched files"

awk -F'\t' '$1=="T"{print $2}' "$WORK_DIR/scan.tsv" | LC_ALL=C sort -u > "$WORK_DIR/touched.txt"
awk -F'\t' '$1=="N"{print $2}' "$WORK_DIR/scan.tsv" | LC_ALL=C sort -u > "$WORK_DIR/declared-new.txt"
N_TOUCHED=$(wc -l < "$WORK_DIR/touched.txt" | tr -d ' ')
N_DECLNEW=$(wc -l < "$WORK_DIR/declared-new.txt" | tr -d ' ')
[ "$N_TOUCHED" -gt 0 ] || harness_fault "the series scan found zero touched files — the scanner is broken, the patches are not"
if [ "$LIST_ONLY" = 1 ]; then cat "$WORK_DIR/touched.txt"; exit 0; fi
echo "      $N_TOUCHED distinct paths touched; $N_DECLNEW declared 'new file mode' by some patch"

# ══ 2. Fetch each touched file from gitiles at $TAG — SERIALLY, cached, with backoff ══════
# Gitiles' raw-file endpoint returns base64 for ?format=TEXT, plus two headers that make the
# classification airtight rather than inferred:
#
#   X-Gitiles-Object-Type: blob | tree | commit
#   X-Gitiles-Path-Mode:   100644 | 100755 | 040000 | 120000
#
# Those headers matter because the HTTP status alone is NOT a clean signal here — verified
# against the live service at 151.0.7922.77:
#
#   200 + object-type blob   file exists at the tag                 -> baseline
#   200 + object-type tree   the path is a DIRECTORY at the tag     -> not a pre-image
#                            (a bare 200-means-present rule would have base64-decoded a
#                             directory listing straight into the baseline as a "file")
#   404  NOT_FOUND           missing file under an existing dir     -> series-created
#   400  INVALID_ARGUMENT    missing file under a MISSING dir       -> series-created
#                            (gitiles answers "format type is not supported" because the
#                             path resolves to nothing; every components/displayxr/* path
#                             lands here, so 400 must be handled or the gate never starts)
#   429 / 5xx / curl != 0    transient                              -> retry, then HARNESS
#
# Whether a file is in the baseline is decided by what gitiles ACTUALLY RETURNS, never by
# the patch's `new file mode` header. The header is only cross-checked against reality
# afterwards, because a header that disagrees with the tag is itself a finding.
echo
echo "[2/4] fetching the baseline from gitiles at $TAG (serial; 429-safe)"
BLOBS="$CACHE_DIR/$TAG/blobs"
MODES="$CACHE_DIR/$TAG/mode"
ABSENT="$CACHE_DIR/$TAG/absent"
mkdir -p "$BLOBS" "$MODES" "$ABSENT" || harness_fault "cannot create cache under $CACHE_DIR"
: > "$WORK_DIR/hints.txt"

n=0; hit=0; got=0; miss=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  n=$((n + 1))
  if [ -f "$BLOBS/$path" ]; then hit=$((hit + 1)); got=$((got + 1)); continue; fi
  if [ -f "$ABSENT/$path" ]; then hit=$((hit + 1)); miss=$((miss + 1)); continue; fi

  url="$GITILES_BASE/$TAG/$path?format=TEXT"
  attempt=1
  while :; do
    b64="$WORK_DIR/.fetch.b64"
    hdr="$WORK_DIR/.fetch.hdr"
    code="$(curl -sS --max-time 90 -D "$hdr" -o "$b64" -w '%{http_code}' "$url" 2>"$WORK_DIR/.fetch.err")"
    rc=$?
    otype="$(awk 'BEGIN{IGNORECASE=1} /^X-Gitiles-Object-Type:/{print $2}' "$hdr" 2>/dev/null | tr -d '\r')"
    omode="$(awk 'BEGIN{IGNORECASE=1} /^X-Gitiles-Path-Mode:/{print $2}'   "$hdr" 2>/dev/null | tr -d '\r')"

    if [ "$rc" -eq 0 ] && [ "$code" = "200" ] && [ "$otype" = "blob" ]; then
      mkdir -p "$(dirname "$BLOBS/$path")" "$(dirname "$MODES/$path")" || harness_fault "cannot create cache dir for $path"
      # Decode to a temp file first: a half-written cache entry would poison every later run.
      if base64 -d < "$b64" > "$WORK_DIR/.fetch.bin" 2>/dev/null; then
        printf '%s\n' "${omode:-100644}" > "$MODES/$path"
        mv -f "$WORK_DIR/.fetch.bin" "$BLOBS/$path"
        got=$((got + 1))
        break
      fi
      # 200 with an undecodable body = truncated / interstitial response. Transient.
      reason="200 but body did not base64-decode"
    elif [ "$rc" -eq 0 ] && [ "$code" = "200" ]; then
      # A definitive answer, just not a blob. Not a pre-image; record it and flag it.
      mkdir -p "$(dirname "$ABSENT/$path")" || harness_fault "cannot create cache dir for $path"
      : > "$ABSENT/$path"
      echo "  the series names '$path' as a file, but at $TAG that path is a ${otype:-non-blob} (mode ${omode:-?})" >> "$WORK_DIR/hints.txt"
      miss=$((miss + 1))
      break
    elif [ "$rc" -eq 0 ] && { [ "$code" = "404" ] || { [ "$code" = "400" ] && grep -qE '^(NOT_FOUND|INVALID_ARGUMENT):' "$b64"; }; }; then
      mkdir -p "$(dirname "$ABSENT/$path")" || harness_fault "cannot create cache dir for $path"
      : > "$ABSENT/$path"
      miss=$((miss + 1))
      break
    else
      reason="curl rc=$rc http=$code"
    fi

    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
      echo "      giving up on $path after $MAX_ATTEMPTS attempts ($reason)" >&2
      sed -n '1,5p' "$WORK_DIR/.fetch.err" >&2 2>/dev/null || true
      sed -n '1,5p' "$b64" >&2 2>/dev/null || true
      harness_fault "gitiles fetch failed for $path ($reason) — network/rate-limit, not a patch problem"
    fi
    back=$(( 1 << attempt ))   # 2, 4, 8, 16 seconds
    echo "      retry $attempt/$MAX_ATTEMPTS for $path in ${back}s ($reason)"
    sleep "$back"
    attempt=$((attempt + 1))
  done

  [ "$DELAY" = "0" ] || sleep "$DELAY"
  [ $((n % 25)) -eq 0 ] && echo "      $n/$N_TOUCHED ..."
done < "$WORK_DIR/touched.txt"
rm -f "$WORK_DIR/.fetch.b64" "$WORK_DIR/.fetch.bin" "$WORK_DIR/.fetch.err" "$WORK_DIR/.fetch.hdr"

echo "      exists at $TAG: $got   created by the series: $miss   (cache hits: $hit/$n)"
[ "$got" -gt 0 ] || harness_fault "not one touched file exists at $TAG — that is a bad tag or a broken fetch, not patch drift"

# Cross-check the `new file mode` headers against what the tag actually holds. This is not
# fatal on its own — `git am` is the judge — but it is a strong hint about WHY a later
# rejection happened, and it costs nothing to print.
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$BLOBS/$path" ] && echo "  a patch declares 'new file mode' for a path that ALREADY EXISTS at $TAG: $path" >> "$WORK_DIR/hints.txt"
done < "$WORK_DIR/declared-new.txt"
if [ -s "$WORK_DIR/hints.txt" ]; then
  echo "      note — header/tag disagreements found:"
  cat "$WORK_DIR/hints.txt"
fi

# ══ 3. Assemble the synthetic checkout ════════════════════════════════════════════════════
echo
echo "[3/4] assembling the synthetic checkout"
SCRATCH="$WORK_DIR/scratch"
mkdir -p "$SCRATCH" || harness_fault "cannot create $SCRATCH"
staged=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$BLOBS/$path" ] || continue
  mkdir -p "$SCRATCH/$(dirname "$path")" || harness_fault "cannot stage $path"
  cp "$BLOBS/$path" "$SCRATCH/$path" || harness_fault "cannot stage $path"
  staged=$((staged + 1))
done < "$WORK_DIR/touched.txt"
[ "$staged" = "$got" ] || harness_fault "staged $staged files but fetched $got — the baseline is incomplete"

# autocrlf/eol are load-bearing on a Windows checkout: any line-ending rewrite would change
# every pre-image and turn the gate into a random-number generator. filemode=false plus an
# explicit `update-index --chmod` below means the exec bit comes from gitiles' reported mode
# on every platform, rather than from whatever the local filesystem happened to preserve.
git -C "$SCRATCH" init -q                    || harness_fault "git init failed in $SCRATCH"
git -C "$SCRATCH" config core.autocrlf false || harness_fault "git config failed"
git -C "$SCRATCH" config core.eol lf
git -C "$SCRATCH" config core.safecrlf false
git -C "$SCRATCH" config core.filemode false
git -C "$SCRATCH" config user.name  "DisplayXR patch gate"
git -C "$SCRATCH" config user.email "patch-gate@displayxr.invalid"
git -C "$SCRATCH" add -A                     || harness_fault "git add failed in the synthetic checkout"
execbits=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ -f "$MODES/$path" ] || continue
  [ "$(cat "$MODES/$path")" = "100755" ] || continue
  git -C "$SCRATCH" update-index --chmod=+x -- "$path" || harness_fault "cannot set the exec bit on $path"
  execbits=$((execbits + 1))
done < "$WORK_DIR/touched.txt"
git -C "$SCRATCH" commit -q -m "synthetic baseline: chromium/src @ $TAG ($staged touched files, $execbits executable)" \
                                             || harness_fault "git commit of the baseline failed"
BASE_COMMIT="$(git -C "$SCRATCH" rev-parse HEAD)"
BASE_FILES="$(git -C "$SCRATCH" ls-tree -r --name-only HEAD | wc -l | tr -d ' ')"
[ "$BASE_FILES" = "$staged" ] || harness_fault "baseline commit holds $BASE_FILES files, expected $staged"
echo "      baseline commit $BASE_COMMIT with $BASE_FILES files"

# One mailbox rather than ${#PATCHES[@]} arguments. This is a direct lesson from browser#132,
# where a long argument list overflowed and the apply silently never happened: an mbox on a
# single argv entry cannot overflow, and a short mbox is detectable (asserted below).
MBOX="$WORK_DIR/series.mbox"
: > "$MBOX"
for p in "${PATCHES[@]}"; do
  cat "$p" >> "$MBOX" || harness_fault "cannot read $p"
  # format-patch files end in a newline, but a hand-truncated one would silently glue two
  # patches together. Cheap insurance.
  [ -n "$(tail -c 1 "$p")" ] && printf '\n' >> "$MBOX"
done
MBOX_PATCHES="$(grep -c '^From [0-9a-f]\{40\} ' "$MBOX" || true)"
[ "$MBOX_PATCHES" = "${#PATCHES[@]}" ] || \
  harness_fault "built a mailbox with $MBOX_PATCHES messages from ${#PATCHES[@]} patch files — the mailbox is malformed, so 'git am' would be judging the wrong input"

# ══ 4. Apply the series exactly as build.sh does ══════════════════════════════════════════
echo
echo "[4/4] git am --3way --keep-non-patch — ${#PATCHES[@]} patches onto $TAG"
AMLOG="$WORK_DIR/am.log"
git -C "$SCRATCH" am --3way --keep-non-patch "$MBOX" > "$AMLOG" 2>&1
AM_RC=$?
APPLIED="$(git -C "$SCRATCH" rev-list --count "$BASE_COMMIT"..HEAD 2>/dev/null || echo 0)"

if [ "$AM_RC" -ne 0 ]; then
  # APPLIED patches landed, so the failure is patch number APPLIED+1 in filename order.
  IDX="$APPLIED"
  BAD="${PATCHES[$IDX]:-<unknown>}"
  echo
  echo "------------------------------------------------------------------------------"
  echo "FAILED PATCH: $(basename "$BAD")"
  echo "  applied cleanly before it: $APPLIED of ${#PATCHES[@]}"
  grep -m1 '^Subject:' "$BAD" 2>/dev/null | sed 's/^/  /'
  echo "------------------------------------------------------------------------------"
  echo "git am said:"
  sed 's/^/  /' "$AMLOG"
  if grep -q 'sha1 information is lacking' "$AMLOG"; then
    echo
    echo "  ('sha1 information is lacking or useless' means: plain apply failed AND --3way could"
    echo "   not rebuild the declared pre-image, because the blob that pre-image names exists"
    echo "   nowhere at $TAG. In verify-series.sh that string signals a bypassed gate; HERE it is"
    echo "   the genuine fresh-clone failure, because this scratch repo holds tag blobs only.)"
  fi

  # Re-apply the offending patch alone with --reject to materialise the rejected hunks.
  # `git am --abort` rewinds all the way to the baseline, so recapture the post-(N-1) commit
  # first and reset forward onto it — that is the tree state the failing patch expected.
  STATE="$(git -C "$SCRATCH" rev-parse HEAD 2>/dev/null || echo "$BASE_COMMIT")"
  git -C "$SCRATCH" am --abort >/dev/null 2>&1 || true
  git -C "$SCRATCH" reset -q --hard "$STATE" >/dev/null 2>&1 || true
  echo
  echo "rejected hunks (git apply --reject --verbose):"
  git -C "$SCRATCH" apply --reject --verbose "$BAD" > "$WORK_DIR/reject.log" 2>&1 || true
  sed 's/^/  /' "$WORK_DIR/reject.log"
  while IFS= read -r rej; do
    echo
    echo "  --- $(basename "$rej") ---"
    sed 's/^/  /' "$rej"
  done < <(find "$SCRATCH" -name '*.rej' 2>/dev/null | LC_ALL=C sort)

  if [ -s "$WORK_DIR/hints.txt" ]; then
    echo
    echo "possibly related header/tag disagreements:"
    cat "$WORK_DIR/hints.txt"
  fi

  echo
  echo "What this means: $(basename "$BAD") declares a pre-image that the patches before it"
  echo "do not produce at $TAG. Fix it by RE-ANCHORING the patch (docs/rebase-runbook.md §4),"
  echo "never by hand-editing the .patch file — regenerate it with git format-patch."
  echo
  echo "Note: a stale 'index <sha>..<sha>' line is NOT what failed here. git apply never reads"
  echo "it; only the context lines matter."
  patch_fault "$(basename "$BAD") rejected after $APPLIED clean patches"
fi

# `git am` returned 0 — now assert it actually did the work, rather than trusting the code.
if [ "$APPLIED" != "${#PATCHES[@]}" ]; then
  harness_fault "git am exited 0 but produced $APPLIED commits from ${#PATCHES[@]} patches — the apply did not really happen (browser#132 class)"
fi
STRAY_REJ="$(find "$SCRATCH" -name '*.rej' 2>/dev/null | wc -l | tr -d ' ')"
[ "$STRAY_REJ" = "0" ] || patch_fault "$STRAY_REJ .rej file(s) left behind despite a zero exit"
DIRTY="$(git -C "$SCRATCH" status --porcelain | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] || harness_fault "the scratch tree is dirty after a clean am ($DIRTY entries) — the gate is confused, do not read this as patch drift"

echo
echo "=============================================================================="
echo "RESULT: PASS — all ${#PATCHES[@]} patches apply to a fresh clone of $TAG."
echo "  baseline: $got files fetched from gitiles, $miss series-created paths correctly absent"
echo "  commits produced: $APPLIED   rejects: 0   working tree: clean"
echo "=============================================================================="
exit 0
