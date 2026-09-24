#!/bin/bash
# Generate rtl/third_party_gen/tg68k/TG68KdotC_Kernel.v, a Verilog netlist of the
# vendored TG68K.C VHDL, for Verilator ONLY. Quartus builds the VHDL itself.
#
# Ubuntu's GHDL 5.0.1 has --synth and --out=verilog built in, so unlike NMK16's
# T80 route (docs/t80-vhdl-toolchain.md there) no ghdl-yosys-plugin is needed.
#
# --latches: TG68K has fully covered CASE statements ending in
# "WHEN OTHERS => NULL;" (the condition decode, and 2-bit size decodes in the
# ALU). Only metavalues reach those arms, but GHDL cannot prove it and infers a
# latch on the net. GHDL writes such a latch as a case whose default arm holds
# the signal's own value; in Verilator's two-state model the decode is always
# one-hot, so the arm is never taken. The script lists every default arm that
# reads a named signal into holds.txt beside the netlist, so a new one after a
# pin bump shows in the diff. (Clocked holds -- vbr, cacr, sfc, dfc, make_berr
# -- are register enables, not latches, and appear there too.)

# MUL_Hardware=0 matches the Quartus build (the iterative multiplier, as
# ITech32's wrapper selects). Re-run only when the vendored VHDL changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/rtl/third_party/tg68k"
GEN="$ROOT/rtl/third_party_gen/tg68k"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp "$SRC"/TG68K_Pack.vhd "$SRC"/TG68K_ALU.vhd "$SRC"/TG68KdotC_Kernel.vhd "$TMP"/
cd "$TMP"
ghdl -a --std=08 -fsynopsys TG68K_Pack.vhd TG68K_ALU.vhd TG68KdotC_Kernel.vhd
ghdl --synth --std=08 -fsynopsys -gMUL_Hardware=0 --latches --out=verilog TG68KdotC_Kernel > "$GEN/TG68KdotC_Kernel.v" 2> "$TMP/synth.log"
grep -o "default: n[0-9]*_o = [A-Za-z_][A-Za-z_0-9]*;" "$GEN/TG68KdotC_Kernel.v" | grep -v "= n[0-9]*_o;" | sed 's/.* = //; s/;//' | sort | uniq -c > "$GEN/holds.txt" || true
echo "hold arms on named signals: $(wc -l < "$GEN/holds.txt") (see $GEN/holds.txt)"
echo "wrote $GEN/TG68KdotC_Kernel.v ($(wc -l < "$GEN/TG68KdotC_Kernel.v") lines)"
