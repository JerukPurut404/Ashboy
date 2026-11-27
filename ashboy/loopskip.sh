#!/usr/bin/env bash
# loopskip.sh - exact fast paths for three loop shapes.
#
# Shapes are matched by opcode bytes, never by address, so any ROM with the
# same loops benefits:
#
#   poll       LDH A,(n) ; AND A ; JR Z back to the top
#              n is a high-RAM address whose byte is 0, so JR Z is taken.
#              The loop may be entered at the top, at the AND, or at the JR.
#   countdown  [NOP | LD x,x] DEC r ; JR NZ back to the top
#   copy       LD A,(HL+) ; LD (DE),A ; INC DE ; DEC BC ; LD A,B ; OR C ;
#              JR NZ back to the top. Bank 0 only.
#
# Contract: loopskip_try BUDGET
#   BUDGET is the cycles left in the current scanline (>= 1).
#   Returns 0 after advancing the CPU: it sets _CPU_CYCLES to the cycles used
#   and updates the registers, memory, GB_STEPS, GB_SKIP_PASSES,
#   GB_COPY_PASSES and the timer.
#   Returns 1 and changes nothing when no shape applies.
#
# Exactness:
#   - Nothing is skipped unless the outcome is known: no pending interrupt,
#     timer off, not halted, no HALT bug, no EI delay.
#   - The poll loop is simulated instruction by instruction. Whole passes are
#     taken in one step. The cycles left at the end of the line are run one
#     instruction at a time, with the scanline stepper's rule: an instruction
#     runs while the budget is not yet used up.
#   - The countdown takes whole passes only; its leftover is run by the stepper.
#   - The copy loop takes only passes whose every instruction would start below
#     the budget. Each byte goes through mmu_read8 and mmu_write8 in the same
#     order as the stepper, so VRAM write tracking (PPU_VRAM_GEN) is unchanged.
#     Writes are limited to VRAM, WRAM and HRAM, so no I/O or interrupt flag
#     can change during a fast run.
#
# Speed: poll and countdown read bytes straight from CART_ROM and MMU_HRAM
# through a nameref (no mmu_read8 calls). LS_CAND is built once at load time;
# the scanline stepper calls loopskip_try only at candidate addresses.
#
# GB_BLOCK_COPY=0 turns the copy path off, for comparison runs.
declare -ga LS_CAND=()
declare -gi GB_BLOCK_COPY=${GB_BLOCK_COPY:-1} GB_COPY_PASSES=0
declare -ga COPY_SHAPE=(0x2A 0x12 0x13 0x0B 0x78 0xB1 0x20 0xF8)

# True when the 8 bytes at address $1 (bank 0) are the copy shape.
loopskip_is_copy_at() {
    local a=$1 j
    for (( j = 0; j < 8; j++ )); do
        (( ${CART_ROM[a+j]:-0} == COPY_SHAPE[j] )) || return 1
    done
    return 0
}

# Copy loop. Called only from loopskip_try, after its gate checks.
# One taken pass is 7 instructions and 52 cycles:
#   2A LD A,(HL+) 8 | 12 LD (DE),A 8 | 13 INC DE 8 | 0B DEC BC 8
#   78 LD A,B 4 | B1 OR C 4 | 20 xx JR NZ 12 (taken)
loopskip_copy() {
    local budget=$1 pc=$CPU_PC
    (( GB_BLOCK_COPY == 1 )) || return 1
    (( pc <= 0x3FF8 )) || return 1
    loopskip_is_copy_at "$pc" || return 1
    local bc=$(( (CPU_B << 8) | CPU_C ))
    local de=$(( (CPU_D << 8) | CPU_E ))
    local hl=$(( (CPU_H << 8) | CPU_L ))
    # Pass j starts at cycle 52*j. Its last instruction boundary is the JR,
    # at offset 40, and it must be below the budget, as in the stepper.
    # That gives k = (budget + 11) / 52 passes.
    local k=$(( (budget + 11) / 52 ))
    # A taken JR needs BC != 0 after DEC BC, so at most BC-1 taken passes.
    if (( k > bc - 1 )); then
        k=$(( bc - 1 ))
    fi
    # Destination must stay in one writable region.
    local rend
    if (( de >= 0x8000 && de <= 0x9FFF )); then
        rend=0x9FFF
    elif (( de >= 0xC000 && de <= 0xDFFF )); then
        rend=0xDFFF
    elif (( de >= 0xFF80 && de <= 0xFFFE )); then
        rend=0xFFFE
    else
        return 1
    fi
    if (( k > rend - de + 1 )); then
        k=$(( rend - de + 1 ))
    fi
    (( k >= 1 )) || return 1
    local i
    for (( i = 0; i < k; i++ )); do
        mmu_read8 "$hl"                  # LD A,(HL+)
        CPU_A=$REPLY
        hl=$(( (hl + 1) & 0xFFFF ))
        mmu_write8 "$de" "$CPU_A"        # LD (DE),A
        de=$(( (de + 1) & 0xFFFF ))      # INC DE
        bc=$(( (bc - 1) & 0xFFFF ))      # DEC BC
    done
    # Registers as the stepper leaves them after the last pass.
    CPU_B=$(( bc >> 8 ))
    CPU_C=$(( bc & 0xFF ))
    CPU_D=$(( de >> 8 ))
    CPU_E=$(( de & 0xFF ))
    CPU_H=$(( hl >> 8 ))
    CPU_L=$(( hl & 0xFF ))
    CPU_A=$(( CPU_B | CPU_C ))           # LD A,B ; OR C
    CPU_F=0                              # OR: Z clear (BC != 0), N H C clear
    # PC is unchanged: the taken JR returns to the top of the loop.
    _CPU_CYCLES=$(( 52 * k ))
    (( GB_STEPS += 7 * k, GB_COPY_PASSES += k ))
    timer_tick "$_CPU_CYCLES"
    return 0
}

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
    # ---- Copy loop -------------------------------------------------------
    # Only ROM can hold the copy shape; a HRAM byte of 0x2A must not match.
    if (( b0 == 0x2A && pc < 0x4000 )); then
        loopskip_copy "$budget"
        return $?
    fi
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
# A copy loop marks its top. loopskip_try does the exact checks; this table
# only avoids calls elsewhere.
loopskip_build_filter() {
    LS_CAND=()
    local a b0 b1 b2 b3 b4 prefix dec jr off2
    for (( a = 0; a < 0x4000; a++ )); do
        b0=${CART_ROM[a]:-0}
        b1=${CART_ROM[a+1]:-0}
        if (( b0 == 0x2A )); then
            if loopskip_is_copy_at "$a"; then
                LS_CAND[a]=1
            fi
            continue
        fi
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