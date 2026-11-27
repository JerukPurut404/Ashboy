# AshBoy

An experimental Game Boy (DMG) emulator written in pure Bash. The picture is drawn in the terminal with half-block characters and ANSI colors.

Pure Bash is slow. AshBoy runs well below real time. See [Performance](#performance).

> **Status: experimental.** The CPU, timer, PPU, joypad, serial port, and interrupts run well enough for commercial games to boot and reach their title or menu screens. Keyboard input has been confirmed in-game on the test ROM. The main limit is speed: with the display on at default settings the emulator runs about 12 times slower than a real Game Boy, and about 2.4 times slower with the display off. There is no audio yet.

---

## Contents

1. [Requirements](#requirements)
2. [Quick start](#quick-start)
3. [Controls](#controls)
4. [Command-line options](#command-line-options)
5. [The status line](#the-status-line)
6. [Project layout](#project-layout)
7. [Architecture](#architecture)
8. [Hardware status](#hardware-status)
9. [Memory map](#memory-map)
10. [Interrupts and timing](#interrupts-and-timing)
11. [Performance](#performance)
12. [Testing and diagnostics](#testing-and-diagnostics)
13. [Troubleshooting](#troubleshooting)
14. [Coding rules](#coding-rules)
15. [Known limitations](#known-limitations)
16. [Next steps](#next-steps)

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
Speed, headless (25 of 60 FPS)      ████████░░░░░░░░░░░░  42%
Speed, playable (5 of 60 FPS)       ██░░░░░░░░░░░░░░░░░░   8%
Speed, storm scene (2 of 60 FPS)    █░░░░░░░░░░░░░░░░░░░   3%
```

---

## Requirements

- **Bash 5.0 or newer.** Frame pacing reads `$EPOCHREALTIME`, which Bash added in 5.0. Check with `bash --version`.
- A terminal that supports ANSI escape codes and UTF-8. A larger window gives a clearer picture. Minimum sizes: 80 × 37 characters at scale 1, 160 × 73 at scale 2.
- Standard Linux tools: `stty`, `sleep`, `md5sum` (diagnostics), and coreutils `cut`, `cp`, `mktemp`. No `jq`, `awk`, or `bc`.
- `git` for `tests/test_render_equiv.sh`, which reads the reference commit from the repository.
- A Game Boy ROM file that you own. ROMs are not included.

## Quick start

Run all commands from the project root, the folder that contains `main.sh`.

```bash
# 1. Run the unit tests (expect "Tests run: 18 | Failed: 0")
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
| `--sleep N` | n/a | Ignored. Prints a note. Replaced by `--fps`. |
| `-h`, `--help` | | Show help. |

Unknown options print an error and exit.

**Note on `--fps`:** the default cap of 10 FPS applies to headless runs too. Headless steady state is about 25 FPS, so a headless run with the default cap is limited to 10 FPS. Benchmarks must use `--fps 0`. When drawing, the emulator runs at about 5 FPS, below the cap, so the cap does not engage.

## The status line

The bottom line shows the cartridge title and live statistics:

```
[AshBoy] TITLE | frame N | X fps (Y% of real time) | drawn Z.Z/s | Q=quit
```

- **frame N:** emulated frames since start.
- **X fps:** emulated frames per second over the last two seconds.
- **Y% of real time:** X divided by 60. Real hardware runs at about 59.7 frames per second.
- **drawn Z.Z/s:** frames written to the terminal per second, shown in tenths.

## Project layout

```
ashboy/                          project root (run commands from here)
├── main.sh                      entry point: options, terminal setup, main loop, pacing
├── README.md                    this file
├── tests/
│   ├── test_ashboy.sh           18 unit tests across five groups
│   ├── test_check.sh            runs the unit tests; fails on "command not found" or "unbound variable"
│   ├── test_skip_equivalence.sh runs a ROM with the loop skip off and on, compares state and framebuffer
│   ├── test_render_equiv.sh     compares the renderer with a reference commit on random PPU states
│   └── render_cases.sh          random PPU state generator used by test_render_equiv.sh
└── ashboy/                      hardware modules, one component per file
    ├── init.sh                  constants, flag lookup tables, shared globals
    ├── gameboy.sh               system wiring: frame, scanline, and step functions
    ├── cpu.sh                   SM83 CPU: registers, opcode dispatch table, handlers, CB prefix
    ├── interrupts.sh            interrupt selection, priority, and dispatch
    ├── mmu.sh                   memory bus: read and write routing, serial port, OAM DMA
    ├── cartridge.sh             ROM loading, MBC1/MBC3 banking, cartridge RAM and .sav files
    ├── ppu.sh                   scanline renderer, LCD state, framebuffer, terminal output
    ├── timer.sh                 DIV, TIMA, TMA, TAC, and the timer interrupt
    ├── joypad.sh                button state (P1 register) and terminal key mapping
    └── loopskip.sh              exact skip of two idle-loop shapes, detected by opcode pattern
```

Each module starts with an include guard (for example `_ASHBOY_MMU_SH`), so sourcing it twice is harmless. Local diagnostic scripts named `probe*.sh` are not part of the repository; `.gitignore` excludes them.

## Architecture

One frame is 154 scanlines. Each scanline runs instructions until it has used 456 clock cycles.

```
main.sh
 ├─ joypad_begin_frame / joypad_poll_terminal   read keys (skipped when headless)
 ├─ gameboy_step_frame                          154 scanlines
 │   └─ gameboy_step_scanline                   456 cycles per line
 │       ├─ loopskip_try                        at candidate addresses only; exact skip of an idle loop
 │       ├─ gameboy_step                        one instruction, or one interrupt
 │       │   ├─ interrupts_service              if IE & IF & 0x1F is nonzero and IME is set
 │       │   └─ cpu_step -> OP_FN[opcode]       opcode handler from the dispatch table
 │       ├─ timer_tick(cycles)
 │       └─ ppu_render_scanline                 only on drawn frames, for LY < 144
 ├─ ppu_present_ansi "$SCALE"                   only on drawn frames
 └─ pace_frame                                  sleep for the rest of the frame budget
```

**Timing.** The Game Boy clock runs at 4,194,304 cycles per second. A frame is 154 scanlines of 456 cycles each, or 70,224 cycles. Scanlines 0 to 143 are visible. Scanline 144 starts V-Blank and sets the V-Blank interrupt flag.

**Stepping.** `gameboy_step_scanline` runs CPU instructions until 456 cycles have passed. The timer advances with every instruction. At the end of each visible line, the PPU renders the line.

**Framebuffer.** `PPU_FRAMEBUFFER` holds 144 rows. Each row is one 160-character string of shade digits (0 to 3). Background and window lines are built from 8-pixel tile rows cached by their two bytes and palette. Sprites are written into the line string. `ppu_fb_flat` produces the flat text used for hashing; it stores the result in `PPU_FLAT`.

**Output.** `ppu_present_ansi` combines pairs of framebuffer rows into half-block characters and prints the whole frame with one `printf` call. The frame is redrawn in place with `ESC[H`, so the terminal is never cleared.

**Segment cache.** Background and window segments are converted to shade and colour strings once and reused. `ppu_fetch_segment` stores each result under a key made of its arguments and `PPU_BGP`. `PPU_VRAM_GEN` is a generation counter. It moves only when a VRAM byte really changes, in the VRAM branch of `mmu_write8`, and the cache is emptied whenever it moves. The cache is also emptied if it grows past 4096 entries. Set `GB_SEG_CACHE=0` to turn it off. The output is identical either way, and the equivalence tests check that.

Measured on a ROM with a static background: 40 drawn frames at `--frameskip 0` took 13.6 s on average with the cache off and 11.4 s with it on (three runs each). On a second ROM with frequent VRAM writes, 94.5% of segment lookups over 900 frames were reusable, but that ROM has not been timed yet, so its saving is unknown.

**CPU dispatch.** A 256-entry table, `OP_FN`, maps each opcode to a handler function. Opcodes with the `CB` prefix go through `op_cb`. Ranges such as `0x40-0x7F` (LD r,r) and `0x80-0xBF` (ALU) are filled in bulk, and individual opcodes are mapped last.

**Loop skip.** At load time, `loopskip_build_filter` scans bank 0 for two loop shapes. They are recognized by their opcode pattern, not by address:

- **Poll loop:** load a hardware register or high-RAM byte, test it, and branch back while the result is zero.
- **Countdown loop:** an optional no-op prefix, a decrement of a register, and a branch back while the register is nonzero.

When the stepper reaches a candidate address and the bytes match, `loopskip_try` checks the conditions: no interrupt pending, timer disabled, no EI delay active, and no HALT bug. It then advances whole loop passes in one step, updating the cycle count, the step count, the registers and the flags exactly as instruction-by-instruction stepping would. Cycles left at the end of a scanline are simulated one instruction at a time, so every scanline boundary matches.

Loops in the switchable ROM bank (`0x4000–0x7FFF`) are never skipped. They run at full cost.

The skip is exact. `tests/test_skip_equivalence.sh` runs a ROM with the skip off and on, and fails on any difference in registers, I/O, memory, VRAM, or framebuffer.

**Data flow.** Modules communicate through global variables. Functions that return a number write it to `REPLY`. Functions that return text write it to a named global such as `PPU_FLAT`. Hardware state is held in globals with names like `CPU_A`, `PPU_LY`, and `MMU_IF`.

## Hardware status

| Component | File | Status |
|---|---|---|
| CPU (SM83) | `cpu.sh` | Full base opcode table, CB prefix, HALT, EI delay, HALT bug. Tested for ALU, flags, CB, and stack. |
| Interrupts | `interrupts.sh` | Five sources, lowest bit has priority. Clears IME and the IF bit on dispatch. Wakes the CPU from HALT. |
| Memory bus | `mmu.sh` | Full map. Joypad, serial, timer, PPU, and interrupt registers routed. OAM DMA implemented. |
| Cartridge | `cartridge.sh` | ROM-only, MBC1, and MBC3 banking. Cartridge RAM saved to a `.sav` file. Other mappers (for example MBC5) are not verified. |
| PPU | `ppu.sh` | Background, window, and sprites (10 per line). LCDC, STAT, LYC, palettes, scroll. Sprites are drawn in OAM order; see [Known limitations](#known-limitations). |
| Terminal output | `ppu.sh` | Half-block characters (`▀`) with a single buffered `printf` per frame. |
| Timer | `timer.sh` | DIV, TIMA, TMA, TAC, overflow reload, and the timer interrupt. |
| Joypad | `joypad.sh` | All eight buttons. P1 register verified: a read with A pressed returns `0xDE`. |
| Serial | `mmu.sh` | SB and SC. Internal-clock transfer appends to `SERIAL_OUTPUT`. |
| Loop skip | `loopskip.sh` | Two loop shapes, exact, verified over 60 and 600 frames. Never applies in the switchable bank. |
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
| 1 | LCD STAT | `0x0048` | PPU (conditions not fully verified) |
| 2 | Timer | `0x0050` | `timer_tick` on TIMA overflow |
| 3 | Serial | `0x0058` | Transfer complete |
| 4 | Joypad | `0x0060` | `joypad_poll_terminal` on any key |

Timing constants:

- 456 cycles per scanline, 154 scanlines per frame, so 70,224 cycles per frame.
- Real hardware runs at about 59.7 frames per second, which is 16.7 ms per frame.
- The emulator counts instructions for benchmarks. For the test ROM, the first 20 frames run 163,821 instructions (about 8,191 per frame on average, including boot). Steady state after boot is about 7,536 instructions per frame.
- `TIMER_DIV` increments every 256 cycles. TIMA periods are 1024, 16, 64, and 256 cycles, selected by TAC bits 0–1.

## Performance

Measured on a ThinkPad E14 Gen 5 with Bash 5. Times are wall-clock. Per-frame figures are averages unless marked otherwise.

### Headless (display off)

| Measurement | Frames | Time | Per frame |
|---|---|---|---|
| From power-on, `--headless --fps 0 --frames 60` | 60 | 7.77 s | 130 ms, including boot |
| Boot and logo wait (frames 0–19) | 20 | 5.48 s | 274 ms |
| Steady state (20-frame blocks after frame 20) | 20 | 0.78–0.95 s | 39–47 ms |

Steady state is about 25 FPS, about 2.4 times slower than real time.

### Drawn (display on)

| Measurement | Frames | Time | Result |
|---|---|---|---|
| `--frameskip 4` (default), scale 1 | 60 (12 drawn) | 11.32 s | 3.55 s more than headless, about 0.30 s per drawn frame |
| `--frameskip 0`, scale 1 (HUD reading) | steady | n/a | 2.9 drawn/s, about 345 ms per drawn frame |
| `--frameskip 0`, scale 2 (HUD reading) | steady | n/a | 1.6 drawn/s, about 625 ms per drawn frame |

- **Scale 2 cost:** about 0.28 s more per drawn frame than scale 1. Of that, about 0.11 s is building the output string (`ppu_present_ansi 2` measured at 114 ms per call).
- **Terminal paint time is not measured.** The benchmarks write to `/dev/null`, so the time the terminal takes to draw is not included.
- **The string renderer is not yet timed.** Commit `2433b0c` changed how lines are stored. The drawn numbers above were measured before that commit. Re-measure before comparing.

### Steps and benchmark history

- **Steps:** 163,821 instructions for 20 frames, 465,261 for 60, and 4,558,653 for 600. The count is identical with the loop skip on or off.
- **Table rewrite:** headless 20-frame time fell from 18.2 s to 7.6 s (2.4×).
- **Loop skip:** steady idle frames fell from about 60 ms to about 40 ms headless. Real instructions in an idle frame fell from about 714 to about 278.
- **Row-cache renderer:** renderer time per frame fell from about 360–395 ms to about 298 ms.
- **String renderer (`2433b0c`):** not yet measured.

### Benchmark commands

```bash
ROM="rom.gb"
time bash main.sh --headless --fps 0 --frames 20 "$ROM"
time bash main.sh --headless --fps 0 --frames 40 "$ROM"
time bash main.sh --fps 0 --frames 20 --frameskip 0 "$ROM" > /dev/null
time bash main.sh --fps 0 --frames 40 --frameskip 0 "$ROM" > /dev/null
```

Subtract the 20-frame time from the 40-frame time to remove boot cost. Divide the difference by 20 to get the per-frame time. The drawn runs need the output sent to `/dev/null`, or the terminal paint time is added to the result.

## Testing and diagnostics

### Unit tests

`tests/test_ashboy.sh` has 18 tests:

| Group | Checks |
|---|---|
| `test_cpu_alu_and_flags` | LD, ADD, half-carry, SUB, zero and subtract flags |
| `test_cb_prefix_and_stack` | CB SWAP, POP AF low nibble masked to zero |
| `test_timer_and_interrupt_dispatch` | HALT, TIMA reload from TMA, IF bit, wake from HALT, vector `0x0050`, IME cleared on entry |
| `test_serial_hello_rom` | Serial transfer captures `OK` |
| `test_ppu_vblank` | LY reaches 144, frame ready, V-Blank interrupt fires |

`tests/test_check.sh` runs the suite and treats any `command not found` or `unbound variable` line as a failure, even if the individual assertions pass.

### Equivalence checks

**Emulator state, loop skip on and off:**

```bash
bash tests/test_skip_equivalence.sh "rom.gb" 60
bash tests/test_skip_equivalence.sh "rom.gb" 600
```

The 600-frame run takes several minutes. Each run prints the registers, I/O, memory, VRAM, and framebuffer hashes for both modes, and reports the number of skips taken. It fails if any value differs, or if the skip never fired.

**Renderer, against a reference commit:**

```bash
bash tests/test_render_equiv.sh 30
bash tests/test_render_equiv.sh 30 2433b0c
```

This renders random PPU states with the current `ppu.sh` and with the one from the reference commit. The default reference is `df8f3bf`, the last commit before the string renderer. The random states include window and sprite lines, and the output reports how many of each were covered. Both counts must be above zero. Use the newer reference when a later change must keep the output identical.

### Regression fingerprints

These values are known-good for the current code. If one changes after an edit, the edit changed behavior.

| Check | Command | Expected |
|---|---|---|
| Instruction count, 20 frames | `bash main.sh --headless --fps 0 --frames 20 "rom.gb"` | `steps=163821` |
| Instruction count, 60 frames | `bash main.sh --headless --fps 0 --frames 60 "rom.gb"` | `steps=465261` |
| Framebuffer, 60 frames | Fingerprint command below | `410f603a31fa55061cbdc000a36790a0` |
| Framebuffer, 600 frames | `tests/test_skip_equivalence.sh "rom.gb" 600` | `fb cd3704f17420298f0578907aea3e3ca4` |

Framebuffer hash command:

```bash
bash -c 'source ashboy/gameboy.sh; gameboy_init; gameboy_load_rom "rom.gb"; for ((f=0;f<60;f++)); do gameboy_step_frame; done; ppu_fb_flat; printf "%s" "$PPU_FLAT" | md5sum'
```

The hash is taken over `PPU_FLAT`, the flat text from `ppu_fb_flat`. It is not taken over `PPU_FRAMEBUFFER` directly, because that array now holds row strings.

### Diagnostics

Local probe scripts (`probe*.sh`) are useful for timing and for counting instructions per address. They are not part of the repository.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `NAME: command not found` | Function renamed or removed, or module not sourced | Run `tests/test_check.sh`. Check the name with `grep -n "NAME()" ashboy/*.sh`. |
| `NAME: unbound variable` | Global used before it is declared, under `set -u` | Declare it with a default: `declare -gi NAME=0`. |
| `syntax error in expression` with long text in the error token | Text was assigned to `REPLY`, which `init.sh` declares with `-i` | Store text in a named global such as `PPU_FLAT`. See [Coding rules](#coding-rules). |
| `value too great for base (error token is "066803")` | Locale uses a comma decimal separator, so `$EPOCHREALTIME` contains a comma | `now_us` must use `${EPOCHREALTIME//[^0-9]/}`. |
| `sleep: invalid time interval` | Same comma issue, in `sleep` | Call `LC_NUMERIC=C sleep "$wait_s"`. |
| `ppu_present_terminal: command not found` | Old function name | The name is `ppu_present_ansi`. Call it as `ppu_present_ansi "$SCALE"`. |
| Headless run stops at 10 FPS | Default `--fps 10` cap applies to headless runs | Add `--fps 0` for benchmarks. |
| `test_render_equiv.sh` reports `not a git repository` | Project folder is not a clone | Run from a clone of the repository, or pass a reference that exists in your history. |
| `test_render_equiv.sh` reports `not defined after loading gameboy.sh` | A module is missing or a source line was changed | Run `grep -n 'source' ashboy/gameboy.sh` and check each path. |
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
5. **Numbers go in `REPLY`, text goes in a named global.** Do not return values with `echo` or `$(...)`.
6. **Never assign text to `REPLY`.** `init.sh` declares `REPLY` with `-i`, so text is evaluated as arithmetic and fails. Use a named global such as `PPU_FLAT`.
7. **No forks in hot loops.** Avoid `$(...)`, pipes, `date`, `expr`, `seq`, `wc`, `grep`, and `awk` inside the emulation loop. Use builtins only.
8. **Keep `local` out of per-pixel and per-instruction loops.** Declare variables once at the top of the function.
9. **Read keys with `IFS= read -s -r -n 1 -t 0.001 key`.** Without `IFS=`, a typed space is stripped and becomes an empty string, which is the Enter key.
10. **Always restore the terminal.** The `trap` must run `stty echo icanon` and `printf '\e[?25h\e[0m'`.
11. **Check the output after every change.** Run the unit tests, then the step count and framebuffer hash, then the equivalence tests for any change to speed code.
12. **Speed changes keep the output identical.** Any change that alters the state or framebuffer is a behavior change. Put it in its own commit with a new reference.

**Names that must not come back.** They were removed after causing "command not found" errors: `cpu_exec_cb` (now `op_cb`), `cpu_execute_op`, `timer_step` (now `timer_tick`), `mmu_write` (now `mmu_write8`), `ppu_present_terminal` (now `ppu_present_ansi`). Also do not reintroduce `--sleep` pacing or `clear` per frame.

## Known limitations

- **No sound.** The audio hardware is not emulated at all.
- **Original Game Boy (DMG) only.** Game Boy Color games will not run; the console mode and its extra hardware are not supported.
- **Limited mappers.** Only ROM-only, MBC1, and MBC3 cartridges are covered. ROMs using other mappers are untested and will likely fail to load or misbehave.
- **Speed.** About 5 FPS with the display on at default settings, and about 25 FPS headless in steady state, against the real console's 59.7 FPS. Pure Bash is unlikely to reach real time.
- **Loop skip coverage.** The skip recognizes two loop shapes. Other loops run at full cost. Code in the switchable ROM bank (`0x4000–0x7FFF`) is never skipped.
- **Sprite priority.** Sprites are drawn in OAM order. The hardware gives priority to the sprite with the lower X coordinate, and ties go to the earlier OAM entry. The fix changes output, so it needs its own commit and a new reference.
- **`REPLY` attribute.** `init.sh` declares `REPLY` with `-i`. Removing the attribute changes global state, so it needs its own commit with the same verification.
- **STAT interrupt.** The vector exists, but the conditions that raise it are not fully verified.
- **Benchmarks exclude terminal paint time.** They write to `/dev/null`.
- **Tested with few ROMs.** Behavior beyond the tested ROMs is unknown; other titles may expose bugs the emulator does not handle yet.

## Next steps

1. **Measure the string renderer.** Commit `2433b0c` is not yet timed. Run the two-length drawn benchmark and the renderer-only timing, then update the Performance tables.
2. **Cache terminal rows at scale 2.** Building the scale-2 output string takes about 114 ms per frame. Reuse rows that did not change since the last frame.
3. **Speed up the hot path of `cpu_step`.** An idle frame runs about 278 real instructions. Reducing the cost of the opcodes that idle frames use is the next lever for emulated speed.
4. **Skip whole scanlines while a poll loop holds.** Exactness must be checked with `tests/test_skip_equivalence.sh` at 60 and 600 frames, skip on and off.
5. **Fix sprite priority.** Implement the hardware rule as its own commit, with a new reference for `tests/test_render_equiv.sh`.
6. **Check WRAM and HRAM first in the memory bus.** Move these high-frequency checks to the top of `mmu_read8` and `mmu_write8`. Confirm `steps=163821` and the framebuffer hashes stay unchanged, then measure the gain.
7. **Remove the integer attribute from `REPLY`.** Its own commit, with the same verification.
8. **Remove the `--sleep` stub** once nothing depends on it.
9. **Decide the speed ceiling.** Staying in pure Bash is the current choice. A compiled hot loop would break the pure-Bash requirement, so that decision belongs to the project owner.
10. **Sound.** Not planned. It depends on real-time timing, which depends on item 9.

## Credits

The hardware behavior follows the Game Boy (DMG) technical reference. Community documentation, especially the Pan Docs and the hardware test suites published by emulator developers, has made this project possible.

**Disclaimer:** This is a fan-made, educational project and is not affiliated with, endorsed by, or sponsored by Nintendo. "Nintendo" and "Game Boy" are trademarks of Nintendo Co., Ltd. No original Nintendo ROMs, BIOS images, or other copyrighted material are included in this repository. Users must supply their own game files and are responsible for complying with copyright law in their jurisdiction. Nintendo remains protective of its intellectual property - please support official releases.