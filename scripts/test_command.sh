# See docs/SCRIPTS.md
# Reference ABC script from earlier experiments (GradMap-oriented).
#
# Verification summary (2026-07-09):
#   - Synthesis -> mapping concept is correct: read AIG, &get, synthesize, &nf, &put, write Verilog.
#   - For pure ABC mapped netlist output, prefer &nf (not &nf -Y).
#     &nf -Y dumps match candidates for GradMap; it still maps internally but -Y is not the
#     right command if the goal is only gate-level Verilog.
#   - Add strash after read.
#   - rec_start3 is optional; default gradmap_libs does not ship rec6Lib_final_filtered3_recanon.aig.
#   - read -m <verilog> before topo/stime gives mapped timing on the gate netlist.
#
# Corrected runnable flows:
#   scripts/abc_syn_map_resyn2.abc   resyn2 + &nf
#   scripts/abc_syn_map_deepsyn.abc  &deepsyn + &nf
#   scripts/run_abc_syn_map.sh       batch runner for EPFL benchmarks
#
# --- original template below ---

source abc.rc
read_lib <GRADMAP_LIBS>/asap7.lib
rec_start3 <GRADMAP_LIBS>/rec6Lib_final_filtered3_recanon.aig
read <TESTCASE_ROOT>/<category>/<testcase>.aig
strash
&get
# (optional, depending on mode)
&if -y -K 6; &put; resyn2; resyn2; &get;
&deepsyn -T 120
# mapping: use &nf for Verilog; use &nf -Y only when dumping GradMap matches
&nf
&put
write_verilog <PROJECT_ROOT>/verilog_output/abc_output/<testcase>_<mode>.v
read -m <PROJECT_ROOT>/verilog_output/abc_output/<testcase>_<mode>.v
topo
stime
