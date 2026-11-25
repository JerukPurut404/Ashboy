#!/usr/bin/env bash
# AshBoy Picture Processing Unit (PPU) 
# Job: Step scanline timing (Modes 2->3->0->1), render BG/Window/Sprites into
#      a 160x144 framebuffer, and blit to the terminal using ANSI half-blocks.

[[ -n "${_ASHBOY_PPU_SH:-}" ]] && return 0
readonly _ASHBOY_PPU_SH=1

_PPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_PPU_DIR/init.sh"

declare -ga PPU_VRAM=()
declare -ga PPU_OAM=()
declare -ga PPU_FRAMEBUFFER=()
declare -ga PPU_BG_COLOR_IDX=()

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
declare -gi PPU_FRAME_READY=0

# Precomputed 4x4 ANSI color half-block LUT (16 combinations)
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
    for (( i = 0; i < 160; i++ )); do PPU_OAM[i]=0; done
    for (( i = 0; i < 23040; i++ )); do PPU_FRAMEBUFFER[i]=0; done
    for (( i = 0; i < 160; i++ )); do PPU_BG_COLOR_IDX[i]=0; done

    PPU_LCDC=0x91; PPU_STAT=0x85
    PPU_SCY=0;     PPU_SCX=0
    PPU_LY=0;      PPU_LYC=0
    PPU_BGP=0xFC;  PPU_OBP0=0xFF; PPU_OBP1=0xFF
    PPU_WY=0;      PPU_WX=0
    PPU_DOTS=0;    PPU_MODE=2
    PPU_WIN_LINE=0; PPU_FRAME_READY=0
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

ppu_render_scanline() {
    # All locals are declared once here. 'local' inside loops costs a builtin
    # call per iteration.
    local ly=$PPU_LY
    local row_offset=$(( ly * 160 ))
    local x p px tc tcol bit c lo hi tile_num tile_addr signed_num
    local unsigned_tiles bg_map win_map win_enabled win_used
    local y_bg tile_row_bg fine_y_bg fx tcol0
    local map_base tile_row tile_col fine_y wx_rel color_idx
    local sprite_height sprites_on_line i sy sx tile attr
    local line t_addr pal bg_prio out_x c_idx

    # LCD off: blank the line to colour 0
    if (( (PPU_LCDC & 0x80) == 0 )); then
        for (( x = 0; x < 160; x++ )); do
            PPU_FRAMEBUFFER[row_offset + x]=0
        done
        return
    fi

    unsigned_tiles=$(( (PPU_LCDC & 0x10) ? 1 : 0 ))
    bg_map=$(( (PPU_LCDC & 0x08) ? 0x1C00 : 0x1800 ))
    win_map=$(( (PPU_LCDC & 0x40) ? 0x1C00 : 0x1800 ))
    win_enabled=$(( ((PPU_LCDC & 0x20) && ly >= PPU_WY && PPU_WX <= 166) ? 1 : 0 ))
    win_used=0

    # Colour index -> shade, computed once per line instead of per pixel
    _PPU_SHADE[0]=$(( PPU_BGP & 3 ))
    _PPU_SHADE[1]=$(( (PPU_BGP >> 2) & 3 ))
    _PPU_SHADE[2]=$(( (PPU_BGP >> 4) & 3 ))
    _PPU_SHADE[3]=$(( (PPU_BGP >> 6) & 3 ))

    y_bg=$(( (ly + PPU_SCY) & 0xFF ))
    tile_row_bg=$(( (y_bg >> 3) * 32 ))
    fine_y_bg=$(( (y_bg & 7) * 2 ))

    # 1. Background & Window
    if (( (PPU_LCDC & 0x01) == 0 )); then
        # Background disabled: every pixel is colour 0
        for (( x = 0; x < 160; x++ )); do
            PPU_BG_COLOR_IDX[x]=0
            PPU_FRAMEBUFFER[row_offset + x]=${_PPU_SHADE[0]}
        done

    elif (( win_enabled )); then
        # Window line: per-pixel path, because the window can start mid-line
        for (( x = 0; x < 160; x++ )); do
            map_base=$bg_map
            tile_row=$tile_row_bg
            tile_col=$(( ((x + PPU_SCX) & 0xFF) >> 3 ))
            fine_y=$fine_y_bg
            bit=$(( 7 - ((x + PPU_SCX) & 7) ))

            if (( x >= (PPU_WX - 7) )); then
                win_used=1
                wx_rel=$(( x - (PPU_WX - 7) ))
                map_base=$win_map
                tile_row=$(( (PPU_WIN_LINE >> 3) * 32 ))
                tile_col=$(( wx_rel >> 3 ))
                fine_y=$(( (PPU_WIN_LINE & 7) * 2 ))
                bit=$(( 7 - (wx_rel & 7) ))
            fi

            tile_num=${PPU_VRAM[map_base + tile_row + tile_col]:-0}
            if (( unsigned_tiles )); then
                tile_addr=$(( tile_num * 16 ))
            else
                signed_num=$(( (tile_num & 0x80) ? (tile_num - 256) : tile_num ))
                tile_addr=$(( 0x1000 + signed_num * 16 ))
            fi
            lo=${PPU_VRAM[tile_addr + fine_y]:-0}
            hi=${PPU_VRAM[tile_addr + fine_y + 1]:-0}
            color_idx=$(( ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1) ))
            PPU_BG_COLOR_IDX[x]=$color_idx
            PPU_FRAMEBUFFER[row_offset + x]=${_PPU_SHADE[color_idx]}
        done
        (( win_used )) && (( PPU_WIN_LINE++ ))

    else
        # Background line: one fetch per 8-pixel tile.
        # Tile column tc covers pixels x = tc*8 + px - fx, where fx = SCX & 7.
        fx=$(( PPU_SCX & 7 ))
        tcol0=$(( PPU_SCX >> 3 ))
        for (( tc = 0; tc < 21; tc++ )); do
            tcol=$(( (tcol0 + tc) & 31 ))
            tile_num=${PPU_VRAM[bg_map + tile_row_bg + tcol]:-0}
            if (( unsigned_tiles )); then
                tile_addr=$(( tile_num * 16 ))
            else
                signed_num=$(( (tile_num & 0x80) ? (tile_num - 256) : tile_num ))
                tile_addr=$(( 0x1000 + signed_num * 16 ))
            fi
            lo=${PPU_VRAM[tile_addr + fine_y_bg]:-0}
            hi=${PPU_VRAM[tile_addr + fine_y_bg + 1]:-0}
            for (( px = 0; px < 8; px++ )); do
                x=$(( tc * 8 + px - fx ))
                (( x < 0 || x >= 160 )) && continue
                bit=$(( 7 - px ))
                c=$(( ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1) ))
                PPU_BG_COLOR_IDX[x]=$c
                PPU_FRAMEBUFFER[row_offset + x]=${_PPU_SHADE[c]}
            done
        done
    fi

    # 2. Sprites (unchanged logic)
    if (( PPU_LCDC & 0x02 )); then
        sprite_height=$(( (PPU_LCDC & 0x04) ? 16 : 8 ))
        sprites_on_line=0
        for (( i = 0; i < 160; i += 4 )); do
            sy=$(( ${PPU_OAM[i]:-0} - 16 ))
            sx=$(( ${PPU_OAM[i + 1]:-0} - 8 ))
            tile=${PPU_OAM[i + 2]:-0}
            attr=${PPU_OAM[i + 3]:-0}

            if (( ly >= sy && ly < sy + sprite_height )); then
                (( sprites_on_line++ ))
                (( sprites_on_line > 10 )) && break

                line=$(( ly - sy ))
                (( attr & 0x40 )) && (( line = sprite_height - 1 - line ))
                (( sprite_height == 16 )) && (( tile &= 0xFE ))

                t_addr=$(( (tile * 16) + (line * 2) ))
                lo=${PPU_VRAM[t_addr]:-0}
                hi=${PPU_VRAM[t_addr + 1]:-0}
                pal=$(( (attr & 0x10) ? PPU_OBP1 : PPU_OBP0 ))
                bg_prio=$(( (attr & 0x80) ? 1 : 0 ))

                for (( px = 0; px < 8; px++ )); do
                    out_x=$(( sx + px ))
                    (( out_x < 0 || out_x >= 160 )) && continue
                    bit=$(( (attr & 0x20) ? px : (7 - px) ))
                    c_idx=$(( ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1) ))
                    (( c_idx == 0 )) && continue
                    if (( !bg_prio || PPU_BG_COLOR_IDX[out_x] == 0 )); then
                        PPU_FRAMEBUFFER[row_offset + out_x]=$(( (pal >> (c_idx * 2)) & 0x03 ))
                    fi
                done
            fi
        done
    fi
}

ppu_tick() {
    local cycles=$1

    if (( (PPU_LCDC & 0x80) == 0 )); then
        PPU_DOTS=0; PPU_LY=0; PPU_WIN_LINE=0
        (( PPU_STAT &= 0xFC ))
        return
    fi

    (( PPU_DOTS += cycles ))

    case $PPU_MODE in
        2) # Mode 2: OAM Scan
            if (( PPU_DOTS >= 80 )); then
                (( PPU_DOTS -= 80 ))
                ppu_set_mode 3
            fi
            ;;
        3) # Mode 3: Pixel Drawing
            if (( PPU_DOTS >= 172 )); then
                (( PPU_DOTS -= 172 ))
                if (( GB_SKIP_RENDER == 0 )); then
                    ppu_render_scanline
                fi
                ppu_set_mode 0
            fi
            ;;
        0) # Mode 0: H-Blank
            if (( PPU_DOTS >= 204 )); then
                (( PPU_DOTS -= 204 ))
                (( PPU_LY++ ))
                ppu_check_lyc
                if (( PPU_LY == 144 )); then
                    ppu_set_mode 1
                    PPU_FRAME_READY=1
                    (( MMU_IF |= INT_VBLANK ))
                else
                    ppu_set_mode 2
                fi
            fi
            ;;
        1) # Mode 1: V-Blank
            if (( PPU_DOTS >= 456 )); then
                (( PPU_DOTS -= 456 ))
                (( PPU_LY++ ))
                if (( PPU_LY > 153 )); then
                    PPU_LY=0
                    PPU_WIN_LINE=0
                    ppu_check_lyc
                    ppu_set_mode 2
                else
                    ppu_check_lyc
                fi
            fi
            ;;
    esac
}

# Single atomic printf call: Pre-buffers the frame into $out and writes in one syscall
ppu_present_ansi() {
    local scale=${1:-1}
    local step_x=$(( scale <= 1 ? 2 : 1 ))
    local step_y=$(( scale <= 1 ? 4 : 2 ))
    local half_y=$(( step_y / 2 ))

    local out=$'\e[H'
    local y x
    for (( y = 0; y < 144; y += step_y )); do
        local r_top=$(( y * 160 ))
        local r_bot=$(( (y + half_y) * 160 ))
        for (( x = 0; x < 160; x += step_x )); do
            out+="${DMG_LUT[PPU_FRAMEBUFFER[r_top + x] * 4 + PPU_FRAMEBUFFER[r_bot + x]]}"
        done
        out+=$'\e[0m\n'
    done
    out+=" [AshBoy] ${CART_TITLE:-ROM} | ${HUD_TEXT:-}"$'\e[K'
    printf '%s' "$out"
}