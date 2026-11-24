#!/usr/bin/env bash
# AshBoy shared constants & helpers 

[[ -n "${_ASHBOY_INIT_SH:-}" ]] && return 0
readonly _ASHBOY_INIT_SH=1

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    printf 'Error: AshBoy requires Bash 4.3 or newer (found %s).\n' "$BASH_VERSION" >&2
    exit 1
fi

readonly INT_VBLANK=1
readonly INT_STAT=2
readonly INT_TIMER=4
readonly INT_SERIAL=8
readonly INT_JOYPAD=16

readonly FLAG_Z=128
readonly FLAG_N=64
readonly FLAG_H=32
readonly FLAG_C=16

readonly DMG_CLOCK_HZ=4194304
readonly CYCLES_PER_SCANLINE=456
readonly SCANLINES_PER_FRAME=154
readonly CYCLES_PER_FRAME=70224

declare -gi REPLY=0

# Precomputed Flag Lookup Tables 
# Pre-calculating 8-bit INC and DEC flag transitions saves millions of runtime comparisons
declare -ga LUT_INC_FLAGS=()
declare -ga LUT_DEC_FLAGS=()

_init_flag_luts() {
    local i res h
    for (( i = 0; i < 256; i++ )); do
        # INC flags: Z, H (N=0, C preserved)
        (( res = (i + 1) & 0xFF ))
        (( h = ((i & 0x0F) == 0x0F) ? FLAG_H : 0 ))
        (( LUT_INC_FLAGS[i] = (res == 0 ? FLAG_Z : 0) | h ))

        # DEC flags: Z, N=1, H (C preserved)
        (( res = (i - 1) & 0xFF ))
        (( h = ((i & 0x0F) == 0x00) ? FLAG_H : 0 ))
        (( LUT_DEC_FLAGS[i] = FLAG_N | (res == 0 ? FLAG_Z : 0) | h ))
    done
}
_init_flag_luts