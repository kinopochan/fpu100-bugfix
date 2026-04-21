#!/usr/bin/env bash
# Run the fpu100-bugfix simulation regression with GHDL.
#
#   ./run.sh            # patched core (expected: ALL PASS)
#   ./run.sh unpatched  # revert patches in-memory first
#                       # (shows the upstream bugs reproduce)
set -euo pipefail

cd "$(dirname "$0")"
SIM=$PWD
CORE=$SIM/../core

# Default: use the patched core as-is.
SRC=$CORE

if [[ "${1:-}" == "unpatched" ]]; then
  echo "# Reverting patches in-memory to reproduce upstream bugs..."
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  cp "$CORE"/*.vhd "$tmp/"
  sed -i 's|v_shl1 := s_exp_10a - "0000000001";|v_shl1 := ("0000"\&s_zeros) - s_exp_10a;|' "$tmp/post_norm_mul.vhd"
  sed -i 's|constant MUL_COUNT: integer:= 13;|constant MUL_COUNT: integer:= 11;|' "$tmp/fpu.vhd"
  SRC=$tmp
fi

GHDL_FLAGS=(--std=08 --ieee=synopsys -fexplicit)
ORDER=(
  fpupack.vhd comppack.vhd addsub_28.vhd mul_24.vhd
  serial_mul.vhd serial_div.vhd sqrt.vhd
  pre_norm_addsub.vhd pre_norm_mul.vhd pre_norm_div.vhd pre_norm_sqrt.vhd
  post_norm_addsub.vhd post_norm_mul.vhd post_norm_div.vhd post_norm_sqrt.vhd
  fpu.vhd
)

WORK=$SIM/work
mkdir -p "$WORK"
rm -f "$WORK"/work-obj*.cf
cd "$WORK"

for f in "${ORDER[@]}"; do
  ghdl -a "${GHDL_FLAGS[@]}" "$SRC/$f"
done
ghdl -a "${GHDL_FLAGS[@]}" "$SIM/tb_bugtracker.vhd"
ghdl -e "${GHDL_FLAGS[@]}" tb_bugtracker
ghdl -r "${GHDL_FLAGS[@]}" tb_bugtracker --stop-time=20us \
  2>&1 | grep -vE 'synopsys/std_logic_arith' \
       | grep -E 'PASS|FAIL|ALL|HAS|sim done' \
  || true
