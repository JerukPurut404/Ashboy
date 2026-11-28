#!/usr/bin/env bash
# test_sprite_priority.sh - direct check of the sprite drawing order.
#
# Renders one scanline with the background off, so only sprites are visible.
# Tile 1 is shade 1 everywhere, tile 2 is shade 3 everywhere (OBP0 = 0xE4).
# Each case runs in hardware mode (GB_SPRITE_HW=1: smaller X on top, equal X
# earlier OAM entry on top) and in OAM mode (GB_SPRITE_HW=0: later entry on top).
# No ROM is needed.
#
# Usage: bash tests/test_sprite_priority.sh
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1
source ashboy/gameboy.sh || { echo "FAIL: cannot load ashboy/gameboy.sh"; exit 1; }
declare -p GB_SPRITE_HW >/dev/null 2>&1 || { echo "FAIL: GB_SPRITE_HW is not defined in ppu.sh"; exit 1; }
gameboy_init

PASSES=0
FAILS=0
# check NAME EXPECTED ACTUAL
check() {
    if [[ $2 == "$3" ]]; then
        PASSES=$(( PASSES + 1 ))
    else
        FAILS=$(( FAILS + 1 ))
        echo "FAIL: $1 (expected $2, got $3)"
    fi
}

T_LY=10
# Tile 1: colour 1 in every pixel. Tile 2: colour 3 in every pixel.
for (( r = 0; r < 8; r++ )); do
    PPU_VRAM[16 + r * 2]=255; PPU_VRAM[17 + r * 2]=0
    PPU_VRAM[32 + r * 2]=255; PPU_VRAM[33 + r * 2]=255
done
# VRAM was written directly, not through mmu_write8, so mark it changed.
PPU_VRAM_GEN=$(( PPU_VRAM_GEN + 1 ))
PPU_OBP0=$(( 0xE4 ))    # colour c -> shade c
PPU_LCDC=$(( 0x82 ))    # LCD on, sprites on, 8x8 sprites, background and window off

clear_oam() {
    local i
    for (( i = 0; i < 160; i++ )); do PPU_OAM[i]=0; done
}
# put_sprite ENTRY SCREEN_X TILE  (top row of the sprite on line T_LY)
put_sprite() {
    local b=$(( $1 * 4 ))
    PPU_OAM[b]=$(( T_LY + 16 ))
    PPU_OAM[b + 1]=$(( $2 + 8 ))
    PPU_OAM[b + 2]=$3
    PPU_OAM[b + 3]=0
}
render() {
    PPU_LY=$T_LY
    ppu_render_scanline
    ROW=${PPU_FRAMEBUFFER[T_LY]}
}

# Baseline: no sprites, so every pixel is the background shade.
clear_oam
render
check "row length" 160 "${#ROW}"
BG=${ROW:0:1}

for mode in 1 0; do
    GB_SPRITE_HW=$mode
    if (( mode )); then name=hw; top1=3; top2=3; else name=oam; top1=1; top2=1; fi

    # Case 1: smaller X in the earlier entry. Overlap is x = 20..23.
    clear_oam; put_sprite 0 16 2; put_sprite 1 20 1; render
    check "$name case 1 overlap x=21" "$top1" "${ROW:21:1}"
    check "$name case 1 left only x=17" 3 "${ROW:17:1}"
    check "$name case 1 right only x=26" 1 "${ROW:26:1}"

    # Case 2: equal X.
    clear_oam; put_sprite 0 16 2; put_sprite 1 16 1; render
    check "$name case 2 equal X x=19" "$top2" "${ROW:19:1}"

    # Case 3: smaller X in the later entry. Both modes put entry 1 on top.
    clear_oam; put_sprite 0 20 1; put_sprite 1 16 2; render
    check "$name case 3 overlap x=21" 3 "${ROW:21:1}"

    # Case 4: 11 sprites on the line. Selection is OAM order, so entry 10
    # (smallest X) is not drawn in either mode.
    clear_oam
    for (( e = 0; e < 10; e++ )); do put_sprite "$e" 100 1; done
    put_sprite 10 0 2
    render
    check "$name case 4 eleventh sprite hidden x=0" "$BG" "${ROW:0:1}"
    check "$name case 4 first ten drawn x=101" 1 "${ROW:101:1}"
done

echo "checks=$(( PASSES + FAILS )) passed=$PASSES failed=$FAILS"
if (( FAILS == 0 )); then
    echo "PASS: sprite drawing order is correct in both modes"
    exit 0
fi
echo "FAIL"
exit 1
