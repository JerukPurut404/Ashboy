#!/usr/bin/env bash
# AshBoy Picture Processing Unit (PPU)
# Job: step scanline timing (Modes 2->3->0->1), render background, window and
#      sprites into a 160x144 framebuffer, and blit it to the terminal with
#      ANSI half-blocks.
#
# Framebuffer layout: PPU_FRAMEBUFFER[y] is one string of 160 shade digits
# ('0'-'3'), one digit per pixel. Lines are built from cached 8-pixel tile
# rows, so pixels are not written one at a time. ppu_fb_flat produces the
# older flat layout (23040 space-separated digits) for hashing.
[[ -n "${_ASHBOY_PPU_SH:-}" ]] && return 0
readonly _ASHBOY_PPU_SH=1
_PPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PPU_DIR/init.sh"


# Segment cache. A stored result is reused only while no VRAM byte has changed
# (PPU_VRAM_GEN). Its key holds every other input: the arguments and PPU_BGP.
# GB_SEG_CACHE=0 turns the cache off, so a run with and without it can be compared.
declare -gi PPU_VRAM_GEN=${PPU_VRAM_GEN:-0}
declare -gi SEG_CACHE_GEN=-1
declare -gi GB_SEG_CACHE=${GB_SEG_CACHE:-1}
# GB_SPRITE_ORDER=oam draws sprites in OAM order, the old behaviour. The default
# (any other value, or unset) uses the hardware rule: smaller X on top, and on
# equal X the earlier OAM entry on top.
declare -gi GB_SPRITE_HW=1
if [[ ${GB_SPRITE_ORDER:-hw} == oam ]]; then
    GB_SPRITE_HW=0
fi
# Scratch list of selected sprites, sorted in draw order. Rebuilt for each line.
declare -ga _PPU_SPR_ORD=()
declare -gA SEG_SHADE_CACHE=() SEG_COL_CACHE=()

declare -ga PPU_VRAM=()
declare -ga PPU_OAM=()
declare -ga PPU_FRAMEBUFFER=()     # 144 rows of 160 shade digits
declare -g  PPU_ZERO_ROW=""        # 160 x '0', shared by blank lines
declare -gi PPU_LCDC=0x91
declare -gi PPU_STAT=0x85
declare -gi PPU_SCY=0x00
declare -gi PPU_SCX=0x00
declare -gi PPU_LY=0x00
declare -gi PPU_LYC=0x00
declare -gi PPU_BGP=0xFC
declare -gi PPU_OBP0=0xFF
declare -gi PPU_OBP1=0xFF
declare -gi PPU_WY=0x00
declare -gi PPU_WX=0x00
declare -gi PPU_DOTS=0
declare -gi PPU_MODE=2
declare -gi PPU_WIN_LINE=0

# Shade for each colour index (0-3), set once per line from BGP.
declare -ga _PPU_SHADE=(0 0 0 0)

# Caches. A tile row depends only on its bytes (and BGP for shades), so
# entries never go stale.
#   PPU_COL_CACHE:   key (lo<<8)|hi            -> 8 colour-index digits
#   PPU_SHADE_CACHE: key (BGP<<16)|(lo<<8)|hi  -> 8 shade digits
declare -gA PPU_COL_CACHE=()
declare -gA PPU_SHADE_CACHE=()

# Results of ppu_fetch_segment (global so no subshell or copy is needed).
declare -g _PPU_SEG_SHADE=""
declare -g _PPU_SEG_COL=""

# Precomputed 4x4 ANSI colour half-block LUT (16 combinations)
declare -ga DMG_LUT=(
    $'\e[38;2;155;188;15m\e[48;2;155;188;15m▀'
    $'\e[38;2;155;188;15m\e[48;2;139;172;15m▀'
    $'\e[38;2;155;188;15m\e[48;2;48;98;48m▀'
    $'\e[38;2;155;188;15m\e[48;2;15;56;15m▀'
    $'\e[38;2;139;172;15m\e[48;2;155;188;15m▀'
    $'\e[38;2;139;172;15m\e[48;2;139;172;15m▀'
    $'\e[38;2;139;172;15m\e[48;2;48;98;48m▀'
    $'\e[38;2;139;172;15m\e[48;2;15;56;15m▀'
    $'\e[38;2;48;98;48m\e[48;2;155;188;15m▀'
    $'\e[38;2;48;98;48m\e[48;2;139;172;15m▀'
    $'\e[38;2;48;98;48m\e[48;2;48;98;48m▀'
    $'\e[38;2;48;98;48m\e[48;2;15;56;15m▀'
    $'\e[38;2;15;56;15m\e[48;2;155;188;15m▀'
    $'\e[38;2;15;56;15m\e[48;2;139;172;15m▀'
    $'\e[38;2;15;56;15m\e[48;2;48;98;48m▀'
    $'\e[38;2;15;56;15m\e[48;2;15;56;15m▀'
)

ppu_init() {
    local i
    for (( i = 0; i < 8192; i++ )); do PPU_VRAM[i]=0; done
    (( PPU_VRAM_GEN++ ))
    for (( i = 0; i < 160; i++ )); do PPU_OAM[i]=0; done
    printf -v PPU_ZERO_ROW '%160s' ''
    PPU_ZERO_ROW=${PPU_ZERO_ROW// /0}
    for (( i = 0; i < 144; i++ )); do PPU_FRAMEBUFFER[i]=$PPU_ZERO_ROW; done
    PPU_LCDC=0x91; PPU_STAT=0x85
    PPU_SCY=0;     PPU_SCX=0
    PPU_LY=0;      PPU_LYC=0
    PPU_BGP=0xFC;  PPU_OBP0=0xFF; PPU_OBP1=0xFF
    PPU_WY=0;      PPU_WX=0
    PPU_DOTS=0;    PPU_MODE=2
    PPU_WIN_LINE=0
}

ppu_check_lyc() {
    if (( PPU_LY == PPU_LYC )); then
        (( PPU_STAT |= 0x04 ))
        if (( PPU_STAT & 0x40 )); then
            (( MMU_IF |= INT_STAT ))
        fi
    else
        (( PPU_STAT &= ~0x04 ))
    fi
}

ppu_set_mode() {
    (( PPU_MODE = $1 ))
    (( PPU_STAT = (PPU_STAT & 0xFC) | PPU_MODE ))
    if (( (PPU_MODE == 0 && (PPU_STAT & 0x08)) ||
          (PPU_MODE == 1 && (PPU_STAT & 0x10)) ||
          (PPU_MODE == 2 && (PPU_STAT & 0x20)) )); then
        (( MMU_IF |= INT_STAT ))
    fi
}

# Fill both caches for one 8-pixel tile row. Pixel 0 is the leftmost, which is
# bit 7 of each byte. Uses _PPU_SHADE, so it must be set for the current BGP.
ppu_build_tile_row() {
    local lo=$1 hi=$2 key=$3 skey=$4 p bit c col="" shd=""
    for (( p = 0; p < 8; p++ )); do
        bit=$(( 7 - p ))
        c=$(( ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1) ))
        col+=$c
        shd+=${_PPU_SHADE[c]}
    done
    PPU_COL_CACHE[$key]=$col
    PPU_SHADE_CACHE[$skey]=$shd
}

# Build ntiles tile rows (8 pixels each) from a tile map, starting at tile
# column first_col (wrapped at 32). Arguments:
#   map_base    VRAM address of the map (0x1800 or 0x1C00)
#   row_off     map row times 32
#   first_col   first tile column
#   fine        pixel row times 2 (byte offset inside a tile)
#   ntiles      number of tiles
#   use_unsigned 1 for unsigned tile numbers (0x8000 mode), 0 for signed
# Results: _PPU_SEG_SHADE and _PPU_SEG_COL, ntiles*8 characters each.
# Splits one segment of ntiles tiles into shade and colour strings.
# Arguments: map_base, row_off, first_col, fine, ntiles, use_unsigned.
# Results: _PPU_SEG_SHADE and _PPU_SEG_COL, ntiles*8 characters each.
ppu_fetch_segment() {
    local map_base=$1 row_off=$2 first_col=$3 fine=$4 ntiles=$5 use_unsigned=$6
    local tc tile_num tile_addr signed_num lo hi key skey ckey

    if (( GB_SEG_CACHE )); then
        # Any VRAM change since the cache was built empties it. The size limit
        # keeps memory bounded if scrolling creates many distinct keys.
        if (( SEG_CACHE_GEN != PPU_VRAM_GEN || ${#SEG_SHADE_CACHE[@]} > 4096 )); then
            SEG_SHADE_CACHE=()
            SEG_COL_CACHE=()
            SEG_CACHE_GEN=$PPU_VRAM_GEN
        fi
        ckey="$map_base:$row_off:$first_col:$fine:$ntiles:$use_unsigned:$PPU_BGP"
        if [[ -n ${SEG_SHADE_CACHE[$ckey]+x} ]]; then
            _PPU_SEG_SHADE=${SEG_SHADE_CACHE[$ckey]}
            _PPU_SEG_COL=${SEG_COL_CACHE[$ckey]}
            return 0
        fi
    fi

    _PPU_SEG_SHADE=""
    _PPU_SEG_COL=""
    for (( tc = 0; tc < ntiles; tc++ )); do
        tile_num=${PPU_VRAM[map_base + row_off + ((first_col + tc) & 31)]:-0}
        if (( use_unsigned )); then
            tile_addr=$(( tile_num * 16 ))
        else
            signed_num=$(( (tile_num & 0x80) ? (tile_num - 256) : tile_num ))
            tile_addr=$(( 0x1000 + signed_num * 16 ))
        fi
        lo=${PPU_VRAM[tile_addr + fine]:-0}
        hi=${PPU_VRAM[tile_addr + fine + 1]:-0}
        key=$(( (lo << 8) | hi ))
        skey=$(( (PPU_BGP << 16) | key ))
        if [[ -z ${PPU_SHADE_CACHE[$skey]+x} ]]; then
            ppu_build_tile_row "$lo" "$hi" "$key" "$skey"
        fi
        _PPU_SEG_SHADE+=${PPU_SHADE_CACHE[$skey]}
        _PPU_SEG_COL+=${PPU_COL_CACHE[$key]}
    done

    if (( GB_SEG_CACHE )); then
        SEG_SHADE_CACHE[$ckey]=$_PPU_SEG_SHADE
        SEG_COL_CACHE[$ckey]=$_PPU_SEG_COL
    fi
}

# Render scanline PPU_LY into PPU_FRAMEBUFFER[PPU_LY].
ppu_render_scanline() {
    local ly=$PPU_LY lcdc=$PPU_LCDC
    local unsigned_tiles bg_map win_map win_enabled
    local y_bg tile_row_bg fine_y_bg fx tcol0 start wx0
    local bg_shade bg_col line idx row s0
    local sprite_height sprites_on_line i sy sx tile attr line_no t_addr lo hi
    local sort_key v j n_ord q step
    local pal bg_prio px out_x bit c_idx
    local x0 x1 k old seg

    # LCD off: the line is blank (shade 0) and nothing else is drawn
    if (( (lcdc & 0x80) == 0 )); then
        PPU_FRAMEBUFFER[ly]=$PPU_ZERO_ROW
        return 0
    fi

    unsigned_tiles=$(( (lcdc & 0x10) ? 1 : 0 ))
    bg_map=$(( (lcdc & 0x08) ? 0x1C00 : 0x1800 ))
    win_map=$(( (lcdc & 0x40) ? 0x1C00 : 0x1800 ))
    win_enabled=$(( ((lcdc & 0x20) && ly >= PPU_WY && PPU_WX <= 166) ? 1 : 0 ))

    # Colour index -> shade for this line's palette
    _PPU_SHADE[0]=$(( PPU_BGP & 3 ))
    _PPU_SHADE[1]=$(( (PPU_BGP >> 2) & 3 ))
    _PPU_SHADE[2]=$(( (PPU_BGP >> 4) & 3 ))
    _PPU_SHADE[3]=$(( (PPU_BGP >> 6) & 3 ))

    fx=$(( PPU_SCX & 7 ))
    tcol0=$(( PPU_SCX >> 3 ))
    y_bg=$(( (ly + PPU_SCY) & 0xFF ))
    tile_row_bg=$(( (y_bg >> 3) * 32 ))
    fine_y_bg=$(( (y_bg & 7) * 2 ))

    if (( (lcdc & 0x01) == 0 )); then
        # Background disabled: colour 0 everywhere, and no window
        s0=${_PPU_SHADE[0]}
        printf -v row '%160s' ''
        line=${row// /$s0}
        idx=$PPU_ZERO_ROW
    elif (( win_enabled )); then
        # Window line. Background tiles fill x < start, where start = max(0, WX-7).
        # Window tiles fill the rest. The window segment starts at tile column 0,
        # so the first window pixel is at offset wx0 = start - (WX-7) in it.
        # Every window line advances the window line counter.
        ppu_fetch_segment "$bg_map" "$tile_row_bg" "$tcol0" "$fine_y_bg" 21 "$unsigned_tiles"
        bg_shade=$_PPU_SEG_SHADE
        bg_col=$_PPU_SEG_COL

        start=$(( PPU_WX - 7 ))
        (( start < 0 )) && start=0
        wx0=$(( start - (PPU_WX - 7) ))
        ppu_fetch_segment "$win_map" "$(( (PPU_WIN_LINE >> 3) * 32 ))" 0 \
            "$(( (PPU_WIN_LINE & 7) * 2 ))" 21 "$unsigned_tiles"

        line=${bg_shade:fx:start}${_PPU_SEG_SHADE:wx0:160-start}
        idx=${bg_col:fx:start}${_PPU_SEG_COL:wx0:160-start}
        (( PPU_WIN_LINE++ ))
    else
        # Background line. Segment pixel 0 is at screen x = -fx.
        ppu_fetch_segment "$bg_map" "$tile_row_bg" "$tcol0" "$fine_y_bg" 21 "$unsigned_tiles"
        line=${_PPU_SEG_SHADE:fx:160}
        idx=${_PPU_SEG_COL:fx:160}
    fi

    # Sprites: at most 10 per line, selected in OAM order as the hardware does.
    # Colour 0 is transparent. With the priority attribute set, a sprite pixel
    # is hidden unless the background colour index there is 0.
    # idx holds the background colour indexes, and sprites never change it.
    # Each sprite row is built as one 8-pixel string and spliced in once.
    # Where two sprites overlap, the one drawn last is on top. The default
    # (GB_SPRITE_HW=1) is the hardware rule: smaller X is on top, and on equal
    # X the earlier OAM entry is on top. GB_SPRITE_ORDER=oam draws in OAM order.
    if (( lcdc & 0x02 )); then
        sprite_height=$(( (lcdc & 0x04) ? 16 : 8 ))
        sprites_on_line=0
        _PPU_SPR_ORD=()
        for (( i = 0; i < 160; i += 4 )); do
            sy=$(( ${PPU_OAM[i]:-0} - 16 ))
            if (( ly < sy || ly >= sy + sprite_height )); then
                continue
            fi
            (( ++sprites_on_line > 10 )) && break
            # Sort key: X then OAM entry (hardware), or OAM entry only (oam).
            # The low 8 bits of v hold the OAM byte offset i.
            if (( GB_SPRITE_HW )); then
                sort_key=$(( ${PPU_OAM[i + 1]:-0} * 64 + i / 4 ))
            else
                sort_key=0
            fi
            v=$(( (sort_key << 8) | i ))
            # Insertion sort, ascending by v. At most 10 entries.
            (( j = ${#_PPU_SPR_ORD[@]} ))
            while (( j > 0 && _PPU_SPR_ORD[j - 1] > v )); do
                _PPU_SPR_ORD[j]=${_PPU_SPR_ORD[j - 1]}
                (( j-- ))
            done
            _PPU_SPR_ORD[j]=$v
        done
        n_ord=${#_PPU_SPR_ORD[@]}
        # Hardware: the sorted list runs from top priority down, so draw it
        # from the end. OAM mode: sorted by OAM entry, so draw from the start.
        if (( GB_SPRITE_HW )); then
            q=$(( n_ord - 1 )); step=-1
        else
            q=0; step=1
        fi
        for (( ; q >= 0 && q < n_ord; q += step )); do
            i=$(( _PPU_SPR_ORD[q] & 0xFF ))
            sy=$(( ${PPU_OAM[i]:-0} - 16 ))
            sx=$(( ${PPU_OAM[i + 1]:-0} - 8 ))
            tile=${PPU_OAM[i + 2]:-0}
            attr=${PPU_OAM[i + 3]:-0}
            line_no=$(( ly - sy ))
            (( attr & 0x40 )) && (( line_no = sprite_height - 1 - line_no ))
            (( sprite_height == 16 )) && (( tile &= 0xFE ))
            t_addr=$(( tile * 16 + line_no * 2 ))
            lo=${PPU_VRAM[t_addr]:-0}
            hi=${PPU_VRAM[t_addr + 1]:-0}
            pal=$(( (attr & 0x10) ? PPU_OBP1 : PPU_OBP0 ))
            bg_prio=$(( (attr & 0x80) ? 1 : 0 ))
            # Visible part of the sprite row, clipped to the screen
            x0=$(( sx < 0 ? 0 : sx ))
            x1=$(( sx + 8 > 160 ? 160 : sx + 8 ))
            if (( x1 <= x0 )); then
                continue
            fi
            old=${line:x0:x1-x0}
            seg=""
            for (( out_x = x0; out_x < x1; out_x++ )); do
                px=$(( out_x - sx ))
                k=$(( out_x - x0 ))
                bit=$(( (attr & 0x20) ? px : (7 - px) ))
                c_idx=$(( (((hi >> bit) & 1) << 1) | ((lo >> bit) & 1) ))
                if (( c_idx == 0 || (bg_prio && ${idx:out_x:1} != 0) )); then
                    seg+=${old:k:1}
                else
                    seg+=$(( (pal >> (c_idx * 2)) & 3 ))
                fi
            done
            line=${line:0:x0}$seg${line:x1}
        done
    fi
    PPU_FRAMEBUFFER[ly]=$line
    return 0
}

# Flat layout for hashing: 23040 space-separated shade digits, row by row. The
# result is in REPLY, so the same hash input works for this and older builds.
PPU_FLAT=""
ppu_fb_flat() {
    local IFS=' ' y x row
    local -a flat=()
    for (( y = 0; y < 144; y++ )); do
        row=${PPU_FRAMEBUFFER[y]}
        for (( x = 0; x < 160; x++ )); do
            flat+=("${row:x:1}")
        done
    done
    PPU_FLAT="${flat[*]}"
}


# Build the whole frame in one string and write it with one printf.
ppu_present_ansi() {
    local scale=${1:-1}
    local step_x=$(( scale <= 1 ? 2 : 1 ))
    local step_y=$(( scale <= 1 ? 4 : 2 ))
    local half_y=$(( step_y / 2 ))
    local out=$'\e[H'
    local y x top bot tc bc
    for (( y = 0; y < 144; y += step_y )); do
        top=${PPU_FRAMEBUFFER[y]}
        bot=${PPU_FRAMEBUFFER[y + half_y]}
        for (( x = 0; x < 160; x += step_x )); do
            tc=${top:x:1}
            bc=${bot:x:1}
            out+=${DMG_LUT[tc * 4 + bc]}
        done
        out+=$'\e[0m\n'
    done
    out+=" [AshBoy] ${CART_TITLE:-ROM} | ${HUD_TEXT:-}"$'\e[K'
    printf '%s' "$out"
}