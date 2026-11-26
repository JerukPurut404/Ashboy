#!/usr/bin/env bash
# Renders the same random PPU states with the current ppu.sh and with the
# ppu.sh from a reference commit. Fails unless every frame hash matches.
#
# Usage: bash tests/test_render_equiv.sh [cases] [reference_commit]
#   cases             number of random states (default 30)
#   reference_commit  commit whose ashboy/ppu.sh is the reference (default df8f3bf)
#
# Each side is a full copy of ashboy/ in its own temporary folder. The
# reference side differs only in ppu.sh. Each side runs from its own folder,
# the same way tests/test_skip_equivalence.sh runs.

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CASES=${1:-30}
REF=${2:-df8f3bf}
LIB="$ROOT/tests/render_cases.sh"
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

[[ $CASES =~ ^[0-9]+$ ]] && (( CASES > 0 )) || fail "cases must be a positive number"
[[ -f $LIB ]] || fail "missing $LIB"
[[ -f $ROOT/ashboy/gameboy.sh ]] || fail "missing $ROOT/ashboy/gameboy.sh"

# make_side LABEL PPU_SOURCE
# Builds $TMP/LABEL/ashboy as a copy of the working tree, with PPU_SOURCE as its ppu.sh.
make_side() {
    local label=$1 ppu=$2
    mkdir -p "$TMP/$label" || return 1
    cp -r "$ROOT/ashboy" "$TMP/$label/ashboy" || return 1
    cp "$ppu" "$TMP/$label/ashboy/ppu.sh" || return 1
}

make_side new "$ROOT/ashboy/ppu.sh" || fail "cannot copy the working tree"

git -C "$ROOT" show "$REF:ashboy/ppu.sh" > "$TMP/ref_ppu.sh" 2>/dev/null \
    || fail "cannot read $REF:ashboy/ppu.sh"
make_side ref "$TMP/ref_ppu.sh" || fail "cannot build the reference side"

# run_side LABEL OUT_FILE ERR_FILE
# Runs in the side's folder. Checks that every function the cases need is
# defined before any case runs.
run_side() {
    local label=$1 out=$2 err=$3
    (
        cd "$TMP/$label" || exit 1
        bash -c '
            set -u
            source ashboy/gameboy.sh
            for f in gameboy_init mmu_write8 mmu_read8 ppu_init ppu_render_scanline; do
                declare -F "$f" >/dev/null || { echo "not defined after loading gameboy.sh: $f" >&2; exit 3; }
            done
            gameboy_init
            source "$1"
            render_cases_run "$2"
        ' _ "$LIB" "$CASES"
    ) > "$out" 2> "$err"
}

run_side new "$TMP/new.out" "$TMP/new.err"; st_new=$?
run_side ref "$TMP/ref.out" "$TMP/ref.err"; st_ref=$?

# check_side LABEL STATUS OUT_FILE ERR_FILE
check_side() {
    local label=$1 status=$2 out=$3 err=$4 n
    if (( status != 0 )) || [[ -s $err ]]; then
        printf 'FAIL: %s side (exit %s). First stderr lines:\n' "$label" "$status"
        head -n 5 "$err"
        exit 1
    fi
    n=$(grep -c '^case ' "$out")
    [[ $n == "$CASES" ]] || fail "$label side printed $n cases, expected $CASES"
}

check_side new "$st_new" "$TMP/new.out" "$TMP/new.err"
check_side ref "$st_ref" "$TMP/ref.out" "$TMP/ref.err"

grep -q '^renderer ppu_fb_flat=1$' "$TMP/new.out" \
    || fail "current side did not load the current ppu.sh"

if ! diff <(grep -v '^renderer ' "$TMP/new.out") \
          <(grep -v '^renderer ' "$TMP/ref.out") > "$TMP/diff.txt"; then
    head -n 20 "$TMP/diff.txt"
    fail "frame hashes differ from $REF"
fi

cov=$(grep '^coverage ' "$TMP/new.out")
if [[ $cov =~ window_lines=([0-9]+)[[:space:]]sprite_lines=([0-9]+) ]]; then
    win=${BASH_REMATCH[1]}
    spr=${BASH_REMATCH[2]}
else
    fail "no coverage line in output"
fi
(( win > 0 )) || fail "no window lines covered"
(( spr > 0 )) || fail "no sprite lines covered"

printf 'PASS: %d random cases identical to %s (coverage window_lines=%s sprite_lines=%s)\n' \
    "$CASES" "$REF" "$win" "$spr"