#!/usr/bin/env bash
# AshBoy Cartridge & MBC chip

[[ -n "${_ASHBOY_CARTRIDGE_SH:-}" ]] && return 0
readonly _ASHBOY_CARTRIDGE_SH=1

_CART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CART_DIR/init.sh"

declare -ga CART_ROM=()
declare -ga CART_RAM=()
declare -gi CART_ROM_SIZE=0
declare -gi CART_MBC_TYPE=0
declare -gi CART_HAS_BATTERY=0
declare -gi CART_ROM_BANK=1
declare -gi CART_RAM_BANK=0
declare -gi CART_RAM_ENABLED=0
declare -gi CART_BANKING_MODE=0
declare -gi CART_ROM_BANKS=2
declare -gi CART_RAM_SIZE=8192
declare -g  CART_TITLE=""
declare -g  CART_SAV_PATH=""

cartridge_load() {
    local rom_path="$1"
    if [[ ! -f "$rom_path" ]]; then
        printf 'Error: ROM file not found: %s\n' "$rom_path" >&2
        return 1
    fi

    read -r -d '' -a CART_ROM < <(od -An -tu1 -v "$rom_path" && printf '\0')
    CART_ROM_SIZE=${#CART_ROM[@]}

    if (( CART_ROM_SIZE < 32768 )); then
        printf 'Error: Invalid ROM size (%d bytes).\n' "$CART_ROM_SIZE" >&2
        return 1
    fi

    CART_TITLE=""
    local addr byte
    for (( addr = 0x0134; addr <= 0x0143; addr++ )); do
        (( byte = ${CART_ROM[addr]:-0} ))
        (( byte == 0 )) && break
        if (( byte >= 32 && byte <= 126 )); then
            printf -v chr "\\$(printf '%03o' "$byte")"
            CART_TITLE+="$chr"
        fi
    done

    (( CART_MBC_TYPE = ${CART_ROM[0x0147]:-0} ))
    local hex_mbc
    printf -v hex_mbc '0x%02X' "$CART_MBC_TYPE"
    case $hex_mbc in
        0x03|0x06|0x09|0x0D|0x0F|0x10|0x13|0x1B|0x1E) CART_HAS_BATTERY=1 ;;
        *) CART_HAS_BATTERY=0 ;;
    esac

    local rom_code=${CART_ROM[0x0148]:-0}
    (( CART_ROM_BANKS = (2 << rom_code) ))
    (( CART_ROM_BANKS < 2 )) && CART_ROM_BANKS=2

    local ram_code=${CART_ROM[0x0149]:-0}
    case $ram_code in
        0) CART_RAM_SIZE=0 ;;
        1) CART_RAM_SIZE=2048 ;;
        2) CART_RAM_SIZE=8192 ;;
        3) CART_RAM_SIZE=32768 ;;
        4) CART_RAM_SIZE=131072 ;;
        5) CART_RAM_SIZE=65536 ;;
        *) CART_RAM_SIZE=8192 ;;
    esac

    CART_RAM=()
    local i
    for (( i = 0; i < (CART_RAM_SIZE > 0 ? CART_RAM_SIZE : 8192); i++ )); do
        CART_RAM[i]=0
    done

    CART_ROM_BANK=1
    CART_RAM_BANK=0
    CART_RAM_ENABLED=0
    CART_BANKING_MODE=0
    CART_SAV_PATH="${rom_path%.*}.sav"

    if (( CART_HAS_BATTERY && CART_RAM_SIZE > 0 )) && [[ -f "$CART_SAV_PATH" ]]; then
        read -r -d '' -a CART_RAM < <(od -An -tu1 -v "$CART_SAV_PATH" && printf '\0')
    fi
}

cartridge_save_ram() {
    (( !CART_HAS_BATTERY || CART_RAM_SIZE == 0 )) && return 0
    local i fmt=""
    for (( i = 0; i < CART_RAM_SIZE; i++ )); do
        printf -v hex '\\x%02x' "${CART_RAM[i]:-0}"
        fmt+="$hex"
    done
    printf "$fmt" > "$CART_SAV_PATH"
}

cartridge_read_rom() {
    local addr=$1
    if (( addr < 0x4000 )); then
        (( REPLY = ${CART_ROM[addr]:-0} ))
    else
        local bank=$(( CART_ROM_BANK % CART_ROM_BANKS ))
        local offset=$(( (bank * 0x4000) + (addr - 0x4000) ))
        (( REPLY = ${CART_ROM[offset % CART_ROM_SIZE]:-0} ))
    fi
}

cartridge_write_rom() {
    local addr=$1 val=$2
    if (( addr < 0x2000 )); then
        (( CART_RAM_ENABLED = ((val & 0x0F) == 0x0A) ? 1 : 0 ))
    elif (( addr < 0x4000 )); then
        if (( CART_MBC_TYPE >= 0x0F && CART_MBC_TYPE <= 0x13 )); then
            (( CART_ROM_BANK = val & 0x7F ))
        else
            (( CART_ROM_BANK = (CART_ROM_BANK & 0x60) | (val & 0x1F) ))
        fi
        (( CART_ROM_BANK == 0 )) && CART_ROM_BANK=1
    elif (( addr < 0x6000 )); then
        if (( CART_MBC_TYPE >= 0x0F && CART_MBC_TYPE <= 0x13 )); then
            (( CART_RAM_BANK = val & 0x03 ))
        elif (( CART_BANKING_MODE == 0 )); then
            (( CART_ROM_BANK = (CART_ROM_BANK & 0x1F) | ((val & 0x03) << 5) ))
            (( CART_ROM_BANK == 0 )) && CART_ROM_BANK=1
        else
            (( CART_RAM_BANK = val & 0x03 ))
        fi
    else
        (( CART_BANKING_MODE = val & 0x01 ))
    fi
}

cartridge_read_ram() {
    local addr=$1
    if (( !CART_RAM_ENABLED || CART_RAM_SIZE == 0 )); then
        REPLY=255
        return
    fi
    local offset=$(( (CART_RAM_BANK * 0x2000) + (addr - 0xA000) ))
    (( REPLY = ${CART_RAM[offset]:-255} ))
}

cartridge_write_ram() {
    local addr=$1 val=$2
    if (( !CART_RAM_ENABLED || CART_RAM_SIZE == 0 )); then
        return
    fi
    local offset=$(( (CART_RAM_BANK * 0x2000) + (addr - 0xA000) ))
    (( CART_RAM[offset] = val & 0xFF ))
}