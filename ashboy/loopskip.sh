#!/usr/bin/env bash
# AshBoy loop skipper
# Job: recognise tight loops by their opcode pattern and advance them in one
#      step, when that gives exactly the same state as running every pass.
#      No ROM addresses are used; the patterns are common Game Boy idioms.
#
# Pattern 1, countdown (register only):
#     [NOP | LD x,x]   DEC r   JR NZ, back to the first byte
#     A pass changes only r and the flags, so whole passes can be applied at once.
#
# Pattern 2, poll (high-RAM flag):
#     LDH A,(n)   AND A   JR Z, back to the first byte     (n = 80..FE)
#     While the flag is 0 the loop cannot exit. The flag changes only by a CPU
#     write or an interrupt, and neither can happen inside a skipped span.
#
# Contract:
#   loopskip_try BUDGET   BUDGET = cycles left in the current scanline.
#   Returns 0 when it advanced the loop. _CPU_CYCLES then holds the cycles used
#   and the timer has been advanced. The caller adds _CPU_CYCLES to its count.
#   Returns 1 when nothing was changed.
#
# Only whole passes are taken, and each pass must end at or before the
# scanline end. A partial pass would move the scanline boundary and change
# the state. The few instructions left over run one at a time.
#
# Speed: loopskip_try runs before almost every instruction, so the opcode is
# read directly from the ROM or high-RAM array, and only candidate opcodes
# take the full path.

[[ -n "${_ASHBOY_LOOPSKIP_SH:-}" ]] && return 0
readonly _ASHBOY_LOOPSKIP_SH=1


# Opcode (decimal) -> register for DEC r. Sets _LS_REG, empty if not DEC r.
_loopskip_dec_reg() {
    _LS_REG=
    case $1 in
        5)  _LS_REG=B ;;   # 0x05
        13) _LS_REG=C ;;   # 0x0D
        21) _LS_REG=D ;;   # 0x15
        29) _LS_REG=E ;;   # 0x1D
        37) _LS_REG=H ;;   # 0x25
        45) _LS_REG=L ;;   # 0x2D
        61) _LS_REG=A ;;   # 0x3D
    esac
}


# Safety checks shared by both patterns. Returns 0 when a skip is allowed.
_loopskip_safe() {
    (( CPU_HALTED || CPU_HALT_BUG || CPU_IME_DELAY )) && return 1
    (( (MMU_IE & MMU_IF & 0x1F) == 0 )) || return 1
    (( TIMER_TAC & 0x04 )) && return 1
    return 0
}


# Pattern 2: LDH A,(n) ; AND A ; JR Z,-5 with the flag at FF00+n still zero.
_loopskip_poll() {
    local pc=$1 budget=$2 n m
    mmu_read8 $(( pc + 1 )); n=$REPLY                           # LDH A,(n)
    (( n >= 0x80 && n <= 0xFE )) || return 1                    # high RAM only
    mmu_read8 $(( pc + 2 )); (( REPLY == 0xA7 )) || return 1    # AND A
    mmu_read8 $(( pc + 3 )); (( REPLY == 0x28 )) || return 1    # JR Z
    mmu_read8 $(( pc + 4 )); (( REPLY == 0xFB )) || return 1    # offset -5: back to pc
    mmu_read8 $(( 0xFF00 + n )); (( REPLY == 0 )) || return 1   # flag still 0
    m=$(( budget / 28 ))                                        # whole passes only
    (( m >= 1 )) || return 1
    CPU_A=0
    CPU_F=$(( FLAG_Z | FLAG_H ))                                # AND A with A = 0
    (( GB_STEPS += 3 * m ))
    (( GB_SKIP_PASSES += m ))
    _CPU_CYCLES=$(( 28 * m ))
    timer_tick "$_CPU_CYCLES"
    return 0
}


# Pattern 1: [prefix] DEC r ; JR NZ back to the first byte.
#   $3 = prefix length (0 or 1). Each taken pass costs 16 cycles, plus 4 with a prefix.
_loopskip_countdown() {
    local pc=$1 budget=$2 prefix=$3 op off n res per h
    mmu_read8 $(( pc + prefix )); op=$(( REPLY ))
    _loopskip_dec_reg "$op"
    [[ -n $_LS_REG ]] || return 1
    mmu_read8 $(( pc + prefix + 1 )); (( REPLY == 0x20 )) || return 1   # JR NZ
    mmu_read8 $(( pc + prefix + 2 )); off=$(( REPLY ))
    (( off >= 128 )) && off=$(( off - 256 ))
    (( pc + prefix + 3 + off == pc )) || return 1                       # target is pc

    local -n _ls_reg="CPU_$_LS_REG"
    (( _ls_reg >= 2 )) || return 1                                      # need one pass to skip
    per=$(( 16 + 4 * prefix ))
    n=$(( budget / per ))                                               # whole passes only
    (( n > _ls_reg - 1 )) && n=$(( _ls_reg - 1 ))                       # counter stays >= 1
    (( n >= 1 )) || return 1

    res=$(( _ls_reg - n ))                                              # counter after n passes
    h=0
    (( (res & 0x0F) == 0x0F )) && h=$FLAG_H                             # half borrow on DEC
    _ls_reg=$res
    CPU_F=$(( (CPU_F & FLAG_C) | FLAG_N | h ))                          # Z clear, since res != 0
    (( GB_STEPS += n * (2 + prefix) ))
    (( GB_SKIP_PASSES += n ))
    _CPU_CYCLES=$(( n * per ))
    timer_tick "$_CPU_CYCLES"
    return 0
}


loopskip_try() {
    local budget=$1 pc=$CPU_PC b0 prefix=0

    (( budget >= 1 )) || return 1

    # Read the opcode directly from the array where possible (no function call).
    # $(( )) turns the value into a plain decimal number, so the case labels match.
    if (( pc < 0x4000 )); then
        b0=$(( ${CART_ROM[pc]:-0} ))                # ROM bank 0
    elif (( pc >= 0xFF80 && pc <= 0xFFFE )); then
        b0=$(( ${MMU_HRAM[pc - 0xFF80]:-0} ))       # high RAM
    else
        mmu_read8 "$pc"; b0=$(( REPLY ))            # switchable bank, work RAM, etc.
    fi

    case $b0 in
        240)                                        # F0: LDH A,(n), poll pattern
            _loopskip_safe || return 1
            _loopskip_poll "$pc" "$budget"
            return ;;
        0|64|73|82|91|100|109|127)                  # NOP or LD x,x, then DEC r
            prefix=1 ;;
        5|13|21|29|37|45|61)                        # DEC r, countdown pattern
            prefix=0 ;;
        *)  return 1 ;;                             # nothing to skip: the common case
    esac
    _loopskip_safe || return 1
    _loopskip_countdown "$pc" "$budget" "$prefix"
}
# Candidate filter for bank 0 (addresses 0x0000-0x3FFF).
# LS_CAND[addr] = 1 when the opcode at addr could start a loop that
# loopskip_try accepts. The filter only skips calls that would return 1
# anyway, so decisions do not change. ROM bytes never change, so the table
# stays valid for the whole run.
declare -ga LS_CAND=()

loopskip_build_filter() {
    local a b
    for (( a = 0; a < 0x4000; a++ )); do
        b=$(( ${CART_ROM[a]:-0} ))
        case $b in
            240|0|64|73|82|91|100|109|127|5|13|21|29|37|45|61) LS_CAND[a]=1 ;;
            *)                                                 LS_CAND[a]=0 ;;
        esac
    done
}
