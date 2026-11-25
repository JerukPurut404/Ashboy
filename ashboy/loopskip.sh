#!/usr/bin/env bash
# loopskip.sh - exact skipping of two idle-loop shapes.
#
# Shapes are matched by opcode bytes, never by address, so any ROM with the
# same loops benefits:
#
#   poll       LDH A,(n) ; AND A ; JR Z back to the top
#              n is a high-RAM address whose byte is 0, so JR Z is taken.
#              The loop may be entered at the top, at the AND, or at the JR.
#   countdown  [NOP | LD x,x] DEC r ; JR NZ back to the top
#
# Contract: loopskip_try BUDGET
#   BUDGET is the cycles left in the current scanline (>= 1).
#   Returns 0 after advancing the CPU: it sets _CPU_CYCLES to the cycles used
#   and updates the registers, GB_STEPS, GB_SKIP_PASSES and the timer.
#   Returns 1 and changes nothing when no shape applies.
#
# Exactness:
#   - Nothing is skipped unless the outcome is known: no pending interrupt,
#     timer off, not halted, no HALT bug, no EI delay.
#   - The poll loop is simulated instruction by instruction. Whole passes are
#     taken in one step. The cycles left at the end of the line are run one
#     instruction at a time, with the scanline stepper's rule: an instruction
#     runs while the budget is not yet used up. Instruction count, cycles,
#     registers and end address match normal stepping.
#   - The countdown takes whole passes only; its leftover is run by the stepper.
#
# Speed: bytes come straight from CART_ROM and MMU_HRAM through a nameref (no
# mmu_read8 calls). LS_CAND is built once at load time; the scanline stepper
# calls loopskip_try only at candidate addresses.

declare -ga LS_CAND=()

loopskip_try() {
    local budget=$1
    (( budget >= 1 )) || return 1
    (( CPU_HALTED == 0 && CPU_HALT_BUG == 0 && CPU_IME_DELAY == 0 )) || return 1
    (( (MMU_IE & MMU_IF & 0x1F) == 0 )) || return 1
    (( (TIMER_TAC & 4) == 0 )) || return 1

    local pc=$CPU_PC src idx
    if (( pc < 0x4000 )); then
        # Keep every byte this function reads inside bank 0.
        if (( pc > 0x3FFB )); then
            return 1
        fi
        src=CART_ROM
        idx=$pc
    elif (( pc >= 0xFF80 && pc <= 0xFFFE )); then
        src=MMU_HRAM
        idx=$(( pc - 0xFF80 ))
    else
        return 1
    fi
    local -n _ls_mem=$src
    local b0=${_ls_mem[idx]:-0} b1=${_ls_mem[idx+1]:-0}

    # ---- Poll loop -------------------------------------------------------
    if (( b0 == 0xF0 || b0 == 0xA7 || b0 == 0x28 )); then
        local off top at cum=0 steps=0 passes=0 m=0
        local t0 t1 t2 t3 t4

        # Which loop instruction starts at pc: 0 = LDH, 2 = AND, 3 = JR Z.
        if (( b0 == 0xF0 )); then
            off=0
        elif (( b0 == 0xA7 )); then
            off=2
        else
            off=3
        fi

        (( idx >= off )) || return 1
        top=$(( idx - off ))
        t0=${_ls_mem[top]:-0}
        t1=${_ls_mem[top+1]:-0}
        t2=${_ls_mem[top+2]:-0}
        t3=${_ls_mem[top+3]:-0}
        t4=${_ls_mem[top+4]:-0}
        (( t0 == 0xF0 && t1 >= 0x80 && t1 <= 0xFE )) || return 1
        (( t2 == 0xA7 && t3 == 0x28 && t4 == 0xFB )) || return 1
        (( ${MMU_HRAM[t1 - 0x80]:-1} == 0 )) || return 1

        # Entry checks: the AND needs A = 0, the JR needs Z set.
        if (( off == 2 )); then
            (( CPU_A == 0 )) || return 1
        elif (( off == 3 )); then
            (( CPU_F & FLAG_Z )) || return 1
        fi

        # Simulate. "at" is the next loop instruction (0, 2 or 3).
        at=$off
        while (( cum < budget )); do
            if (( at == 0 )); then
                # Whole passes from the top, all of which fit in the budget.
                m=$(( (budget - cum) / 28 ))
                if (( m > 0 )); then
                    (( cum += 28 * m, steps += 3 * m, passes += m ))
                    CPU_A=0
                    CPU_F=$(( FLAG_Z | FLAG_H ))
                fi
                (( cum < budget )) || break
                CPU_A=0                             # LDH A,(n): 12 cycles
                (( cum += 12, steps += 1 ))
                at=2
            elif (( at == 2 )); then
                CPU_F=$(( FLAG_Z | FLAG_H ))        # AND A: 4 cycles
                (( cum += 4, steps += 1 ))
                at=3
            else
                (( cum += 12, steps += 1 ))         # JR Z back to the top: 12 cycles
                at=0
            fi
        done

        CPU_PC=$(( pc - off + at ))
        _CPU_CYCLES=$cum
        (( GB_STEPS += steps, GB_SKIP_PASSES += passes ))
        timer_tick "$cum"
        return 0
    fi

    # ---- Countdown loop --------------------------------------------------
    local prefix=0 dec=$b0 reg jr off2 regv per n res h
    if (( b0 == 0x00 || b0 == 0x40 || b0 == 0x49 || b0 == 0x52 || b0 == 0x5B || b0 == 0x64 || b0 == 0x6D || b0 == 0x7F )); then
        prefix=1
        dec=$b1
    fi
    if (( dec == 0x05 )); then reg=CPU_B
    elif (( dec == 0x0D )); then reg=CPU_C
    elif (( dec == 0x15 )); then reg=CPU_D
    elif (( dec == 0x1D )); then reg=CPU_E
    elif (( dec == 0x25 )); then reg=CPU_H
    elif (( dec == 0x2D )); then reg=CPU_L
    elif (( dec == 0x3D )); then reg=CPU_A
    else return 1
    fi

    jr=${_ls_mem[idx+prefix+1]:-0}
    off2=${_ls_mem[idx+prefix+2]:-0}
    (( jr == 0x20 && off2 == 256 - prefix - 3 )) || return 1

    local -n _ls_reg=$reg
    regv=$_ls_reg
    (( regv >= 2 )) || return 1
    per=$(( 16 + 4 * prefix ))
    n=$(( budget / per ))
    if (( n > regv - 1 )); then
        n=$(( regv - 1 ))
    fi
    (( n >= 1 )) || return 1

    res=$(( regv - n ))
    _ls_reg=$res
    h=0
    if (( (res & 0x0F) == 0x0F )); then
        h=$FLAG_H
    fi
    CPU_F=$(( (CPU_F & FLAG_C) | FLAG_N | h ))
    _CPU_CYCLES=$(( n * per ))
    (( GB_STEPS += n * (2 + prefix), GB_SKIP_PASSES += n ))
    timer_tick "$_CPU_CYCLES"
    return 0
}

# Build the candidate table once, at load time. A poll loop marks its top and
# its AND and JR addresses, so entry in the middle of a pass is also caught.
# loopskip_try does the exact checks; this table only avoids calls elsewhere.
loopskip_build_filter() {
    LS_CAND=()
    local a b0 b1 b2 b3 b4 prefix dec jr off2
    for (( a = 0; a < 0x4000; a++ )); do
        b0=${CART_ROM[a]:-0}
        b1=${CART_ROM[a+1]:-0}

        if (( b0 == 0xF0 )); then
            b2=${CART_ROM[a+2]:-0}
            b3=${CART_ROM[a+3]:-0}
            b4=${CART_ROM[a+4]:-0}
            if (( b1 >= 0x80 && b1 <= 0xFE && b2 == 0xA7 && b3 == 0x28 && b4 == 0xFB )); then
                LS_CAND[a]=1
                LS_CAND[a+2]=1
                LS_CAND[a+3]=1
            fi
            continue
        fi

        prefix=0
        dec=$b0
        if (( b0 == 0x00 || b0 == 0x40 || b0 == 0x49 || b0 == 0x52 || b0 == 0x5B || b0 == 0x64 || b0 == 0x6D || b0 == 0x7F )); then
            prefix=1
            dec=$b1
        fi
        if (( dec == 0x05 || dec == 0x0D || dec == 0x15 || dec == 0x1D || dec == 0x25 || dec == 0x2D || dec == 0x3D )); then
            jr=${CART_ROM[a+prefix+1]:-0}
            off2=${CART_ROM[a+prefix+2]:-0}
            if (( jr == 0x20 && off2 == 256 - prefix - 3 )); then
                LS_CAND[a]=1
            fi
        fi
    done
    return 0
}