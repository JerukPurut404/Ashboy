#!/usr/bin/env bash
# ashboy/cpu.sh: Sharp LR35902 (SM83) CPU core, table-dispatched
#
# Speed design:
#   * OP_FN[opcode] names the handler for each base opcode. One array lookup
#     replaces the old linear `case` (which compared patterns one by one).
#   * Related opcodes share a handler and decode their own bits.
#   * Handlers write their cycle count to _CPU_CYCLES and use globals only.
#   * Opcode fetch from the first 16 KB of ROM reads CART_ROM directly.
#
# Interrupt dispatch lives in interrupts.sh. CB-prefixed opcodes are decoded
# by op_cb, which replaces the old cpu_exec_cb.

[[ -n "${_ASHBOY_CPU_SH:-}" ]] && return 0
readonly _ASHBOY_CPU_SH=1

_CPU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_CPU_DIR/init.sh"
source "$_CPU_DIR/mmu.sh"

# Registers
declare -gi CPU_A=0x01 CPU_F=0xB0
declare -gi CPU_B=0x00 CPU_C=0x13
declare -gi CPU_D=0x00 CPU_E=0xD8
declare -gi CPU_H=0x01 CPU_L=0x4D
declare -gi CPU_SP=0xFFFE
declare -gi CPU_PC=0x0100

declare -gi CPU_IME=0
declare -gi CPU_IME_DELAY=0
declare -gi CPU_HALTED=0
declare -gi CPU_HALT_BUG=0

# Scratch globals
declare -gi _CPU_OP=0 _CPU_CYCLES=4 _CPU_EI=0 _CPU_IDX=0
declare -gi _CPU_ADDR=0 _CPU_REL=0 _CPU_TMP=0 _CPU_LO=0 _CPU_HI=0
declare -gi _CC_OK=0 _RR=0 _HL_OLD=0 _HL_RES=0
declare -gi _ALU_OP=0 _ALU_V=0 _ALU_C=0 _ALU_R=0
declare -gi _ROT_V=0 _ROT_RES=0 _ROT_C=0
declare -gi _DAA_A=0 _DAA_C=0
declare -gi _CB_OP=0 _CB_REG=0 _CB_SUB=0 _CB_VAL=0

# OP_FN[opcode] = handler function name for each base opcode
declare -ga OP_FN=()

cpu_init() {
    CPU_A=0x01; CPU_F=0xB0
    CPU_B=0x00; CPU_C=0x13
    CPU_D=0x00; CPU_E=0xD8
    CPU_H=0x01; CPU_L=0x4D
    CPU_SP=0xFFFE
    CPU_PC=0x0100
    CPU_IME=0
    CPU_IME_DELAY=0
    CPU_HALTED=0
    CPU_HALT_BUG=0
}

# Memory access helpers 

# Read the byte at PC into REPLY and advance PC.
cpu_fetch8() {
    if (( CPU_PC < 16384 )); then
        (( REPLY = ${CART_ROM[CPU_PC]:-0} ))     # fast path: ROM bank 0
    else
        mmu_read8 "$CPU_PC"
    fi
    if (( CPU_HALT_BUG )); then
        CPU_HALT_BUG=0                            # HALT bug: PC does not advance
    else
        (( CPU_PC = (CPU_PC + 1) & 0xFFFF ))
    fi
}

# Read a little-endian 16-bit immediate into REPLY.
cpu_fetch16() {
    cpu_fetch8; _CPU_LO=$REPLY
    cpu_fetch8
    (( REPLY = (REPLY << 8) | _CPU_LO ))
}

cpu_push16() {
    _CPU_TMP=$1
    (( CPU_SP = (CPU_SP - 1) & 0xFFFF ))
    mmu_write8 "$CPU_SP" $(( (_CPU_TMP >> 8) & 0xFF ))
    (( CPU_SP = (CPU_SP - 1) & 0xFFFF ))
    mmu_write8 "$CPU_SP" $(( _CPU_TMP & 0xFF ))
}

# Pop a 16-bit value into REPLY.
cpu_pop16() {
    mmu_read8 "$CPU_SP"; _CPU_LO=$REPLY
    (( CPU_SP = (CPU_SP + 1) & 0xFFFF ))
    mmu_read8 "$CPU_SP"; _CPU_HI=$REPLY
    (( CPU_SP = (CPU_SP + 1) & 0xFFFF ))
    (( REPLY = (_CPU_HI << 8) | _CPU_LO ))
}

# 8-bit register by index: 0 B, 1 C, 2 D, 3 E, 4 H, 5 L, 6 (HL), 7 A.
# Result in REPLY.
cpu_get_r8() {
    case $1 in
        0) (( REPLY = CPU_B )) ;;
        1) (( REPLY = CPU_C )) ;;
        2) (( REPLY = CPU_D )) ;;
        3) (( REPLY = CPU_E )) ;;
        4) (( REPLY = CPU_H )) ;;
        5) (( REPLY = CPU_L )) ;;
        6) mmu_read8 $(( (CPU_H << 8) | CPU_L )) ;;
        7) (( REPLY = CPU_A )) ;;
    esac
}

cpu_set_r8() {
    case $1 in
        0) (( CPU_B = $2 & 0xFF )) ;;
        1) (( CPU_C = $2 & 0xFF )) ;;
        2) (( CPU_D = $2 & 0xFF )) ;;
        3) (( CPU_E = $2 & 0xFF )) ;;
        4) (( CPU_H = $2 & 0xFF )) ;;
        5) (( CPU_L = $2 & 0xFF )) ;;
        6) mmu_write8 $(( (CPU_H << 8) | CPU_L )) $(( $2 & 0xFF )) ;;
        7) (( CPU_A = $2 & 0xFF )) ;;
    esac
}

# 16-bit register pair by index: 0 BC, 1 DE, 2 HL, 3 SP. Result in _RR.
cpu_get_rr() {
    case $1 in
        0) (( _RR = (CPU_B << 8) | CPU_C )) ;;
        1) (( _RR = (CPU_D << 8) | CPU_E )) ;;
        2) (( _RR = (CPU_H << 8) | CPU_L )) ;;
        3) (( _RR = CPU_SP )) ;;
    esac
}

cpu_set_rr() {
    case $1 in
        0) (( CPU_B = ($2 >> 8) & 0xFF, CPU_C = $2 & 0xFF )) ;;
        1) (( CPU_D = ($2 >> 8) & 0xFF, CPU_E = $2 & 0xFF )) ;;
        2) (( CPU_H = ($2 >> 8) & 0xFF, CPU_L = $2 & 0xFF )) ;;
        3) (( CPU_SP = $2 & 0xFFFF )) ;;
    esac
}

# HL = HL + $1 (used by LD (HL+/-),A and LD A,(HL+/-))
cpu_hl_add() {
    (( _RR = ((((CPU_H << 8) | CPU_L) + $1) & 0xFFFF) ))
    (( CPU_H = (_RR >> 8) & 0xFF, CPU_L = _RR & 0xFF ))
}

# Condition check: $1 = 0 NZ, 1 Z, 2 NC, 3 C. REPLY = 1 if the condition holds.
cpu_check_cc() {
    case $1 in
        0) (( REPLY = ((CPU_F & FLAG_Z) == 0) ? 1 : 0 )) ;;
        1) (( REPLY = ((CPU_F & FLAG_Z) != 0) ? 1 : 0 )) ;;
        2) (( REPLY = ((CPU_F & FLAG_C) == 0) ? 1 : 0 )) ;;
        3) (( REPLY = ((CPU_F & FLAG_C) != 0) ? 1 : 0 )) ;;
    esac
}

# ALU 

# $1 = op (0 ADD, 1 ADC, 2 SUB, 3 SBC, 4 AND, 5 XOR, 6 OR, 7 CP), $2 = operand
cpu_alu8() {
    _ALU_OP=$1
    _ALU_V=$2
    case $_ALU_OP in
        0|1) # ADD, ADC
            _ALU_C=0
            if (( _ALU_OP == 1 && (CPU_F & FLAG_C) != 0 )); then _ALU_C=1; fi
            (( _ALU_R = CPU_A + _ALU_V + _ALU_C ))
            (( CPU_F = (((_ALU_R & 0xFF) == 0) ? FLAG_Z : 0)
                     | ((((CPU_A & 0x0F) + (_ALU_V & 0x0F) + _ALU_C) > 0x0F) ? FLAG_H : 0)
                     | ((_ALU_R > 0xFF) ? FLAG_C : 0) ))
            (( CPU_A = _ALU_R & 0xFF ))
            ;;
        2|3|7) # SUB, SBC, CP (CP does not store the result)
            _ALU_C=0
            if (( _ALU_OP == 3 && (CPU_F & FLAG_C) != 0 )); then _ALU_C=1; fi
            (( _ALU_R = CPU_A - _ALU_V - _ALU_C ))
            (( CPU_F = FLAG_N
                     | (((_ALU_R & 0xFF) == 0) ? FLAG_Z : 0)
                     | ((((CPU_A & 0x0F) - (_ALU_V & 0x0F) - _ALU_C) < 0) ? FLAG_H : 0)
                     | ((_ALU_R < 0) ? FLAG_C : 0) ))
            if (( _ALU_OP != 7 )); then (( CPU_A = _ALU_R & 0xFF )); fi
            ;;
        4) (( CPU_A &= _ALU_V, CPU_F = FLAG_H | ((CPU_A == 0) ? FLAG_Z : 0) )) ;;
        5) (( CPU_A ^= _ALU_V, CPU_F = ((CPU_A == 0) ? FLAG_Z : 0) )) ;;
        6) (( CPU_A |= _ALU_V, CPU_F = ((CPU_A == 0) ? FLAG_Z : 0) )) ;;
    esac
}

# Rotate/shift. $1 = op (0 RLC, 1 RRC, 2 RL, 3 RR, 4 SLA, 5 SRA, 6 SWAP, 7 SRL)
# $2 = value. Result in _ROT_RES, carry-out in _ROT_C.
# Reads CPU_F only for RL/RR, so call it before flags are overwritten.
cpu_rot8() {
    _ROT_V=$2
    case $1 in
        0) (( _ROT_C = (_ROT_V >> 7) & 1, _ROT_RES = ((_ROT_V << 1) | _ROT_C) & 0xFF )) ;;
        1) (( _ROT_C = _ROT_V & 1, _ROT_RES = ((_ROT_V >> 1) | (_ROT_C << 7)) & 0xFF )) ;;
        2) (( _ROT_C = (_ROT_V >> 7) & 1,
              _ROT_RES = ((_ROT_V << 1) | (((CPU_F & FLAG_C) != 0) ? 1 : 0)) & 0xFF )) ;;
        3) (( _ROT_C = _ROT_V & 1,
              _ROT_RES = ((_ROT_V >> 1) | ((((CPU_F & FLAG_C) != 0) ? 1 : 0) << 7)) & 0xFF )) ;;
        4) (( _ROT_C = (_ROT_V >> 7) & 1, _ROT_RES = (_ROT_V << 1) & 0xFF )) ;;
        5) (( _ROT_C = _ROT_V & 1, _ROT_RES = ((_ROT_V >> 1) | (_ROT_V & 0x80)) & 0xFF )) ;;
        6) (( _ROT_C = 0, _ROT_RES = ((_ROT_V & 0x0F) << 4) | ((_ROT_V >> 4) & 0x0F) )) ;;
        7) (( _ROT_C = _ROT_V & 1, _ROT_RES = _ROT_V >> 1 )) ;;
    esac
}

#  Opcode handlers 
# Each handler executes one instruction family and sets _CPU_CYCLES.

op_illegal() { _CPU_CYCLES=4; }
op_nop()     { _CPU_CYCLES=4; }

op_stop() {                       # STOP takes a padding byte
    cpu_fetch8
    _CPU_CYCLES=4
}

op_halt() {
    if (( CPU_IME == 0 && (MMU_IF & MMU_IE & 0x1F) != 0 )); then
        CPU_HALT_BUG=1            # pending interrupt with IME=0: HALT bug
    else
        CPU_HALTED=1
    fi
    _CPU_CYCLES=4
}

# LD r,r' (0x40-0x7F, except HALT)
op_ld_r_r() {
    cpu_get_r8 $(( _CPU_OP & 7 ))
    cpu_set_r8 $(( (_CPU_OP >> 3) & 7 )) "$REPLY"
    if (( (_CPU_OP & 7) == 6 || ((_CPU_OP >> 3) & 7) == 6 )); then
        _CPU_CYCLES=8
    else
        _CPU_CYCLES=4
    fi
}

# ALU A,r (0x80-0xBF)
op_alu_r() {
    cpu_get_r8 $(( _CPU_OP & 7 ))
    cpu_alu8 $(( (_CPU_OP >> 3) & 7 )) "$REPLY"
    if (( (_CPU_OP & 7) == 6 )); then _CPU_CYCLES=8; else _CPU_CYCLES=4; fi
}

# ALU A,n (0xC6, 0xCE, ... 0xFE)
op_alu_imm() {
    cpu_fetch8
    cpu_alu8 $(( (_CPU_OP >> 3) & 7 )) "$REPLY"
    _CPU_CYCLES=8
}

# INC r (0x04, 0x0C, ... 0x3C)
op_inc_r() {
    _CPU_IDX=$(( (_CPU_OP >> 3) & 7 ))
    cpu_get_r8 $_CPU_IDX
    (( CPU_F = (CPU_F & FLAG_C) | LUT_INC_FLAGS[REPLY] ))
    cpu_set_r8 $_CPU_IDX $(( (REPLY + 1) & 0xFF ))
    if (( _CPU_IDX == 6 )); then _CPU_CYCLES=12; else _CPU_CYCLES=4; fi
}

# DEC r (0x05, 0x0D, ... 0x3D)
op_dec_r() {
    _CPU_IDX=$(( (_CPU_OP >> 3) & 7 ))
    cpu_get_r8 $_CPU_IDX
    (( CPU_F = (CPU_F & FLAG_C) | LUT_DEC_FLAGS[REPLY] ))
    cpu_set_r8 $_CPU_IDX $(( (REPLY - 1) & 0xFF ))
    if (( _CPU_IDX == 6 )); then _CPU_CYCLES=12; else _CPU_CYCLES=4; fi
}

# LD r,n (0x06, 0x0E, ... 0x3E)
op_ld_r_n() {
    _CPU_IDX=$(( (_CPU_OP >> 3) & 7 ))
    cpu_fetch8
    cpu_set_r8 $_CPU_IDX "$REPLY"
    if (( _CPU_IDX == 6 )); then _CPU_CYCLES=12; else _CPU_CYCLES=8; fi
}

# LD rr,nn (0x01, 0x11, 0x21, 0x31)
op_ld_rr_nn() {
    cpu_fetch16
    cpu_set_rr $(( (_CPU_OP >> 4) & 3 )) "$REPLY"
    _CPU_CYCLES=12
}

# INC rr (0x03, 0x13, 0x23, 0x33) and DEC rr (0x0B, 0x1B, 0x2B, 0x3B)
op_incdec_rr() {
    _CPU_IDX=$(( (_CPU_OP >> 4) & 3 ))
    cpu_get_rr $_CPU_IDX
    if (( _CPU_OP & 0x08 )); then
        (( _RR = (_RR - 1) & 0xFFFF ))
    else
        (( _RR = (_RR + 1) & 0xFFFF ))
    fi
    cpu_set_rr $_CPU_IDX $_RR
    _CPU_CYCLES=8
}

# ADD HL,rr (0x09, 0x19, 0x29, 0x39)
op_add_hl() {
    cpu_get_rr $(( (_CPU_OP >> 4) & 3 ))
    (( _HL_OLD = (CPU_H << 8) | CPU_L ))
    (( _HL_RES = _HL_OLD + _RR ))
    (( CPU_F = (CPU_F & FLAG_Z)
             | ((((_HL_OLD & 0x0FFF) + (_RR & 0x0FFF)) > 0x0FFF) ? FLAG_H : 0)
             | ((_HL_RES > 0xFFFF) ? FLAG_C : 0) ))
    cpu_set_rr 2 $(( _HL_RES & 0xFFFF ))
    _CPU_CYCLES=8
}

# LD (BC),A / LD (DE),A / LD (HL+),A / LD (HL-),A
op_ld_mem_a() {
    _CPU_IDX=$(( (_CPU_OP >> 4) & 3 ))
    if (( _CPU_IDX == 0 )); then
        mmu_write8 $(( (CPU_B << 8) | CPU_C )) "$CPU_A"
    elif (( _CPU_IDX == 1 )); then
        mmu_write8 $(( (CPU_D << 8) | CPU_E )) "$CPU_A"
    else
        mmu_write8 $(( (CPU_H << 8) | CPU_L )) "$CPU_A"
        if (( _CPU_IDX == 2 )); then cpu_hl_add 1; else cpu_hl_add -1; fi
    fi
    _CPU_CYCLES=8
}

# LD A,(BC) / LD A,(DE) / LD A,(HL+) / LD A,(HL-)
op_ld_a_mem() {
    _CPU_IDX=$(( (_CPU_OP >> 4) & 3 ))
    if (( _CPU_IDX == 0 )); then
        mmu_read8 $(( (CPU_B << 8) | CPU_C ))
    elif (( _CPU_IDX == 1 )); then
        mmu_read8 $(( (CPU_D << 8) | CPU_E ))
    else
        mmu_read8 $(( (CPU_H << 8) | CPU_L ))
        if (( _CPU_IDX == 2 )); then cpu_hl_add 1; else cpu_hl_add -1; fi
    fi
    CPU_A=$REPLY
    _CPU_CYCLES=8
}

# LD (nn),SP (0x08)
op_ld_nn_sp() {
    cpu_fetch16
    _CPU_ADDR=$REPLY
    mmu_write8 "$_CPU_ADDR" $(( CPU_SP & 0xFF ))
    mmu_write8 $(( (_CPU_ADDR + 1) & 0xFFFF )) $(( CPU_SP >> 8 ))
    _CPU_CYCLES=20
}

# RLCA (0x07), RRCA (0x0F), RLA (0x17), RRA (0x1F). Z is always cleared.
op_rot_a() {
    cpu_rot8 $(( (_CPU_OP >> 3) & 7 )) "$CPU_A"
    CPU_A=$_ROT_RES
    (( CPU_F = _ROT_C ? FLAG_C : 0 ))
    _CPU_CYCLES=4
}

# DAA (0x27)
op_daa() {
    _DAA_A=$CPU_A
    (( _DAA_C = CPU_F & FLAG_C ))
    if (( (CPU_F & FLAG_N) == 0 )); then
        if (( (CPU_F & FLAG_C) != 0 || _DAA_A > 0x99 )); then
            (( _DAA_A += 0x60, _DAA_C = FLAG_C ))
        fi
        if (( (CPU_F & FLAG_H) != 0 || (_DAA_A & 0x0F) > 0x09 )); then
            (( _DAA_A += 0x06 ))
        fi
    else
        if (( (CPU_F & FLAG_C) != 0 )); then (( _DAA_A -= 0x60 )); fi
        if (( (CPU_F & FLAG_H) != 0 )); then (( _DAA_A -= 0x06 )); fi
    fi
    (( CPU_A = _DAA_A & 0xFF ))
    (( CPU_F = (CPU_F & FLAG_N) | ((CPU_A == 0) ? FLAG_Z : 0) | _DAA_C ))
    _CPU_CYCLES=4
}

# CPL (0x2F)
op_cpl() {
    (( CPU_A = (~CPU_A) & 0xFF, CPU_F = (CPU_F & (FLAG_Z | FLAG_C)) | FLAG_N | FLAG_H ))
    _CPU_CYCLES=4
}

# SCF (0x37)
op_scf() {
    (( CPU_F = (CPU_F & FLAG_Z) | FLAG_C ))
    _CPU_CYCLES=4
}

# CCF (0x3F)
op_ccf() {
    (( CPU_F = (CPU_F & FLAG_Z) | (((CPU_F & FLAG_C) != 0) ? 0 : FLAG_C) ))
    _CPU_CYCLES=4
}

# JR e (0x18)
op_jr() {
    cpu_fetch8
    (( _CPU_REL = (REPLY ^ 0x80) - 0x80 ))          # sign-extend the byte
    (( CPU_PC = (CPU_PC + _CPU_REL) & 0xFFFF ))
    _CPU_CYCLES=12
}

# JR cc,e (0x20, 0x28, 0x30, 0x38)
op_jr_cc() {
    cpu_fetch8
    (( _CPU_REL = (REPLY ^ 0x80) - 0x80 ))
    cpu_check_cc $(( (_CPU_OP >> 3) & 3 ))
    if (( REPLY )); then
        (( CPU_PC = (CPU_PC + _CPU_REL) & 0xFFFF ))
        _CPU_CYCLES=12
    else
        _CPU_CYCLES=8
    fi
}

# JP nn (0xC3)
op_jp() {
    cpu_fetch16
    (( CPU_PC = REPLY ))
    _CPU_CYCLES=16
}

# JP cc,nn (0xC2, 0xCA, 0xD2, 0xDA)
op_jp_cc() {
    cpu_fetch16
    _CPU_ADDR=$REPLY
    cpu_check_cc $(( (_CPU_OP >> 3) & 3 ))
    if (( REPLY )); then
        (( CPU_PC = _CPU_ADDR ))
        _CPU_CYCLES=16
    else
        _CPU_CYCLES=12
    fi
}

# JP (HL) (0xE9)
op_jp_hl() {
    (( CPU_PC = (CPU_H << 8) | CPU_L ))
    _CPU_CYCLES=4
}

# CALL nn (0xCD)
op_call() {
    cpu_fetch16
    _CPU_ADDR=$REPLY
    cpu_push16 "$CPU_PC"
    (( CPU_PC = _CPU_ADDR ))
    _CPU_CYCLES=24
}

# CALL cc,nn (0xC4, 0xCC, 0xD4, 0xDC)
op_call_cc() {
    cpu_fetch16
    _CPU_ADDR=$REPLY
    cpu_check_cc $(( (_CPU_OP >> 3) & 3 ))
    if (( REPLY )); then
        cpu_push16 "$CPU_PC"
        (( CPU_PC = _CPU_ADDR ))
        _CPU_CYCLES=24
    else
        _CPU_CYCLES=12
    fi
}

# RET (0xC9)
op_ret() {
    cpu_pop16
    (( CPU_PC = REPLY ))
    _CPU_CYCLES=16
}

# RET cc (0xC0, 0xC8, 0xD0, 0xD8)
op_ret_cc() {
    cpu_check_cc $(( (_CPU_OP >> 3) & 3 ))
    if (( REPLY )); then
        cpu_pop16
        (( CPU_PC = REPLY ))
        _CPU_CYCLES=20
    else
        _CPU_CYCLES=8
    fi
}

# RETI (0xD9): RET and enable interrupts immediately
op_reti() {
    cpu_pop16
    (( CPU_PC = REPLY ))
    CPU_IME=1
    _CPU_CYCLES=16
}

# RST n (0xC7, 0xCF, ... 0xFF)
op_rst() {
    cpu_push16 "$CPU_PC"
    (( CPU_PC = _CPU_OP & 0x38 ))
    _CPU_CYCLES=16
}

# PUSH rr (0xC5, 0xD5, 0xE5, 0xF5). Index 3 is AF here, not SP.
op_push() {
    _CPU_IDX=$(( (_CPU_OP >> 4) & 3 ))
    if (( _CPU_IDX == 3 )); then
        (( _RR = (CPU_A << 8) | (CPU_F & 0xF0) ))
    else
        cpu_get_rr $_CPU_IDX
    fi
    cpu_push16 $_RR
    _CPU_CYCLES=16
}

# POP rr (0xC1, 0xD1, 0xE1, 0xF1). Index 3 is AF here, low nibble of F is kept at 0.
op_pop() {
    _CPU_IDX=$(( (_CPU_OP >> 4) & 3 ))
    cpu_pop16
    _RR=$REPLY
    if (( _CPU_IDX == 3 )); then
        (( CPU_A = (_RR >> 8) & 0xFF, CPU_F = _RR & 0xF0 ))
    else
        cpu_set_rr $_CPU_IDX $_RR
    fi
    _CPU_CYCLES=12
}

# LDH (n),A (0xE0)
op_ldh_n_a() {
    cpu_fetch8
    mmu_write8 $(( 0xFF00 + REPLY )) "$CPU_A"
    _CPU_CYCLES=12
}

# LDH A,(n) (0xF0)
op_ldh_a_n() {
    cpu_fetch8
    mmu_read8 $(( 0xFF00 + REPLY ))
    CPU_A=$REPLY
    _CPU_CYCLES=12
}

# LD (C),A (0xE2)
op_ldh_c_a() {
    mmu_write8 $(( 0xFF00 + CPU_C )) "$CPU_A"
    _CPU_CYCLES=8
}

# LD A,(C) (0xF2)
op_ldh_a_c() {
    mmu_read8 $(( 0xFF00 + CPU_C ))
    CPU_A=$REPLY
    _CPU_CYCLES=8
}

# LD (nn),A (0xEA)
op_ld_nn_a() {
    cpu_fetch16
    mmu_write8 "$REPLY" "$CPU_A"
    _CPU_CYCLES=16
}

# LD A,(nn) (0xFA)
op_ld_a_nn() {
    cpu_fetch16
    mmu_read8 "$REPLY"
    CPU_A=$REPLY
    _CPU_CYCLES=16
}

# Shared flag logic for SP + signed e8 (ADD SP,e8 and LD HL,SP+e8).
# Input: _CPU_REL = signed offset, _CPU_VAL = raw byte.
cpu_sp_flags() {
    (( CPU_F = ((((CPU_SP & 0x0F) + (_CPU_VAL & 0x0F)) > 0x0F) ? FLAG_H : 0)
             | ((((CPU_SP & 0xFF) + (_CPU_VAL & 0xFF)) > 0xFF) ? FLAG_C : 0) ))
}

# ADD SP,e8 (0xE8)
op_add_sp_e() {
    cpu_fetch8
    _CPU_VAL=$REPLY
    (( _CPU_REL = (_CPU_VAL ^ 0x80) - 0x80 ))
    cpu_sp_flags
    (( CPU_SP = (CPU_SP + _CPU_REL) & 0xFFFF ))
    _CPU_CYCLES=16
}

# LD HL,SP+e8 (0xF8)
op_ld_hl_sp_e() {
    cpu_fetch8
    _CPU_VAL=$REPLY
    (( _CPU_REL = (_CPU_VAL ^ 0x80) - 0x80 ))
    cpu_sp_flags
    (( _RR = (CPU_SP + _CPU_REL) & 0xFFFF ))
    cpu_set_rr 2 $_RR
    _CPU_CYCLES=12
}

# LD SP,HL (0xF9)
op_ld_sp_hl() {
    (( CPU_SP = (CPU_H << 8) | CPU_L ))
    _CPU_CYCLES=8
}

# DI (0xF3). Also cancels a pending EI.
op_di() {
    CPU_IME=0
    CPU_IME_DELAY=0
    _CPU_EI=0
    _CPU_CYCLES=4
}

# EI (0xFB). Takes effect after the next instruction (handled in cpu_step).
op_ei() {
    CPU_IME_DELAY=1
    _CPU_CYCLES=4
}

# CB prefix (0xCB): decode the second byte with bit fields.
op_cb() {
    cpu_fetch8
    _CB_OP=$REPLY
    _CB_REG=$(( _CB_OP & 7 ))
    _CB_SUB=$(( (_CB_OP >> 3) & 7 ))
    cpu_get_r8 $_CB_REG
    _CB_VAL=$REPLY

    case $(( _CB_OP >> 6 )) in
        0) # RLC, RRC, RL, RR, SLA, SRA, SWAP, SRL
            cpu_rot8 $_CB_SUB $_CB_VAL
            (( CPU_F = ((_ROT_RES == 0) ? FLAG_Z : 0) | (_ROT_C ? FLAG_C : 0) ))
            cpu_set_r8 $_CB_REG $_ROT_RES
            ;;
        1) # BIT b,r
            (( CPU_F = (CPU_F & FLAG_C) | FLAG_H | ((((_CB_VAL >> _CB_SUB) & 1) == 0) ? FLAG_Z : 0) ))
            ;;
        2) # RES b,r
            cpu_set_r8 $_CB_REG $(( _CB_VAL & ~(1 << _CB_SUB) ))
            ;;
        3) # SET b,r
            cpu_set_r8 $_CB_REG $(( _CB_VAL | (1 << _CB_SUB) ))
            ;;
    esac

    if (( _CB_REG == 6 )); then
        if (( (_CB_OP >> 6) == 1 )); then _CPU_CYCLES=12; else _CPU_CYCLES=16; fi
    else
        _CPU_CYCLES=8
    fi
}

#  Dispatch table 

# Map one handler to a list of opcodes: _cpu_map handler op1 op2 ...
_cpu_map() {
    local handler=$1 op
    shift
    for op in "$@"; do
        OP_FN[$op]=$handler
    done
}

cpu_build_tables() {
    local op

    # Default: undefined opcodes take 4 cycles and do nothing
    for (( op = 0; op < 256; op++ )); do
        OP_FN[op]=op_illegal
    done

    # Block 1: LD r,r' (0x40-0x7F). HALT (0x76) is overridden below.
    for (( op = 0x40; op <= 0x7F; op++ )); do OP_FN[op]=op_ld_r_r; done

    # Block 2: ALU A,r (0x80-0xBF)
    for (( op = 0x80; op <= 0xBF; op++ )); do OP_FN[op]=op_alu_r; done

    # Block 0: opcodes whose low 3 bits select the column
    for (( op = 0x00; op <= 0x3F; op++ )); do
        case $(( op & 7 )) in
            4) OP_FN[op]=op_inc_r ;;
            5) OP_FN[op]=op_dec_r ;;
            6) OP_FN[op]=op_ld_r_n ;;
        esac
    done

    # Block 0: individual opcodes (these override the column rules above)
    _cpu_map op_nop        0x00
    _cpu_map op_ld_rr_nn   0x01 0x11 0x21 0x31
    _cpu_map op_ld_mem_a   0x02 0x12 0x22 0x32
    _cpu_map op_incdec_rr  0x03 0x13 0x23 0x33 0x0B 0x1B 0x2B 0x3B
    _cpu_map op_rot_a      0x07 0x0F 0x17 0x1F
    _cpu_map op_ld_nn_sp   0x08
    _cpu_map op_add_hl     0x09 0x19 0x29 0x39
    _cpu_map op_ld_a_mem   0x0A 0x1A 0x2A 0x3A
    _cpu_map op_stop       0x10
    _cpu_map op_jr         0x18
    _cpu_map op_jr_cc      0x20 0x28 0x30 0x38
    _cpu_map op_daa        0x27
    _cpu_map op_cpl        0x2F
    _cpu_map op_scf        0x37
    _cpu_map op_ccf        0x3F

    # Block 3: control, stack, immediate and I/O
    _cpu_map op_ret_cc     0xC0 0xC8 0xD0 0xD8
    _cpu_map op_pop        0xC1 0xD1 0xE1 0xF1
    _cpu_map op_jp_cc      0xC2 0xCA 0xD2 0xDA
    _cpu_map op_jp         0xC3
    _cpu_map op_call_cc    0xC4 0xCC 0xD4 0xDC
    _cpu_map op_push       0xC5 0xD5 0xE5 0xF5
    _cpu_map op_alu_imm    0xC6 0xCE 0xD6 0xDE 0xE6 0xEE 0xF6 0xFE
    _cpu_map op_rst        0xC7 0xCF 0xD7 0xDF 0xE7 0xEF 0xF7 0xFF
    _cpu_map op_ret        0xC9
    _cpu_map op_cb         0xCB
    _cpu_map op_call       0xCD
    _cpu_map op_ldh_n_a    0xE0
    _cpu_map op_ldh_c_a    0xE2
    _cpu_map op_add_sp_e   0xE8
    _cpu_map op_jp_hl      0xE9
    _cpu_map op_ld_nn_a    0xEA
    _cpu_map op_ldh_a_n    0xF0
    _cpu_map op_ldh_a_c    0xF2
    _cpu_map op_di         0xF3
    _cpu_map op_ei         0xFB
    _cpu_map op_ld_hl_sp_e 0xF8
    _cpu_map op_ld_sp_hl   0xF9
    _cpu_map op_ld_a_nn    0xFA
    _cpu_map op_reti       0xD9

    # Control and HALT
    _cpu_map op_halt       0x76
}

#  Instruction step 

# Execute one instruction and leave its T-cycle count in _CPU_CYCLES.
# Interrupt dispatch is done by interrupts_service() before this is called.
cpu_step() {
    if (( CPU_HALTED )); then
        _CPU_CYCLES=4
        return
    fi

    # EI takes effect after the instruction that follows it.
    _CPU_EI=$CPU_IME_DELAY

    cpu_fetch8
    _CPU_OP=$REPLY
    _CPU_CYCLES=4

    "${OP_FN[_CPU_OP]}"

    if (( _CPU_EI )); then
        CPU_IME=1
        CPU_IME_DELAY=0
    fi
}

cpu_build_tables