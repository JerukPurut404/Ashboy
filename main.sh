#!/usr/bin/env bash
# AshBoy CLI Entry Point & Main Loop

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/ashboy/gameboy.sh"

SCALE=1
FRAMESKIP=0      # draw 1 frame out of every FRAMESKIP+1
FPS=10           # target frame rate; 0 = uncapped (never sleep)
HEADLESS=0
MAX_FRAMES=0     # 0 = run until Q
ROM_FILE=""

usage() {
    cat <<'EOF'
Usage: bash main.sh [options] <rom.gb>
  --scale <1|2>      Render scale (default: 1)
  --frameskip <N>    Draw only every (N+1)th frame (default: 0)
  --fps <N>          Frame-rate cap, 0 = uncapped (default: 10)
  --headless         No drawing and no key input (benchmarking)
  --frames <N>       Stop after N frames (default: unlimited)
  -h, --help         Show this help
EOF
    exit 0
}

while (( $# > 0 )); do
    case "$1" in
        --scale)      SCALE="$2"; shift 2 ;;
        --frameskip)  FRAMESKIP="$2"; shift 2 ;;
        --fps)        FPS="$2"; shift 2 ;;
        --sleep)      echo "Note: --sleep is ignored; use --fps N instead." >&2; shift 2 ;;
        --headless)   HEADLESS=1; shift ;;
        --frames)     MAX_FRAMES="$2"; shift 2 ;;
        -h|--help)    usage ;;
        -*)           echo "Error: unknown option '$1'" >&2; exit 1 ;;
        *)            ROM_FILE="$1"; shift ;;
    esac
done

if [[ -z "$ROM_FILE" || ! -f "$ROM_FILE" ]]; then
    echo "Error: ROM file not found: '$ROM_FILE'" >&2
    exit 1
fi

# Frame pacing (no forks: uses $EPOCHREALTIME)
NOW_US=0
NEXT_US=0
FRAME_US=0
if (( FPS > 0 )); then
    (( FRAME_US = 1000000 / FPS ))
fi

now_us() {
    (( NOW_US = 10#${EPOCHREALTIME//[^0-9]/} ))
}

# Sleep only for the time left in this frame's budget.
# If the emulator is slower than the cap, never sleep and resync the schedule.
pace_frame() {
    (( FPS > 0 )) || return 0
    now_us
    (( NEXT_US += FRAME_US ))
    local wait_us=$(( NEXT_US - NOW_US ))
    if (( wait_us > 0 )); then
        local wait_s
        printf -v wait_s '%d.%06d' $(( wait_us / 1000000 )) $(( wait_us % 1000000 ))
        LC_NUMERIC=C sleep "$wait_s"
    else
        (( NEXT_US = NOW_US ))
    fi
}

# Terminal setup and cleanup 
cleanup() {
    stty echo icanon 2>/dev/null
    printf '\e[?25h\e[0m\n'
}
trap cleanup EXIT INT TERM

if (( ! HEADLESS )); then
    stty -echo -icanon 2>/dev/null
    printf '\e[?25l\e[2J'
fi

gameboy_init
gameboy_load_rom "$ROM_FILE"
now_us
NEXT_US=$NOW_US

declare -g  HUD_TEXT=""
declare -gi HUD_FRAMES=0 HUD_DRAWN=0 HUD_T0=0 HUD_F0=0 HUD_D0=0
declare -gi HUD_EMU_FPS=0 HUD_DRAW_FPS=0

hud_tick() {
    (( HUD_FRAMES++ ))
    if (( RENDER_THIS_FRAME && ! HEADLESS )); then
        (( HUD_DRAWN++ ))
    fi
    now_us
    if (( HUD_T0 == 0 )); then
        HUD_T0=$NOW_US; HUD_F0=$HUD_FRAMES; HUD_D0=$HUD_DRAWN
    fi
    local dt=$(( NOW_US - HUD_T0 ))
    if (( dt >= 2000000 )); then
        # Emulated fps in whole frames per second; drawn rate in tenths
        (( HUD_EMU_FPS  = (HUD_FRAMES - HUD_F0) * 1000000 / dt ))
        (( HUD_DRAW_FPS = (HUD_DRAWN - HUD_D0) * 10000000 / dt ))
        HUD_T0=$NOW_US; HUD_F0=$HUD_FRAMES; HUD_D0=$HUD_DRAWN
    fi
    printf -v HUD_TEXT 'frame %d | %d fps (%d%% of real time) | drawn %d.%d/s | Q=quit' \
        "$HUD_FRAMES" "$HUD_EMU_FPS" $(( HUD_EMU_FPS * 100 / 60 )) \
        $(( HUD_DRAW_FPS / 10 )) $(( HUD_DRAW_FPS % 10 ))
}

# Main loop 
frame=0
while (( MAX_FRAMES == 0 || frame < MAX_FRAMES )); do
    joypad_begin_frame
    if (( ! HEADLESS )); then
        joypad_poll_terminal
    fi
    if (( JOYPAD_QUIT )); then
        break
    fi

    # Decide once per frame whether this frame is drawn
    if (( HEADLESS || frame % (FRAMESKIP + 1) != 0 )); then
        RENDER_THIS_FRAME=0
    else
        RENDER_THIS_FRAME=1
    fi

    gameboy_step_frame
    hud_tick

    if (( RENDER_THIS_FRAME && ! HEADLESS )); then
        ppu_present_ansi "$SCALE"
    fi

    pace_frame
    (( frame++ ))
done
(( HEADLESS )) && printf 'frames=%d steps=%d\n' "$frame" "$GB_STEPS" >&2