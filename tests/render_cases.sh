#!/usr/bin/env bash
# Random PPU states for comparing renderer versions.
# This is a library: tests/test_render_equiv.sh sources it after gameboy.sh
# and gameboy_init. Every state goes through the normal memory bus
# (mmu_write8), so the same states reach any renderer version without
# depending on its internal arrays. Coverage is counted from the values
# written here.

declare -gi RC_WIN_LINES=0 RC_SPR_LINES=0
declare -ga _RC_OY=() _RC_OX=()
declare -gi _RC_LCDC=0 _RC_WY=0 _RC_WX=0

# render_case_setup CASE
# Builds one random PPU state. Even cases force the window and background
# on, so the window path is always exercised. Odd cases are fully random.
render_case_setup() {
    local seed=$1 addr i y x a lcdc

    RANDOM=$seed
    ppu_init
    PPU_WIN_LINE=0

    # Tile data 0x8000-0x97FF: about half the bytes are zero, so tile rows repeat.
    for (( addr = 0x8000; addr < 0x9800; addr++ )); do
        if (( RANDOM & 1 )); then
            mmu_write8 "$addr" $(( RANDOM & 255 ))
        else
            mmu_write8 "$addr" 0
        fi
    done

    # Both tile maps 0x9800-0x9FFF: random tile numbers.
    for (( addr = 0x9800; addr < 0xA000; addr++ )); do
        mmu_write8 "$addr" $(( RANDOM & 255 ))
    done

    # OAM 0xFE00-0xFE9F: 40 sprites with Y and X in 0..175.
    for (( i = 0; i < 40; i++ )); do
        y=$(( RANDOM % 176 ))
        x=$(( RANDOM % 176 ))
        _RC_OY[i]=$y
        _RC_OX[i]=$x
        a=$(( 0xFE00 + i * 4 ))
        mmu_write8 "$a" "$y"
        mmu_write8 $(( a + 1 )) "$x"
        mmu_write8 $(( a + 2 )) $(( RANDOM & 255 ))
        mmu_write8 $(( a + 3 )) $(( RANDOM & 255 ))
    done

    # Registers. LCD is always on, so the LCD-off path is not covered here.
    lcdc=$(( (RANDOM & 0xFF) | 0x80 ))
    if (( seed % 2 == 0 )); then
        lcdc=$(( lcdc | 0x21 ))     # bit 5 window on, bit 0 background on
    fi
    _RC_LCDC=$lcdc
    _RC_WY=$(( RANDOM % 144 ))
    _RC_WX=$(( RANDOM % 167 ))

    mmu_write8 $(( 0xFF40 )) "$lcdc"                  # LCDC
    mmu_write8 $(( 0xFF42 )) $(( RANDOM & 255 ))      # SCY
    mmu_write8 $(( 0xFF43 )) $(( RANDOM & 255 ))      # SCX
    mmu_write8 $(( 0xFF47 )) $(( RANDOM & 255 ))      # BGP
    mmu_write8 $(( 0xFF48 )) $(( RANDOM & 255 ))      # OBP0
    mmu_write8 $(( 0xFF49 )) $(( RANDOM & 255 ))      # OBP1
    mmu_write8 $(( 0xFF4A )) "$_RC_WY"                # WY
    mmu_write8 $(( 0xFF4B )) "$_RC_WX"                # WX
}

# render_case_coverage
# Adds this state's window lines and sprite lines to the running totals.
render_case_coverage() {
    local ln i top h hit win_on=0

    if (( (_RC_LCDC & 0x20) && (_RC_LCDC & 0x01) )); then
        win_on=1
    fi
    h=8
    if (( _RC_LCDC & 0x04 )); then
        h=16
    fi

    for (( ln = 0; ln < 144; ln++ )); do
        if (( win_on && ln >= _RC_WY && _RC_WX <= 166 )); then
            RC_WIN_LINES=$(( RC_WIN_LINES + 1 ))
        fi
        hit=0
        for (( i = 0; i < 40; i++ )); do
            top=$(( _RC_OY[i] - 16 ))
            if (( ln >= top && ln < top + h && _RC_OX[i] > 0 && _RC_OX[i] < 168 )); then
                hit=1
                break
            fi
        done
        RC_SPR_LINES=$(( RC_SPR_LINES + hit ))
    done
}

# render_case_hash
# MD5 of the 23040-cell frame in the flat layout used by the frame hashes.
# Uses ppu_fb_flat when the renderer defines it, otherwise the flat array.
render_case_hash() {
    local s
    if declare -F ppu_fb_flat >/dev/null; then
        ppu_fb_flat
        s=$PPU_FLAT
    else
        s="${PPU_FRAMEBUFFER[*]}"
    fi
    printf '%s' "$s" | md5sum | cut -d' ' -f1
}

# render_cases_run COUNT
# Renders 144 lines for each random state and prints one hash per state,
# then the coverage totals and which renderer layout was loaded.
render_cases_run() {
    local count=$1 c ln

    RC_WIN_LINES=0
    RC_SPR_LINES=0
    for (( c = 0; c < count; c++ )); do
        render_case_setup "$c"
        render_case_coverage
        for (( ln = 0; ln < 144; ln++ )); do
            PPU_LY=$ln
            ppu_render_scanline
        done
        printf 'case %d %s\n' "$c" "$(render_case_hash)"
    done

    printf 'coverage window_lines=%d sprite_lines=%d\n' "$RC_WIN_LINES" "$RC_SPR_LINES"
    if declare -F ppu_fb_flat >/dev/null; then
        printf 'renderer ppu_fb_flat=1\n'
    else
        printf 'renderer ppu_fb_flat=0\n'
    fi
}