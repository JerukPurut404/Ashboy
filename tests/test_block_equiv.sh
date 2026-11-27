#!/usr/bin/env bash
# test_block_equiv.sh - randomized check of the block-copy fast path.
#
# Each trial starts from one random state (registers, WRAM, HRAM, VRAM), with
# the copy loop placed in bank 0 at 0x2100. The reference spends the cycle
# budget by plain instruction stepping. The fast side calls loopskip_try first,
# then steps whatever is left. The full state text and the cycles used must be
# identical.
#
# Usage: bash tests/test_block_equiv.sh [trials] [seed]
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
TRIALS=${1:-200}
SEED=${2:-12345}
RANDOM=$SEED
cd "$ROOT" || exit 1
source ashboy/gameboy.sh || { echo "FAIL: cannot load ashboy/gameboy.sh"; exit 1; }

GB_BLOCK_COPY=1
CART_ROM_SIZE=32768
CART_ROM_BANKS=2
CART_ROM_BANK=1
gameboy_init
# Names of the state that must match. GB_COPY_PASSES is left out on purpose:
# only the fast side increments it.
mapfile -t STATE_VARS < <(compgen -v | grep -E '^(CPU_|MMU_|TIMER_|PPU_VRAM|GB_STEPS$)' | grep -v '^TIMER_PERIODS$')

dump_state() {
    declare -p "${STATE_VARS[@]}" 2>/dev/null
}

# Runs the budget. $2 = 1 tries the fast path first, 0 is pure stepping.
run_steps() {
    local budget=$1 cum=0
    LAST_FAST=0
    if (( $2 == 1 )); then
        if loopskip_try "$budget"; then
            cum=$_CPU_CYCLES
            LAST_FAST=1
        fi
    fi
    while (( cum < budget )); do
        gameboy_step
        cum=$(( cum + _CPU_CYCLES ))
    done
    RUN_CUM=$cum
}

setup_trial() {
    local i lo hi dest src
    for (( i = 0; i < 8192; i++ )); do
        MMU_WRAM[i]=$(( RANDOM & 0xFF ))
        PPU_VRAM[i]=$(( RANDOM & 0xFF ))
    done
    for (( i = 0; i < 127; i++ )); do
        MMU_HRAM[i]=$(( RANDOM & 0xFF ))
    done
    for (( i = 0; i < 8; i++ )); do
        CART_ROM[0x2100 + i]=$(( COPY_SHAPE[i] ))
    done
    # BC is sometimes tiny, so the BC cap is exercised.
    if (( RANDOM % 4 == 0 )); then
        CPU_B=0
        CPU_C=$(( RANDOM % 4 ))
    else
        CPU_B=$(( RANDOM & 0xFF ))
        CPU_C=$(( RANDOM & 0xFF ))
    fi
    # DE sometimes sits near the region end, so the region cap is exercised.
    case $(( RANDOM % 3 )) in
        0) lo=0xC000; hi=0xDFFF ;;
        1) lo=0x8000; hi=0x9FFF ;;
        *) lo=0xFF80; hi=0xFFFE ;;
    esac
    if (( RANDOM % 4 == 0 )); then
        dest=$(( hi - RANDOM % 6 ))
    else
        dest=$(( lo + RANDOM % (hi - lo + 1) ))
    fi
    CPU_D=$(( dest >> 8 ))
    CPU_E=$(( dest & 0xFF ))
    src=$(( 0xC000 + RANDOM % 0x1E00 ))
    CPU_H=$(( src >> 8 ))
    CPU_L=$(( src & 0xFF ))
    CPU_A=$(( RANDOM & 0xFF ))
    CPU_F=$(( RANDOM & 0xF0 ))
    CPU_PC=$(( 0x2100 ))
    CPU_SP=$(( 0xFFFE ))
    CPU_HALTED=0
    CPU_HALT_BUG=0
    CPU_IME_DELAY=0
    MMU_IE=0
    MMU_IF=0
    TIMER_TAC=$(( 0xF8 ))
}

FAIL=0
FAST_HITS=0
for (( t = 1; t <= TRIALS; t++ )); do
    setup_trial
    BUDGET=$(( 1 + RANDOM % 456 ))
    BASE=$(dump_state)

    run_steps "$BUDGET" 0
    REF_STATE=$(dump_state)
    REF_CUM=$RUN_CUM

    eval "$BASE"                 # restore the random start state (top level)
    run_steps "$BUDGET" 1
    FAST_HITS=$(( FAST_HITS + LAST_FAST ))
    FAST_STATE=$(dump_state)
    FAST_CUM=$RUN_CUM

    if [[ $REF_STATE != "$FAST_STATE" ]] || (( REF_CUM != FAST_CUM )); then
        FAIL=$(( FAIL + 1 ))
        if (( FAIL <= 5 )); then
            echo "FAIL trial $t: budget=$BUDGET ref_cycles=$REF_CUM fast_cycles=$FAST_CUM"
        fi
    fi
done

echo "trials=$TRIALS seed=$SEED fast_path_hits=$FAST_HITS copy_passes=$GB_COPY_PASSES fails=$FAIL"
if (( FAIL == 0 && FAST_HITS > 0 )); then
    echo "PASS: fast path matches stepping in every trial"
    exit 0
fi
echo "FAIL"
exit 1