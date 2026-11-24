#!/usr/bin/env bash
# ashboy/interrupts.sh: Interrupt controller: priority selection and dispatch

[[ -n "${_ASHBOY_INTERRUPTS_SH:-}" ]] && return 0
readonly _ASHBOY_INTERRUPTS_SH=1

# Scratch globals (no `local` in the hot path)
_INT_PENDING=0
_INT_BIT=0

# Returns 0 if an interrupt was dispatched (PC = vector, _CPU_CYCLES = 20).
# Returns 1 otherwise and leaves PC, SP and the stack untouched.
#
# Priority (lowest bit first): V-Blank 0x40, STAT 0x48, Timer 0x50,
#                              Serial 0x58, Joypad 0x60
interrupts_service() {
    (( _INT_PENDING = MMU_IE & MMU_IF & 0x1F ))
    (( _INT_PENDING != 0 )) || return 1

    # A pending, enabled interrupt wakes HALT even when IME = 0
    CPU_HALTED=0

    # With IME = 0 the interrupt stays pending and runs once IME is set
    (( CPU_IME )) || return 1

    # Highest priority = lowest set bit
    for (( _INT_BIT = 0; _INT_BIT < 5; _INT_BIT++ )); do
        if (( _INT_PENDING & (1 << _INT_BIT) )); then
            break
        fi
    done

    CPU_IME=0
    CPU_IME_DELAY=0
    (( MMU_IF &= ~(1 << _INT_BIT) ))    # acknowledge this interrupt

    cpu_push16 "$CPU_PC"                # return address goes on the stack
    (( CPU_PC = 0x40 + _INT_BIT * 8 ))  # jump to the vector

    _CPU_CYCLES=20
    return 0
}