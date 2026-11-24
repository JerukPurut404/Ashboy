#!/usr/bin/env bash
# ashboy/gameboy.sh: System coordinator: instruction, scanline and frame stepping

[[ -n "${_ASHBOY_GAMEBOY_SH:-}" ]] && return 0
readonly _ASHBOY_GAMEBOY_SH=1

_GB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_GB_DIR/init.sh"
source "$_GB_DIR/cartridge.sh"
source "$_GB_DIR/timer.sh"
source "$_GB_DIR/joypad.sh"
source "$_GB_DIR/ppu.sh"
source "$_GB_DIR/mmu.sh"
source "$_GB_DIR/interrupts.sh"
source "$_GB_DIR/cpu.sh"

# Set by main.sh before each frame: 1 = draw scanlines, 0 = skip drawing
RENDER_THIS_FRAME=1
declare -gi PPU_FRAME_COUNT=${PPU_FRAME_COUNT:-0}
declare -gi GB_STEPS=0

# Scratch globals
_GB_LY=0
_GB_CYC=0
_GB_LINE=0

gameboy_init() {
    cpu_init
    mmu_init
    timer_init
    joypad_init
    ppu_init
}

gameboy_load_rom() {
    cartridge_load "$1"
}

# Execute one unit of work and advance the timer by its cycle count.
# The unit is one of: an interrupt dispatch, one HALT idle slice, or one instruction.
gameboy_step() {
    (( ++GB_STEPS ))
    # One arithmetic test decides whether interrupts_service is needed.
    # Most steps have nothing pending, so the function call is skipped.
    if (( (MMU_IE & MMU_IF & 0x1F) != 0 )) && interrupts_service; then
        :                               # dispatched: _CPU_CYCLES is 20
    elif (( CPU_HALTED )); then
        _CPU_CYCLES=4                   # idle until an interrupt arrives
    else
        cpu_step
    fi
    (( _CPU_CYCLES > 0 )) || (( _CPU_CYCLES = 4 ))
    timer_tick "$_CPU_CYCLES"
}

# Run one scanline (456 T-cycles)
gameboy_step_scanline() {
    _GB_LY=$PPU_LY
    _GB_CYC=0

    while (( _GB_CYC < 456 )); do
        # Idle fast-path: halted with nothing that can wake the CPU,
        # so skip the rest of the scanline in one timer step.
        if (( CPU_HALTED && ((MMU_IE & MMU_IF & 0x1F) == 0) )); then
            timer_tick $(( 456 - _GB_CYC ))
            (( _GB_CYC = 456 ))
            break
        fi

        gameboy_step
        (( _GB_CYC += _CPU_CYCLES ))
    done

    if (( _GB_LY < 144 )); then
        if (( RENDER_THIS_FRAME )); then
            ppu_render_scanline "$_GB_LY"
        fi
    elif (( _GB_LY == 144 )); then
        (( MMU_IF |= 1 ))               # V-Blank interrupt request
    fi

    (( PPU_LY = (_GB_LY + 1) % 154 ))
    MMU_IO[68]=$PPU_LY                  # 0xFF44 = LY
}

# Run one full frame (154 scanlines = 70,224 T-cycles)
gameboy_step_frame() {
    for (( _GB_LINE = 0; _GB_LINE < 154; _GB_LINE++ )); do
        gameboy_step_scanline
    done
    (( PPU_FRAME_COUNT++ ))
}