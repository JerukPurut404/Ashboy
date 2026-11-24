#!/usr/bin/env bash
# AshBoy timer (DIV/TIMA/TMA/TAC)
# Job: advance the internal cycle counters and request INT_TIMER on TIMA overflow

[[ -n "${_ASHBOY_TIMER_SH:-}" ]] && return 0
readonly _ASHBOY_TIMER_SH=1

_TIMER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_TIMER_DIR/init.sh"

declare -gi TIMER_DIV=0xAB
declare -gi TIMER_TIMA=0x00
declare -gi TIMER_TMA=0x00
declare -gi TIMER_TAC=0xF8
declare -gi TIMER_DIV_CYCLES=0
declare -gi TIMER_TIMA_CYCLES=0
declare -gi _TIMER_PERIOD=0

readonly -a TIMER_PERIODS=(1024 16 64 256)

timer_init() {
    TIMER_DIV=0xAB
    TIMER_TIMA=0x00
    TIMER_TMA=0x00
    TIMER_TAC=0xF8
    TIMER_DIV_CYCLES=0
    TIMER_TIMA_CYCLES=0
}

# $1 = T-cycles elapsed
timer_tick() {
    # DIV: +1 every 256 cycles (the counter may cross more than once per call)
    (( TIMER_DIV_CYCLES += $1 ))
    if (( TIMER_DIV_CYCLES >= 256 )); then
        (( TIMER_DIV = (TIMER_DIV + (TIMER_DIV_CYCLES >> 8)) & 0xFF,
           TIMER_DIV_CYCLES &= 0xFF ))
    fi

    # TIMA: runs only when TAC bit 2 (enable) is set
    if (( TIMER_TAC & 4 )); then
        (( TIMER_TIMA_CYCLES += $1 ))
        (( _TIMER_PERIOD = TIMER_PERIODS[TIMER_TAC & 3] ))
        while (( TIMER_TIMA_CYCLES >= _TIMER_PERIOD )); do
            (( TIMER_TIMA_CYCLES -= _TIMER_PERIOD, TIMER_TIMA++ ))
            if (( TIMER_TIMA > 0xFF )); then
                (( TIMER_TIMA = TIMER_TMA, MMU_IF |= INT_TIMER ))
            fi
        done
    fi
}