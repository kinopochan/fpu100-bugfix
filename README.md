# fpu100-bugfix

Unmerged patches for [opencores.org/projects/fpu100][upstream] — two bugs
from the upstream tracker that had never been addressed.

[upstream]: https://opencores.org/projects/fpu100

The first commit is `fpu100` trunk rev 21 imported verbatim, so `git log -p`
is an auditable diff between upstream and this fork.

## Fixed bugs

### Bugtracker [#4][bug4] / [#5][bug5] — denormal multiply

A multiplication whose result lands in the binary32 subnormal range comes
back with the wrong mantissa.  Reproducer from the report:

    0xc1800300  *  0x00034000
      upstream         -> 0x80068027   (wrong)
      soft-float ref.  -> 0x80340138
      after patch      -> 0x80340138

Fix: one-line shift-amount correction at `core/post_norm_mul.vhd:154`.

[bug4]: https://opencores.org/projects/fpu100/issues/4
[bug5]: https://opencores.org/projects/fpu100/issues/5

### Bugtracker [#2][bug2] — `ready_o` premature

`ready_o` rises two clocks before `output_o` is actually valid, so any
master sampling on the rising edge reads stale data.

Fix: `MUL_COUNT` raised from 11 to 13 at `core/fpu.vhd:107` so that
`ready_o` lines up with the first clock at which `output_o` is correct.

[bug2]: https://opencores.org/projects/fpu100/issues/2

## Verification

**Simulation** (requires [GHDL](https://ghdl.github.io/ghdl/), tested 4.1):

    cd sim
    ./run.sh            # patched   — all cases PASS
    ./run.sh unpatched  # reverts   — bug #4/#5 case FAILs

**Hardware** (Intel Cyclone V, SH-2 at 50 MHz, 2026-04-22): an 8-case
regression covering add / sub / mul / div / sqrt plus the bugtracker #4/#5
reproducer was driven through the Wishbone wrapper below.  All passed,
using both the bus-stall `RESULT` read path and the `FPU_OP & 0x100`
polling path.

## Bonus: `rtl/fpu_wb.v`

Not part of upstream.  A small Wishbone-slave wrapper around the raw `fpu`
entity, included as a convenience:

    +0x00  OPA     (R/W)
    +0x04  OPB     (R/W)
    +0x08  FPU_OP  (W: op + rmode, triggers start; R: status + flags)
    +0x0C  RESULT  (R stalls until ready, W = re-start)

## License

fpu100 is © 2006 Jidan Al-eryani `<jidan@gmx.net>`, distributed under:

> This source file may be used and distributed without restriction provided
> that this copyright statement is not removed from the file and that any
> derivative work contains the original copyright notice and the associated
> disclaimer. (…) You can use this code academically, commercially, etc.
> for free; just acknowledge the author.

Source-file copyright notices are preserved.  Patches and wrapper are
contributed under the same terms.
