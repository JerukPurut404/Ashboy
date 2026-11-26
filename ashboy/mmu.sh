#!/usr/bin/env bash
# AshBoy: Memory Management Unit (MMU / Address Bus)

[[ -n "${_ASHBOY_MMU_SH:-}" ]] && return 0
readonly _ASHBOY_MMU_SH=1

_MMU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_MMU_DIR/init.sh"
source "$_MMU_DIR/cartridge.sh"
source "$_MMU_DIR/joypad.sh"
source "$_MMU_DIR/timer.sh"
source "$_MMU_DIR/ppu.sh"

declare -ga MMU_WRAM=()
declare -ga MMU_HRAM=()
declare -ga MMU_IO=()
declare -gi _MMU_OFF=0

declare -gi MMU_IF=0xE1
declare -gi MMU_IE=0x00
declare -gi MMU_SB=0x00
declare -gi MMU_SC=0x7E
declare -g  SERIAL_OUTPUT=""
declare -gi SERIAL_STDOUT=0

mmu_init() {
    local i
    for (( i = 0; i < 8192; i++ )); do MMU_WRAM[i]=0; done
    for (( i = 0; i < 128; i++ )); do MMU_HRAM[i]=0; done
    for (( i = 0; i < 128; i++ )); do MMU_IO[i]=0xFF; done

    MMU_IF=0xE1
    MMU_IE=0x00
    MMU_SB=0x00
    MMU_SC=0x7E
    SERIAL_OUTPUT=""
}

mmu_read8() {
    # Hot paths first: Work RAM and High RAM are used by most instructions.
    if (( $1 >= 49152 && $1 < 57344 )); then
        (( REPLY = ${MMU_WRAM[$1 - 49152]:-0} ))
        return
    fi
    if (( $1 >= 65408 && $1 < 65535 )); then
        (( REPLY = ${MMU_HRAM[$1 - 65408]:-0} ))
        return
    fi
    # 1. Ultra Fast-Path: Bank 0 ROM (0x0000-0x3FFF)
    if (( $1 < 16384 )); then
        (( REPLY = ${CART_ROM[$1]:-0} ))
        return
    fi

    # 2. Fast-Path: Bank 1..N ROM (0x4000-0x7FFF)
    if (( $1 < 32768 )); then
        (( _MMU_OFF = (CART_ROM_BANK % CART_ROM_BANKS) * 16384 + $1 - 16384 ))
        (( REPLY = ${CART_ROM[_MMU_OFF % CART_ROM_SIZE]:-0} ))
        return
    fi

    # 3. Fast-Path: Work RAM (0xC000-0xDFFF)
    if (( $1 >= 49152 && $1 < 57344 )); then
        (( REPLY = ${MMU_WRAM[$1 - 49152]:-0} ))
        return
    fi

    # 4. Video RAM (0x8000-0x9FFF)
    if (( $1 < 40960 )); then
        (( REPLY = ${PPU_VRAM[$1 - 32768]:-0} ))
        return
    fi

    # 5. External Cartridge RAM (0xA000-0xBFFF)
    if (( $1 < 49152 )); then
        cartridge_read_ram "$1"
        return
    fi

    # 6. Echo RAM (0xE000-0xFDFF)
    if (( $1 < 65024 )); then
        (( REPLY = ${MMU_WRAM[$1 - 57344]:-0} ))
        return
    fi

    # 7. OAM (0xFE00-0xFE9F)
    if (( $1 < 65184 )); then
        (( REPLY = ${PPU_OAM[$1 - 65024]:-0} ))
        return
    fi

    # 8. Unusable space
    if (( $1 < 65280 )); then
        REPLY=255
        return
    fi

    # 9. I/O Registers (0xFF00-0xFF7F)
    if (( $1 < 65408 )); then
        case $1 in
            65280) joypad_read ;;
            65281) (( REPLY = MMU_SB )) ;;
            65282) (( REPLY = MMU_SC | 0x7E )) ;;
            65284) (( REPLY = TIMER_DIV )) ;;
            65285) (( REPLY = TIMER_TIMA )) ;;
            65286) (( REPLY = TIMER_TMA )) ;;
            65287) (( REPLY = TIMER_TAC | 0xF8 )) ;;
            65295) (( REPLY = MMU_IF | 0xE0 )) ;;
            65344) (( REPLY = PPU_LCDC )) ;;
            65345) (( REPLY = PPU_STAT | 0x80 )) ;;
            65346) (( REPLY = PPU_SCY )) ;;
            65347) (( REPLY = PPU_SCX )) ;;
            65348) (( REPLY = PPU_LY )) ;;
            65349) (( REPLY = PPU_LYC )) ;;
            65351) (( REPLY = PPU_BGP )) ;;
            65352) (( REPLY = PPU_OBP0 )) ;;
            65353) (( REPLY = PPU_OBP1 )) ;;
            65354) (( REPLY = PPU_WY )) ;;
            65355) (( REPLY = PPU_WX )) ;;
            *)     (( REPLY = ${MMU_IO[$1 - 65280]:-255} )) ;;
        esac
        return
    fi

    # 10. High RAM (0xFF80-0xFFFE) & Interrupt Enable (0xFFFF)
    if (( $1 < 65535 )); then
        (( REPLY = ${MMU_HRAM[$1 - 65408]:-0} ))
    else
        (( REPLY = MMU_IE ))
    fi
}

mmu_write8() {
    if (( $1 >= 49152 && $1 < 57344 )); then
        (( MMU_WRAM[$1 - 49152] = $2 & 0xFF ))
        return
    fi

    if (( $1 >= 65408 && $1 < 65535 )); then
        (( MMU_HRAM[$1 - 65408] = $2 & 0xFF ))
        return
    fi
    
    if (( $1 < 32768 )); then
        cartridge_write_rom "$1" "$2"
        return
    fi

    if (( $1 >= 49152 && $1 < 57344 )); then
        (( MMU_WRAM[$1 - 49152] = $2 & 0xFF ))
        return
    fi

    if (( $1 < 40960 )); then
        if (( ${PPU_VRAM[$1 - 32768]:-0} != ($2 & 0xFF) )); then
            (( PPU_VRAM[$1 - 32768] = $2 & 0xFF ))
            (( PPU_VRAM_GEN++ ))
        fi
        return
    fi

    if (( $1 < 49152 )); then
        cartridge_write_ram "$1" "$2"
        return
    fi

    if (( $1 < 65024 )); then
        (( MMU_WRAM[$1 - 57344] = $2 & 0xFF ))
        return
    fi

    if (( $1 < 65184 )); then
        (( PPU_OAM[$1 - 65024] = $2 & 0xFF ))
        return
    fi

    if (( $1 < 65280 )); then
        return
    fi

    if (( $1 < 65408 )); then
        case $1 in
            65280) joypad_write "$2" ;;
            65281) (( MMU_SB = $2 & 0xFF )) ;;
            65282)
                (( MMU_SC = $2 & 0xFF ))
                if (( ($2 & 0x81) == 0x81 )); then
                    local chr
                    printf -v chr "\\$(printf '%03o' "$MMU_SB")"
                    SERIAL_OUTPUT+="$chr"
                    (( SERIAL_STDOUT )) && printf '%s' "$chr"
                    (( MMU_SC &= 0x7F ))
                    (( MMU_IF |= INT_SERIAL ))
                fi
                ;;
            65284) TIMER_DIV=0; TIMER_DIV_CYCLES=0 ;;
            65285) (( TIMER_TIMA = $2 & 0xFF )) ;;
            65286) (( TIMER_TMA = $2 & 0xFF )) ;;
            65287) (( TIMER_TAC = $2 & 0x07 )) ;;
            65295) (( MMU_IF = $2 & 0x1F )) ;;
            65344)
                local was_on=$(( PPU_LCDC & 0x80 ))
                (( PPU_LCDC = $2 & 0xFF ))
                if (( was_on && ($2 & 0x80) == 0 )); then
                    PPU_DOTS=0; PPU_LY=0; PPU_MODE=0
                    (( PPU_STAT &= 0xFC ))
                fi
                ;;
            65345) (( PPU_STAT = ($2 & 0x78) | (PPU_STAT & 0x07) )) ;;
            65346) (( PPU_SCY = $2 & 0xFF )) ;;
            65347) (( PPU_SCX = $2 & 0xFF )) ;;
            65348) : ;;
            65349) (( PPU_LYC = $2 & 0xFF )); ppu_check_lyc ;;
            65350) # OAM DMA
                local src_base=$(( ($2 & 0xFF) << 8 )) i
                for (( i = 0; i < 160; i++ )); do
                    mmu_read8 $(( src_base + i ))
                    (( PPU_OAM[i] = REPLY ))
                done
                ;;
            65351) (( PPU_BGP = $2 & 0xFF )) ;;
            65352) (( PPU_OBP0 = $2 & 0xFF )) ;;
            65353) (( PPU_OBP1 = $2 & 0xFF )) ;;
            65354) (( PPU_WY = $2 & 0xFF )) ;;
            65355) (( PPU_WX = $2 & 0xFF )) ;;
            *)     (( MMU_IO[$1 - 65280] = $2 & 0xFF )) ;;
        esac
        return
    fi

    if (( $1 < 65535 )); then
        (( MMU_HRAM[$1 - 65408] = $2 & 0xFF ))
    else
        (( MMU_IE = $2 & 0x1F ))
    fi
}

mmu_read16() {
    local lo hi
    mmu_read8 "$1";         lo=$REPLY
    mmu_read8 $(( $1 + 1 )); hi=$REPLY
    (( REPLY = (hi << 8) | lo ))
}

mmu_write16() {
    mmu_write8 "$1"         $(( $2 & 0xFF ))
    mmu_write8 $(( $1 + 1 )) $(( ($2 >> 8) & 0xFF ))
}