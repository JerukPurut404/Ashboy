#!/usr/bin/env bash
# Equivalence check for the loop skip. Does not name any game.
# Runs one ROM twice, with GB_SKIP=0 and GB_SKIP=1, and compares the CPU
# registers, I/O state, RAM, VRAM, OAM and framebuffer.
# Fails if the skip never fired, so a PASS always means the skip was tested.
#
# Usage (from the folder that contains ashboy/):
#   bash tests/test_skip_equivalence.sh "ROMs/game.gb" [frames]

ROM=${1:-}
FRAMES=${2:-60}
[[ -n $ROM && -f $ROM ]] || { echo "usage: $0 ROM.gb [frames]" >&2; exit 2; }

# Prints the full state after FRAMES frames. $1 is the GB_SKIP value.
state() {
    GB_SKIP=$1 _ROM=$ROM _FRAMES=$FRAMES bash -c '
        source ashboy/gameboy.sh
        gameboy_init
        gameboy_load_rom "$_ROM" || exit 1
        (( CART_ROM_SIZE > 0 )) || { echo "ROM not loaded" >&2; exit 1; }
        for (( f = 0; f < _FRAMES; f++ )); do gameboy_step_frame; done
        printf "regs A=%s F=%s B=%s C=%s D=%s E=%s H=%s L=%s SP=%s PC=%s IME=%s HALT=%s\n" \
            "$CPU_A" "$CPU_F" "$CPU_B" "$CPU_C" "$CPU_D" "$CPU_E" \
            "$CPU_H" "$CPU_L" "$CPU_SP" "$CPU_PC" "$CPU_IME" "$CPU_HALTED"
        printf "io IE=%s IF=%s LY=%s steps=%s\n" "$MMU_IE" "$MMU_IF" "$PPU_LY" "$GB_STEPS"
        printf "mem %s\n"  "$(printf "%s|%s|%s" "${MMU_WRAM[*]}" "${MMU_HRAM[*]}" "${MMU_IO[*]}" | md5sum)"
        printf "vram %s\n" "$(printf "%s|%s" "${PPU_VRAM[*]}" "${PPU_OAM[*]}" | md5sum)"
        printf "fb %s\n"   "$(printf "%s" "${PPU_FRAMEBUFFER[*]}" | md5sum)"
        printf "passes %s\n" "$GB_SKIP_PASSES"
    '
}

off=$(state 0) || exit 1
on=$(state 1)  || exit 1

# The pass count differs by design, so it is compared separately.
same_off=$(grep -v '^passes' <<< "$off")
same_on=$(grep -v '^passes' <<< "$on")
passes=$(sed -n 's/^passes //p' <<< "$on")
passes=${passes:-0}

if [[ $same_off != "$same_on" ]]; then
    echo "FAIL: state differs between GB_SKIP=0 and GB_SKIP=1"
    diff <(echo "$same_off") <(echo "$same_on")
    exit 1
fi
if (( passes == 0 )); then
    echo "FAIL: the skip never fired, so nothing was tested"
    exit 1
fi
echo "$same_on"
echo "PASS: identical state after $FRAMES frames; the skip fired $passes times"
