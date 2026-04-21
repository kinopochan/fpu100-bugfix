# fpu100-bugfix

A community-maintained patch set for [opencores.org/projects/fpu100][upstream]
(single-precision IEEE 754 FPU by Jidan Al-eryani), fixing two long-standing
bugs that have been filed against the upstream tracker for more than a decade
and never merged.

[upstream]: https://opencores.org/projects/fpu100

## What this repo is

- `core/` — the 16 VHDL source files of `fpu100` trunk rev 21 (the final
  "New directory structure" snapshot before upstream went quiet), with the two
  patches described below applied.
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

## Running the regression

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

Only `fpu_op_i = "010"` (multiply) is exercised. Add/sub/div/sqrt paths are
untouched by the patches, but are also not independently verified here.

## Scope, caveats

- **Simulation-verified only.** These patches have not been put through
  a synthesized hardware run in this repo. They should be harmless on real
  silicon — the math fix is a literal one-line expression swap, and the
  timing fix only delays `ready_o` by two cycles (a master that was already
  correctly waiting for `ready_o` will just see the same value two cycles
  later). But you are responsible for verifying on your own target.
- The upstream testbench (`test_bench/tb_fpu.vhd`) relies on an external
  `testcases.txt` file that is not distributed with the opencores release.
  Porting it to run here is future work.
- Only the parallel multiplier path (`MUL_SERIAL = 0`) is tested. If you use
  the serial multiplier, `MUL_COUNT` for that path (upstream value: 34) may
  also be off — re-check against your pipeline depth.

## Credit and license

The fpu100 core is © 2006 Jidan Al-eryani `<jidan@gmx.net>`, originally
published on opencores.org under:

> This source file may be used and distributed without restriction provided
> that this copyright statement is not removed from the file and that any
> derivative work contains the original copyright notice and the associated
> disclaimer. (…) You can use this code academically, commercially, etc. for
> free; just acknowledge the author.

This fork preserves those notices in every source file. The patches in
`core/post_norm_mul.vhd` and `core/fpu.vhd` are contributed under the same
terms; please continue to credit the original author when reusing this code.
