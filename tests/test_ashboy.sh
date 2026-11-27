#!/usr/bin/env bash
# AshBoy Unit & Integration Test Suite 
# Run with: bash tests/test_ashboy.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/ashboy/init.sh"
source "$SCRIPT_DIR/ashboy/cartridge.sh"
source "$SCRIPT_DIR/ashboy/timer.sh"
source "$SCRIPT_DIR/ashboy/joypad.sh"
source "$SCRIPT_DIR/ashboy/ppu.sh"
source "$SCRIPT_DIR/ashboy/mmu.sh"
source "$SCRIPT_DIR/ashboy/cpu.sh"
source "$SCRIPT_DIR/ashboy/gameboy.sh"

declare -gi TESTS_RUN=0
declare -gi TESTS_FAILED=0

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    (( TESTS_RUN++ ))
    if [[ "$expected" != "$actual" ]]; then
        (( TESTS_FAILED++ ))
        printf '  [FAIL] %s: expected %s, got %s\n' "$msg" "$expected" "$actual"
    else
        printf '  [PASS] %s\n' "$msg"
    fi
}

setup_blank_rom() {
    gameboy_init ""
    CART_ROM=()
    local i
    for (( i = 0; i < 32768; i++ )); do CART_ROM[i]=0; done
    CART_ROM_SIZE=32768
    CART_ROM_BANKS=2
    CART_MBC_TYPE=0
}

test_cpu_alu_and_flags() {
    printf 'Running test_cpu_alu_and_flags...\n'
    setup_blank_rom

    # Program at 0x0100:
    # LD A, 0x0F (3E 0F) -> ADD A, 0x01 (C6 01) -> SUB 0x10 (D6 10)
    CART_ROM[0x0100]=0x3E; CART_ROM[0x0101]=0x0F
    CART_ROM[0x0102]=0xC6; CART_ROM[0x0103]=0x01
    CART_ROM[0x0104]=0xD6; CART_ROM[0x0105]=0x10

    cpu_step # LD A, 0x0F
    assert_eq 15 "$CPU_A" "LD A, 0x0F loads 15"

    cpu_step # ADD A, 0x01 -> 0x10 with Half-Carry (H) set
    assert_eq 16 "$CPU_A" "ADD A, 0x01 equals 16"
    assert_eq "$FLAG_H" "$CPU_F" "Half-carry flag set on 0x0F + 0x01"

    cpu_step # SUB 0x10 -> 0x00 with Zero (Z) and Subtract (N) set
    assert_eq 0 "$CPU_A" "SUB 0x10 equals 0"
    assert_eq $(( FLAG_Z | FLAG_N )) "$CPU_F" "Z and N flags set on zero result"
}

test_cb_prefix_and_stack() {
    printf 'Running test_cb_prefix_and_stack...\n'
    setup_blank_rom

    # LD B, 0x85 (06 85) -> CB SWAP B (CB 30) -> PUSH BC (C5) -> POP AF (F1)
    CART_ROM[0x0100]=0x06; CART_ROM[0x0101]=0x85
    CART_ROM[0x0102]=0xCB; CART_ROM[0x0103]=0x30
    CART_ROM[0x0104]=0xC5
    CART_ROM[0x0105]=0xF1

    CPU_C=0xFF
    cpu_step # LD B, 0x85
    cpu_step # SWAP B -> 0x58
    assert_eq $(( 0x58 )) "$CPU_B" "CB SWAP B swaps nibbles 0x85 -> 0x58"

    cpu_step # PUSH BC (0x58FF)
    cpu_step # POP AF -> A=0x58, F=0xF0 (low nibble masked!)
    assert_eq $(( 0x58 )) "$CPU_A" "POP AF restores high byte to A"
    assert_eq $(( 0xF0 )) "$CPU_F" "POP AF masks lower 4 bits of F to 0"
}

test_timer_and_interrupt_dispatch() {
    printf 'Running test_timer_and_interrupt_dispatch...\n'
    setup_blank_rom

    # Enable Timer Interrupt in IE, set IME=1, set TIMA=0xFF, TMA=0x42, TAC=0x05 (16 cycles)
    MMU_IE=$INT_TIMER
    MMU_IF=0
    CPU_IME=1
    TIMER_TIMA=0xFF
    TIMER_TMA=0x42
    TIMER_TAC=0x05 # Enable + 16-cycle clock

    # Put HALT at 0x0100
    CART_ROM[0x0100]=0x76

    gameboy_step # Executes HALT (4 cycles)
    assert_eq 1 "$CPU_HALTED" "CPU enters HALT state"

    timer_tick 16 # Overflow TIMA!
    assert_eq $(( 0x42 )) "$TIMER_TIMA" "TIMA reloads TMA (0x42) on overflow"
    assert_eq "$INT_TIMER" $(( MMU_IF & INT_TIMER )) "Timer overflow sets INT_TIMER in IF"

    gameboy_step # Services interrupt -> wakes from HALT and jumps to 0x0050
    assert_eq 0 "$CPU_HALTED" "Interrupt wakes CPU from HALT"
    assert_eq $(( 0x0050 )) "$CPU_PC" "CPU jumps to Timer ISR vector 0x0050"
    assert_eq 0 "$CPU_IME" "CPU clears IME upon entering ISR"
}

test_serial_hello_rom() {
    printf 'Running test_serial_hello_rom...\n'
    setup_blank_rom

    # Mini ROM that sends 'O' and 'K' over the Serial Link port (0xFF01 / 0xFF02)
    # 0100: LD A, 'O' (3E 4F)
    # 0102: LDH (0x01), A (E0 01)
    # 0104: LD A, 0x81 (3E 81)
    # 0106: LDH (0x02), A (E0 02)
    # 0108: LD A, 'K' (3E 4B)
    # 010A: LDH (0x01), A (E0 01)
    # 010C: LD A, 0x81 (3E 81)
    # 010E: LDH (0x02), A (E0 02)
    local -a prog=(0x3E 0x4F 0xE0 0x01 0x3E 0x81 0xE0 0x02 0x3E 0x4B 0xE0 0x01 0x3E 0x81 0xE0 0x02)
    local i
    for (( i = 0; i < ${#prog[@]}; i++ )); do
        CART_ROM[0x0100 + i]=${prog[i]}
    done

    for (( i = 0; i < 8; i++ )); do
        gameboy_step
    done

    assert_eq "OK" "$SERIAL_OUTPUT" "Serial port captures 'OK' transfer"
}


test_ppu_vblank() {
    printf 'Running test_ppu_vblank...\n'
    setup_blank_rom
    RENDER_THIS_FRAME=1
    MMU_IF=0
    # Run the 144 visible scanlines through the emulator's own scanline path.
    local line
    for (( line = 0; line < 144; line++ )); do
        gameboy_step_scanline
    done
    assert_eq 144 "$PPU_LY" "PPU reaches LY=144 after 144 scanlines"
    assert_eq 0 $(( MMU_IF & INT_VBLANK )) "V-Blank is not requested before LY=144"
    # The next scanline is the first V-Blank line, which requests the interrupt.
    gameboy_step_scanline
    assert_eq "$INT_VBLANK" $(( MMU_IF & INT_VBLANK )) "PPU fires V-Blank interrupt at LY=144"
}

test_cpu_alu_and_flags
test_cb_prefix_and_stack
test_timer_and_interrupt_dispatch
test_serial_hello_rom
test_ppu_vblank

printf '\n========================================\n'
printf 'Tests run: %d | Failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
printf '========================================\n'
(( TESTS_FAILED == 0 ))