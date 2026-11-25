# AshBoy

A experimental Game Boy (DMG) emulator written in pure Bash. The picture is drawn in the terminal with half-block characters and ANSI colors.
Pure Bash is slow. AshBoy runs well below real time. See [Performance](#performance).

> **Status: experimental.** The CPU, timer, PPU, joypad, serial port, and interrupts run well enough for commercial games to boot and reach their title or menu screens. The main limit is speed: the emulator runs about 24 times slower than a real Game Boy. There is no audio yet. Keyboard play through a menu has not been confirmed end to end.

---

## Contents

1. [Requirements](#requirements)
2. [Quick start](#quick-start)
3. [Controls](#controls)
4. [Command-line options](#command-line-options)
5. [Project layout](#project-layout)
6. [Architecture](#architecture)
7. [Hardware status](#hardware-status)
8. [Memory map](#memory-map)
9. [Interrupts and timing](#interrupts-and-timing)
10. [Performance](#performance)
11. [Testing and diagnostics](#testing-and-diagnostics)
12. [Troubleshooting](#troubleshooting)
13. [Coding rules](#coding-rules)
14. [Known limitations](#known-limitations)
15. [Next steps](#next-steps)

---

## Project progress

Percentages are rough estimates. The two speed rows are measured.

```
CPU instructions (incl. CB prefix)  ███████████████████░  95%
Interrupts and timer                ██████████████████░░  90%
Keyboard input (joypad)             ██████████████████░░  90%
PPU: background, window, sprites    █████████████████░░░  85%
Terminal display                    █████████████████░░░  85%
Memory bus and cartridge            ████████████████░░░░  80%
Serial port                         ████████████████░░░░  80%
Sound (APU)                         ░░░░░░░░░░░░░░░░░░░░   0%
Speed, headless (18 of 60 FPS)      ██████░░░░░░░░░░░░░░  30%
Speed, playable (3 of 60 FPS)       █░░░░░░░░░░░░░░░░░░░   5%
```

## Requirements

- **Bash 5.0 or newer.** Frame pacing reads `$EPOCHREALTIME`, which Bash added in 5.0. The original target was Bash 4.3, which no longer holds. Check with `bash --version`.
- A terminal that supports ANSI escape codes. Running the emulator in a larger window gives a clearer picture.
- Standard Linux tools only for the core run: `stty`, `sleep`, and `md5sum` (used by diagnostics). No `jq`, `awk`, `bc`.
- A Game Boy ROM file that you own. ROMs are not included.

## Quick start

Run all commands from the project root, the folder that contains `main.sh`.

```bash
cd ~/Downloads/Ashboy/ashboy

# 1. Run the test suite (expect "Tests run: 18 | Failed: 0")
bash tests/test_check.sh

# 2. Play (nice lowers the CPU priority so the rest of the system stays responsive)
nice -n 19 bash main.sh --scale 1 --frameskip 2 --fps 0 "rom.gb"
```

Press **Q** to quit. The terminal is restored on exit, even after a crash.

## Controls

| Game Boy | Keyboard |
|---|---|
| D-pad | Arrow keys or W A S D |
| A | Z |
| B | X |
| Start | Enter |
| Select | Space or Backspace |
| Quit emulator | Q |

Each key press is latched for one emulated frame. Keys are drained from the terminal buffer at the start of every frame, so input is not delayed by the rendering.

## Command-line options

```
bash main.sh [options] ROM_FILE
```

| Option | Default | Meaning |
|---|---|---|
| `--scale N` | `1` | Picture scale for the terminal renderer. |
| `--frameskip N` | `4` | Draw one frame in every N+1. The other frames are emulated but not drawn. |
| `--fps N` | `10` | Frame-rate cap. `0` means uncapped, and the emulator never sleeps. |
| `--headless` | off | No drawing and no keyboard input. On exit, prints `frames=N steps=N` to stderr. Used for benchmarks. |
| `--frames N` | `0` | Stop after N frames. `0` means run until Q. |
| `--serial` | off | Print characters sent through the serial port. Check `bash main.sh --help` to confirm this flag is in your version. |
| `--sleep N` | n/a | Ignored. Prints a note. Replaced by `--fps`. |
| `-h`, `--help` | | Show help. |

Unknown options print an error and exit.

**Note on `--fps`:** at the current speed (about 2.5 FPS), the cap never engages, so the emulator runs flat out. The cap matters only once the emulator is fast enough to exceed it.

## The status line

The bottom line shows the cartridge title and live statistics:

```
[AshBoy] TITLE | frame N | X fps (Y% of real time) | drawn Z/s | Q=quit
```

- **frame N:** emulated frames since start.
- **X fps:** emulated frames per second over the last interval.
- **Y% of real time:** X divided by 60. Real Game Boy speed is about 59.7 frames per second.
- **drawn Z/s:** frames written to the terminal per second.


## Project layout

```
ashboy/                     project root (run commands from here)
├── main.sh                 entry point: options, terminal setup, main loop, pacing
├── README.md               this file
├── tests/
│   ├── test_ashboy.sh      18 unit tests across five groups
│   └── test_check.sh       runs the suite; fails on "command not found" or "unbound variable"
└── ashboy/                 hardware modules, one component per file
    ├── init.sh             constants, flag lookup tables, shared globals
    ├── gameboy.sh          system wiring: frame, scanline, and step functions
    ├── cpu.sh              SM83 CPU: registers, opcode dispatch table, handlers, CB prefix
    ├── interrupts.sh       interrupt selection, priority, and dispatch
    ├── mmu.sh              memory bus: read and write routing, serial port, OAM DMA
    ├── cartridge.sh        ROM loading, MBC1/MBC3 banking, cartridge RAM and .sav files
    ├── ppu.sh              picture processing: scanline renderer, LCD state, terminal output
    ├── timer.sh            DIV, TIMA, TMA, TAC, and the timer interrupt
    └── joypad.sh           button state (P1 register) and terminal key mapping
```

Each module starts with an include guard (for example `_ASHBOY_MMU_SH`), so sourcing it twice is harmless.

## Architecture

One frame is 154 scanlines. Each scanline runs instructions until it has used 456 clock cycles.

```
main.sh
 ├─ joypad_begin_frame / joypad_poll_terminal   read keys (skipped when headless)
 ├─ gameboy_step_frame                          154 scanlines
 │   └─ gameboy_step_scanline                   456 cycles per line
 │       ├─ gameboy_step                        one instruction, or one interrupt
 │       │   ├─ interrupts_service              if IE & IF & 0x1F is nonzero and IME is set
 │       │   └─ cpu_step -> OP_FN[opcode]       opcode handler from the dispatch table
 │       ├─ timer_tick(cycles)
 │       └─ ppu_render_scanline                 only on drawn frames, for LY < 144
 ├─ ppu_present_ansi "$SCALE"                   only on drawn frames
 └─ pace_frame                                  sleep for the rest of the frame budget
```

**Timing.** The Game Boy clock runs at 4,194,304 cycles per second. A frame is 154 scanlines of 456 cycles each, or 70,224 cycles. Scanlines 0 to 143 are visible. Scanline 144 starts V-Blank and sets the V-Blank interrupt flag.

**Stepping.** `gameboy_step_scanline` runs CPU instructions until 456 cycles have passed. The timer advances with every instruction. At the end of each line, the PPU renders the line into a 160 × 144 framebuffer of shade indexes.

**Output.** `ppu_present_ansi` combines pairs of framebuffer rows into half-block characters and prints the whole frame with one `printf` call. The frame is redrawn in place with `ESC[H`, so the terminal is never cleared.

**CPU dispatch.** A 256-entry table, `OP_FN`, maps each opcode to a handler function. Opcodes with the `CB` prefix go through `op_cb`.

**Idle-loop skip.** Game-independent note: the skip applies to one busy-wait loop in one ROM, at address `0x02ED`. It waits for a flag that the V-Blank handler sets. When the loop is detected, the emulator advances time in one jump instead of running each pass. It runs only when the ROM bytes at the loop match exactly and all of these hold: no interrupt is pending, the timer is disabled, no EI delay is active, and the HALT bug is not active. With `GB_SKIP=0`, the CPU, memory, and framebuffer state are identical. This was checked over 60 and 600 frames. Other ROMs are not affected; they run at normal speed.

**Data flow.** Modules communicate through global variables. Functions that return a value write it to `REPLY`, or to a named global such as `_RR` or `_ROT_RES`. Hardware state is held in globals with names like `CPU_A`, `PPU_LY`, and `MMU_IF`.

**Dispatch.** `cpu_build_tables` fills `OP_FN[256]`, a global array that maps each opcode to a handler function name. `cpu_step` fetches the opcode and calls `${OP_FN[opcode]}`. Ranges such as `0x40-0x7F` (LD r,r) and `0x80-0xBF` (ALU) are filled in bulk, and individual opcodes are mapped last.

## Hardware status

| Component | File | Status |
|---|---|---|
| CPU (SM83) | `cpu.sh` | Full base opcode table, CB prefix, HALT, EI delay, HALT bug. Tested for ALU, flags, CB, and stack. Commercial games runs on it. |
| Interrupts | `interrupts.sh` | Five sources, lowest bit has priority. Clears IME and the IF bit on dispatch. Wakes the CPU from HALT. |
| Memory bus | `mmu.sh` | Full map. Joypad, serial, timer, PPU, and interrupt registers routed. OAM DMA implemented. |
| Cartridge | `cartridge.sh` | ROM-only, MBC1, and MBC3 banking. Cartridge RAM saved to a `.sav` file. Other mappers (for example MBC5) are not verified. |
| PPU | `ppu.sh` | Background, window, and sprites (10 per line). LCDC, STAT, LYC, palettes, scroll. Renders to a 160×144 framebuffer. |
| Terminal output | `ppu.sh` | Half-block characters (`▀`) with a single buffered `printf` per frame. |
| Timer | `timer.sh` | DIV, TIMA, TMA, TAC, overflow reload, and the timer interrupt. |
| Joypad | `joypad.sh` | All eight buttons, P1 register verified (test read returned `0xDE` as expected for A pressed). |
| Serial | `mmu.sh` | SB and SC. Internal-clock transfer appends to `SERIAL_OUTPUT`. |
| Sound (APU) | none | Not implemented. |
| Game Boy Color | none | Not implemented. DMG only. |

## Memory map

| Address | Region | Where it lives |
|---|---|---|
| `0000–3FFF` | ROM bank 0 | `CART_ROM` (direct index) |
| `4000–7FFF` | ROM bank N (switchable) | `CART_ROM`, offset by `CART_ROM_BANK` |
| `8000–9FFF` | Video RAM | `PPU_VRAM` (index = address − 32768) |
| `A000–BFFF` | External (cartridge) RAM | `cartridge_read_ram` / `cartridge_write_ram` |
| `C000–DFFF` | Work RAM | `MMU_WRAM` |
| `E000–FDFF` | Echo RAM | Mirror of `MMU_WRAM` |
| `FE00–FE9F` | OAM (sprite table) | `PPU_OAM` |
| `FEA0–FEFF` | Unusable | Reads return `0xFF`; writes ignored |
| `FF00–FF7F` | I/O registers | Individual globals (`MMU_IF`, `PPU_LY`, …) and `MMU_IO` for the rest |
| `FF80–FFFE` | High RAM | `MMU_HRAM` |
| `FFFF` | Interrupt enable (IE) | `MMU_IE` |

Bank 0 maps directly to file offsets. For example, `0x0040` is file offset 64.

## Interrupts and timing

| Bit | Source | Vector | Set by |
|---|---|---|---|
| 0 | V-Blank | `0x0040` | `gameboy_step_scanline` at LY 144 |
| 1 | LCD STAT | `0x0048` | PPU (generation not fully verified) |
| 2 | Timer | `0x0050` | `timer_tick` on TIMA overflow |
| 3 | Serial | `0x0058` | Transfer complete |
| 4 | Joypad | `0x0060` | `joypad_poll_terminal` on any key |

Timing constants:

- 456 cycles per scanline, 154 scanlines per frame, so 70,224 cycles per frame.
- Real hardware runs at about 59.7 frames per second, which is 16.7 ms per frame.
- The emulator counts instructions, not cycles. Commercial games executes about 8,191 instructions per frame.
- `TIMER_DIV` increments every 256 cycles. TIMA periods are 1024, 16, 64, and 256 cycles, selected by TAC bits 0–1.

## Performance

Measured on a ThinkPad E14 Gen 5 with Bash 5, 20 frames:

| Mode | Command | Time | Per frame |
|---|---|---|---|
| Headless (CPU only) | `--headless --fps 0 --frames 20 <rom>` | 8.0 s | 0.40 s (about 2.5 FPS) |
| Drawn every frame | `--frameskip 0 --fps 0 --frames 20 <rom>` | 19.2 s | 0.96 s (about 1 FPS) |

- **Steps:** 163,821 for 20 frames, about 46 µs per instruction.
- **Real time:** 16.7 ms per frame. The headless emulator is about 24 times slower.
- **Drawing cost:** about 0.55 s per drawn frame. With the default `--frameskip 4`, the average is about 0.5 s per frame.
- **Where the time goes:** about 88% of executed instructions are a V-Blank wait loop at `0x02ED–0x02F0`, which polls `FF85`. Bash function-call overhead dominates each instruction.
- **Benchmark history:** the table rewrite took the headless run from 18.2 s to 7.6 s (2.4×). Later changes (`ppu_render_scanline` without `local`) changed drawing time by about 2%.

Benchmark commands:

```bash
time bash main.sh --headless --fps 0 --frames 20 "<rom>.gb"
time bash main.sh --fps 0 --frames 20 --frameskip 0 "<rom>.gb" > /dev/null
```

## Testing and diagnostics

### Regression tests

`tests/test_ashboy.sh` has 18 tests:

| Group | Checks |
|---|---|
| `test_cpu_alu_and_flags` | LD, ADD, half-carry, SUB, zero and subtract flags |
| `test_cb_prefix_and_stack` | CB SWAP, POP AF low nibble masked to zero |
| `test_timer_and_interrupt_dispatch` | HALT, TIMA reload from TMA, IF bit, wake from HALT, vector `0x0050`, IME cleared on entry |
| `test_serial_hello_rom` | Serial transfer captures `OK` |
| `test_ppu_vblank` | LY reaches 144, frame ready, V-Blank interrupt fires |

`tests/test_check.sh` runs the suite and treats any `command not found` or `unbound variable` line as a failure, even if the individual assertions pass.

### Regression fingerprints

These values are known-good for the current code. If one changes after an edit, the edit changed behavior.

| Check | Command | Expected |
|---|---|---|
| Instruction count | `bash main.sh --headless --fps 0 --frames 20 "<rom>.gb"` | `steps=163821` |
| Framebuffer hash | Run 60 frames, then `md5sum` of the framebuffer (see below) | `410f603a31fa55061cbdc000a36790a0` |

Framebuffer hash command:

```bash
bash -c 'source ashboy/gameboy.sh; gameboy_init; gameboy_load_rom "<rom>.gb"; for ((f=0;f<60;f++)); do gameboy_step_frame; done; printf "%s" "${PPU_FRAMEBUFFER[*]}" | md5sum'
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `NAME: command not found` | Function renamed or removed, or module not sourced | Run `tests/test_check.sh`. Check the name with `grep -n "NAME()" ashboy/*.sh`. |
| `NAME: unbound variable` | Global used before it is declared, under `set -u` | Declare it with a default: `declare -gi NAME=0`. |
| `value too great for base (error token is "066803")` | Locale uses a comma decimal separator, so `$EPOCHREALTIME` contains a comma | `now_us` must use `${EPOCHREALTIME//[^0-9]/}`. |
| `sleep: invalid time interval` | Same comma issue, in `sleep` | Call `LC_NUMERIC=C sleep "$wait_s"`. |
| `ppu_present_terminal: command not found` | Old function name | The name is `ppu_present_ansi`. Call it as `ppu_present_ansi "$SCALE"`. |
| Screen stays blank | Renderer never called, or LCD off | Check `grep -n "ppu_present" main.sh`. |
| Keys do nothing | Input not reaching the game | Run the P1 test below. |
| Terminal has no echo or cursor after a crash | Cleanup trap did not run | Run `stty echo icanon; printf '\e[?25h\e[0m'`. |
| Very slow | Expected at current speed | See [Performance](#performance). |

**P1 input test** (no terminal needed):

```bash
printf z | bash -c 'source ashboy/init.sh; source ashboy/mmu.sh; mmu_init; joypad_begin_frame; joypad_poll_terminal; mmu_write8 65280 16; mmu_read8 65280; echo "P1=$REPLY (expect 222)"'
```

`222` means A is read correctly through the bus.

## Coding rules

These rules come from bugs found during development. Follow them when changing the code.

1. **Bash 5.0 or newer.** `$EPOCHREALTIME` requires it.
2. **Include guards.** Each module starts with `[[ -n "${_ASHBOY_X_SH:-}" ]] && return 0`.
3. **`set -u` only, never `set -e`.** `(( 0 ))` returns status 1, which aborts the script.
4. **Decimal case labels.** Write `65280)` in `case`, not `0xFF00)`. Hex labels never match.
5. **Return values in `REPLY`** or a named global. Do not return values with `echo` or `$(...)`.
6. **No forks in hot loops.** Avoid `$(...)`, pipes, `date`, `expr`, `seq`, `wc`, `grep`, and `awk` inside the emulation loop. Use builtins only.
7. **Keep `local` out of per-pixel and per-instruction loops.** Declare variables once at the top of the function.
8. **Read keys with `IFS= read -s -r -n 1 -t 0.001 key`.** Without `IFS=`, a typed space is stripped and becomes an empty string, which is the Enter key.
9. **Always restore the terminal.** The `trap` must run `stty echo icanon` and `printf '\e[?25h\e[0m'`.
10. **Check the output after every change.** Run the tests, then the step count and framebuffer hash.

**Names that must not come back.** They were removed after causing "command not found" errors:
`cpu_exec_cb` (now `op_cb`), `cpu_execute_op`, `timer_step` (now `timer_tick`), `mmu_write` (now `mmu_write8`), `ppu_present_terminal` (now `ppu_present_ansi`). Also do not reintroduce `--sleep` pacing or `clear` per frame.

## Known limitations

- **No sound.** The audio hardware is not emulated at all. Implementing it would need real-time timing, which the emulator does not reach yet.
- **Original Game Boy (DMG) only.** Game Boy Color games will not run; the console mode and its extra hardware are not supported.
- **Limited mappers.** Only ROM-only, MBC1, and MBC3 cartridges are covered. ROMs using other mappers are untested and will likely fail to load or misbehave.
- **Speed.** Performance is far below real time: a few FPS headless and slower still with the display on, against the real console's 59.7 FPS. Pure Bash is unlikely to ever reach real time.
- **Idle-loop skip is ROM-specific.** The skip applies to one polling loop at one address, tuned for the tested game. Other ROMs run without it and pay the full cost of the idle loop.
- **STAT interrupt.** The vector exists, but the conditions that raise it are not fully verified.
- **Tested with few ROMs.** Behaviour beyond the handful of tested games is unknown; other titles may expose bugs the emulator does not handle yet.

## Next steps

1. **Speed up `ppu_render_scanline`.** It is the single largest cost in a drawn frame, about 0.36 s. Optimising it is the biggest lever on overall framerate.
2. **Measure `ppu_present_ansi 2`.** Count and reduce the characters written per frame at scale 2 — fewer escape sequences and ideally a single `printf` per frame.
3. **Generalize the idle-loop skip.** Either detect the pattern automatically or document how to add a skip entry for another ROM, so the technique is not limited to one hardcoded address.
4. **Check WRAM and HRAM first in the memory bus.** Move these high-frequency checks to the top of `mmu_read8` and `mmu_write8`, confirm `steps=163821` and the framebuffer hash stay unchanged, then measure the gain.
5. **Add a skip regression test.** Write an automated test that takes the ROM path as an argument, so the idle-loop skip stays verified as the code evolves.
6. **Remove the `--sleep` stub** once nothing depends on it.
7. **Decide the speed ceiling.** Staying in pure Bash is the current choice; the alternative is rewriting the CPU, PPU, and bus in a compiled language and keeping Bash for the UI. That breaks the pure-Bash requirement, so the decision belongs to the project owner.
8. **Sound.** Not planned. It depends on real-time timing, which in turn depends on how item 7 is resolved.

## Credits

The hardware behavior follows the Game Boy (DMG) technical reference. Community documentation especially the Pan Docs and the hardware test suites published by emulator developers has made this project possible.

**Disclaimer:** This is a fan-made, educational project and is not affiliated with, endorsed by, or sponsored by Nintendo. "Nintendo" and "Game Boy" are trademarks of Nintendo Co., Ltd. No original Nintendo ROMs, BIOS images, or other copyrighted material are included in this repository. Users must supply their own game files and are responsible for complying with copyright law in their jurisdiction. Nintendo remains protective of its intellectual property - please support official releases.
