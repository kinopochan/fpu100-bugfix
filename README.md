# fpu100-bugfix

A community-maintained patch set for [opencores.org/projects/fpu100][upstream]
(single-precision IEEE 754 FPU by Jidan Al-eryani), fixing two long-standing
bugs that have been filed against the upstream tracker for more than a decade
and never merged.

[upstream]: https://opencores.org/projects/fpu100

> ✅ **HW verified on 2026-04-22** — patched core synthesized for an Intel
> Cyclone V FPGA (Altera 5CEFA2, 50 MHz clock), driven by an SH-2 CPU through
> the included Wishbone wrapper.  All 8 regression vectors pass, including
> the bugtracker #4/#5 reproducer.  See *HW verification* below.

## What this repo is

- `core/` — the 16 VHDL source files of `fpu100` trunk rev 21 (the final
  "New directory structure" snapshot before upstream went quiet), with the
  two patches described below applied.
- `rtl/` — `fpu_wb.v`, a small Wishbone-slave wrapper around the raw `fpu`
  entity.  Exposes a 4-register memory-mapped interface (operands, control,
  result) and takes care of handshaking.
- `sim/` — a minimal GHDL testbench (`tb_bugtracker.vhd`) and a driver script
  (`run.sh`) that exercise the patched core against the public bug-report
  reproducer plus a handful of additional multiply cases.

The first commit is the verbatim import of rev 21 so that `git log -p` shows
the complete, auditable diff between upstream and this fork.

## Fixes

### Bugtracker [#4][bug4] / [#5][bug5] — denormal multiply mantissa

Reported 11+ years ago. A multiplication whose result lands in the binary32
subnormal range produces the wrong mantissa. The canonical reproducer from
the bug report:

|                        | value                |
|------------------------|----------------------|
| opa                    | `0xc1800300`         |
| opb (subnormal)        | `0x00034000`         |
| soft-float expected    | `0x80340138`         |
| **upstream fpu100**    | `0x80068027`  *(wrong)* |
| **fpu100-bugfix**      | `0x80340138`  *(matches soft float)* |

Root cause: in `core/post_norm_mul.vhd`, the inner denormal branch of the
post-normalization process (when the raw product exponent is still non-zero,
but the leading-zero correction pushes it into the subnormal range) computes
the left-shift amount for the fraction as `s_zeros - s_exp_10a`. The correct
expression is `s_exp_10a - 1`, which is the shift needed to realign the
mantissa after the output exponent is force-clamped to `1` (the subnormal
boundary). The one-character fix is at `core/post_norm_mul.vhd:154`.

[bug4]: https://opencores.org/projects/fpu100/issues/4
[bug5]: https://opencores.org/projects/fpu100/issues/5

### Bugtracker [#2][bug2] — `ready_o` asserts before `output_o` is valid

Reported 14+ years ago. `ready_o` goes high two clock cycles before the
multiplier result actually appears on `output_o`. A Wishbone (or any other)
master that samples `output_o` on the rising edge of `ready_o` reads stale
data. This is the handshake bug that the bug report refers to as the
"Output Register for MULT Unit" issue.

Root cause: `fpu.vhd` defines `MUL_COUNT = 11` — the FSM cycle threshold at
which `ready_o` is asserted for the multiply path. The actual pipeline depth
(`pre_norm_mul` → `mul_24` → `post_norm_mul` → output multiplexer → output
register) is two cycles deeper. Setting `MUL_COUNT = 13` aligns `ready_o`
with the first clock edge at which `output_o` is valid. `core/fpu.vhd:107`.

[bug2]: https://opencores.org/projects/fpu100/issues/2

## Bonus: `rtl/fpu_wb.v` — Wishbone wrapper

Not part of upstream fpu100.  This is a small Wishbone-slave wrapper we
wrote for our own SoC that bus-connects the raw `fpu` entity to an SH-2
(or any other wishbone master).  It's included here purely as a
convenience — you can drop it next to the core and get a 4-register
MMIO interface (OPA / OPB / CTL / RESULT) without writing your own bus
glue.

Register map:

```
+0x00  OPA     (R/W)  Operand A  (IEEE 754 single)
+0x04  OPB     (R/W)  Operand B  (IEEE 754 single)
+0x08  FPU_OP  (R/W)  Write = op + rmode, triggers start
                      Read  = op, rmode, ready, IEEE flags
+0x0C  RESULT  (R stalls until ready, W = re-start)
```

If you're writing your own wrapper instead, three subtleties that we had
to work through are probably worth being aware of:

1. `req = sel & stb & cyc & ~ack;` — without the `~ack` guard, an OP write
   that's immediately followed by a RESULT read (back-to-back MA inside
   one 32-bit fetch word) spills the write's ack into the read phase and
   the master reads `0` without stalling.
2. `ready_o` is a one-cycle pulse and `output_o` / status are
   combinational off pipeline state, so the wrapper latches result + flags
   on the pulse and hands out the latch (not the live wire) on bus reads.
3. The status read-back concatenation has to add up to 32 bits exactly, or
   Verilog's implicit zero-extend silently shifts the fields (we had
   `wb_ready` end up at bit 10 instead of bit 8, which made polling
   `FPU_OP & 0x100` hang forever — this is what our first HW-test actually
   caught, before we were exercising the fpu100 patches themselves).

[fpu-sp]: https://github.com/taneroksuz/fpu-sp

## Running the simulation regression

Requires [GHDL](https://ghdl.github.io/ghdl/) (tested with 4.1.0).

```
cd sim
./run.sh            # patched core — ALL PASS
./run.sh unpatched  # reverts both patches in-memory
                    # bugtracker #4/#5 case FAILs, other multiplies pass
```

Expected patched output:

```
PASS #4/#5 denormal mul: 0xc1800300 * 0x00034000 = 0x80340138
PASS 2.0 * 3.0        : 0x40000000 * 0x40400000 = 0x40c00000
PASS -1.5 * 2.0       : 0xbfc00000 * 0x40000000 = 0xc0400000
PASS 0 * 3.0          : 0x00000000 * 0x40400000 = 0x00000000
PASS 1.0 * pi         : 0x3f800000 * 0x40490fdb = 0x40490fdb
PASS 1e-20 * 1e-20    : 0x1e3ce508 * 0x1e3ce508 = 0x000116c2 (denormal)
ALL PASS (0 failures)
```

The testbench exercises only `fpu_op_i = "010"` (multiply).  Add/sub/div/sqrt
paths are untouched by the fpu100 core patches, but are also independently
verified by the on-hardware regression described next.

## HW verification

**Target**: Intel Cyclone V 5CEFA2F23 (Altera) on a custom board.  
**CPU**: SH-2 (fvdhoef/aquarius-plus-style SoC) at 50 MHz.  
**Driver**: An 8-case regression cart that drives the FPU through the
Wishbone wrapper, writes each test's result to an on-screen text plane, and
lights an LED on full pass.

All 8 tests passed:

| # | label                     | expected     | observed     | result |
|---|---------------------------|--------------|--------------|--------|
| 1 | bugtracker #4/#5 denormal | `0x80340138` | `0x80340138` | OK     |
| 2 | `1.0 + 2.0 = 3.0`         | `0x40400000` | `0x40400000` | OK     |
| 3 | `3.0 - 1.0 = 2.0`         | `0x40000000` | `0x40000000` | OK     |
| 4 | `2.0 * 3.0 = 6.0`         | `0x40C00000` | `0x40C00000` | OK     |
| 5 | `6.0 / 2.0 = 3.0`         | `0x40400000` | `0x40400000` | OK     |
| 6 | `sqrt(4.0) = 2.0`         | `0x40000000` | `0x40000000` | OK     |
| 7 | `0.1 + 0.2 = 0.3`         | `0x3E99999A` | `0x3E99999A` | OK     |
| 8 | `0.0 * 0.0 = 0`           | `0x00000000` | `0x00000000` | OK     |

The LED (GPIO[31]) came on, indicating every test passed.

The driving cart source is not part of this repo (it's SoC-specific), but
the regression pattern is straightforward: write OPA, OPB, CTL=MUL (or
other op); read RESULT; compare to `expected`.  The wrapper will bus-stall
the read until the FPU signals `ready_o`.

## Scope, caveats

- Only the parallel multiplier path (`MUL_SERIAL = 0`) is exercised.  If you
  use the serial multiplier, `MUL_COUNT` for that path (upstream value: 34)
  may also be off — re-check against your pipeline depth.
- The upstream testbench (`test_bench/tb_fpu.vhd`) relies on an external
  `testcases.txt` file that is not distributed with the opencores release,
  so it is not wired into the sim runner here.  Porting a broader test
  vector set is future work.
- Latency characteristics of fpu100 (13-cycle multiply after the timing fix,
  no pipeline) may be limiting for heavy FP workloads; for production use
  consider a pipelined FPU such as [fpu-sp][fpu-sp].  fpu100-bugfix is most
  useful as a minimal, well-documented, LGPL-friendly drop-in when GPL
  code-bases are a concern.

## Credit and license

The fpu100 core is © 2006 Jidan Al-eryani `<jidan@gmx.net>`, originally
published on opencores.org under:

> This source file may be used and distributed without restriction provided
> that this copyright statement is not removed from the file and that any
> derivative work contains the original copyright notice and the associated
> disclaimer. (…) You can use this code academically, commercially, etc. for
> free; just acknowledge the author.

This fork preserves those notices in every source file.  The patches in
`core/post_norm_mul.vhd`, `core/fpu.vhd` and the wrapper fixes in
`rtl/fpu_wb.v` are contributed under the same terms; please continue to
credit the original author when reusing this code.
