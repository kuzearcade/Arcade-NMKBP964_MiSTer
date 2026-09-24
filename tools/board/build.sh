#!/bin/bash
# Build and refuse to report success unless Quartus says so, with the stale
# .rbf removed first (the siblings' build script).
#   tools/board/build.sh LOGFILE
cd "$(dirname "$0")/../.." || exit 1
LOG="$1"
rm -f output_files_macplus/NMKBP964.rbf
~/intelFPGA_lite_clean/17.0/quartus/bin/quartus_sh --flow compile NMKBP964 > "$LOG" 2>&1
rc=$?
if grep -q "Full Compilation was successful" "$LOG" && [ -f output_files_macplus/NMKBP964.rbf ]; then
  echo "BUILD OK (rc=$rc)"
  grep -E "Logic utilization \(in ALMs\)|Total RAM Blocks|Total registers|Total DSP" output_files_macplus/NMKBP964.fit.rpt | head -n 4
  grep -c "Timing requirements not met" output_files_macplus/NMKBP964.sta.rpt | sed 's/^/timing-not-met lines: /'
  md5sum output_files_macplus/NMKBP964.rbf
else
  echo "BUILD FAILED (rc=$rc)"
  grep -E "^Error|Error \(" "$LOG" | head -25
fi
