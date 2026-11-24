#!/usr/bin/env bash
# AshBoy Joypad (0xFF00)
# Job: Track active-low button states, poll terminal keys, fire INT_JOYPAD

# Game Boy buttons are ACTIVE-LOW: 0 = pressed, 1 = released
[[ -n "${_ASHBOY_JOYPAD_SH:-}" ]] && return 0
_ASHBOY_JOYPAD_SH=1

# Button lines are active-low: a cleared bit means "pressed"
#   JOYPAD_DIR:    bit0 Right, bit1 Left, bit2 Up, bit3 Down
#   JOYPAD_ACTION: bit0 A,     bit1 B,    bit2 Select, bit3 Start
JOYPAD_SELECT=48          # 0x30: no group selected
JOYPAD_DIR=15
JOYPAD_ACTION=15
JOYPAD_QUIT=0
_JOY_RES=15

joypad_init() {
    JOYPAD_SELECT=48
    JOYPAD_DIR=15
    JOYPAD_ACTION=15
    JOYPAD_QUIT=0
}

# Called on writes to 0xFF00. Only bits 4-5 are writable.
joypad_write() {
    (( JOYPAD_SELECT = $1 & 0x30 ))
}

# Called on reads of 0xFF00. Result is placed in _MMU_VAL.
joypad_read() {
    _JOY_RES=15
    if (( (JOYPAD_SELECT & 0x10) == 0 )); then
        (( _JOY_RES &= JOYPAD_DIR ))       # direction group selected
    fi
    if (( (JOYPAD_SELECT & 0x20) == 0 )); then
        (( _JOY_RES &= JOYPAD_ACTION ))    # action group selected
    fi
    (( REPLY = 0xC0 | JOYPAD_SELECT | _JOY_RES ))
}

# Called once per frame. A key press stays latched for one frame, then clears.
joypad_begin_frame() {
    JOYPAD_DIR=15
    JOYPAD_ACTION=15
}

# Apply one printable key. $1 = the key character.
_joy_press() {
    case "$1" in
        w|W)            (( JOYPAD_DIR &= ~4 )) ;;     # Up
        s|S)            (( JOYPAD_DIR &= ~8 )) ;;     # Down
        a|A)            (( JOYPAD_DIR &= ~2 )) ;;     # Left
        d|D)            (( JOYPAD_DIR &= ~1 )) ;;     # Right
        z|Z)            (( JOYPAD_ACTION &= ~1 )) ;;  # A
        x|X)            (( JOYPAD_ACTION &= ~2 )) ;;  # B
        " ")            (( JOYPAD_ACTION &= ~4 )) ;;  # Select (Space)
        $'\x7f'|$'\b')  (( JOYPAD_ACTION &= ~4 )) ;;  # Select (Backspace)
        q|Q)            JOYPAD_QUIT=1 ;;
    esac
}

# Drain every key waiting in the terminal buffer so input never lags behind.
joypad_poll_terminal() {
    local key seq
    while :; do
        key=""
        # IFS= stops read from stripping a typed Space into an empty string
        if ! IFS= read -s -r -n 1 -t 0.001 key; then
            break                                  # buffer is empty
        fi

        if [[ -z "$key" ]]; then
            (( JOYPAD_ACTION &= ~8 ))              # Enter = Start
        elif [[ "$key" == $'\e' ]]; then
            seq=""
            IFS= read -s -r -n 2 -t 0.001 seq      # rest of arrow sequence, e.g. "[A"
            case "$seq" in
                "[A") (( JOYPAD_DIR &= ~4 )) ;;    # Up
                "[B") (( JOYPAD_DIR &= ~8 )) ;;    # Down
                "[C") (( JOYPAD_DIR &= ~1 )) ;;    # Right
                "[D") (( JOYPAD_DIR &= ~2 )) ;;    # Left
            esac
        else
            _joy_press "$key"
        fi

        (( MMU_IF |= 16 ))                         # request joypad interrupt
    done
}