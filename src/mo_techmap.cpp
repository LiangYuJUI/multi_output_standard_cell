#include <chrono>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <string>

#include <lorina/aiger.hpp>
#include <lorina/genlib.hpp>
#include <mockturtle/algorithms/aig_balancing.hpp>
#include <mockturtle/algorithms/emap.hpp>
#include <mockturtle/io/aiger_reader.hpp>
#include <mockturtle/io/genlib_reader.hpp>
#include <mockturtle/io/write_verilog.hpp>
#include <mockturtle/networks/aig.hpp>
#include <mockturtle/networks/block.hpp>
#include <mockturtle/utils/stopwatch.hpp>
#include <mockturtle/utils/tech_library.hpp>
#include <mockturtle/views/cell_view.hpp>
#include <mockturtle/views/depth_view.hpp>

namespace {

struct Options {
  std::string input_aig;
  std::string genlib;
  std::string output_verilog;
  std::string stats_path;
  bool map_multioutput = true;
  bool area_oriented = true;
  bool help = false;
};

void usage(const char* prog) {
  std::cerr
      << "Usage: " << prog
      << " --aig <file.aig> --genlib <file.genlib> --out <mapped.v> [options]\n\n"
      << "Options:\n"
      << "  --stats <file>        write mapping stats summary\n"
      << "  --no-multioutput      disable multi-output cell mapping\n"
      << "  --delay-oriented      use delay-oriented emap (default: area-oriented)\n"
      << "  -h, --help            show this help\n";
}

bool parse_args(int argc, char** argv, Options* opts) {
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    auto need_value = [&](const std::string& name) -> std::string {
      if (i + 1 >= argc) {
        std::cerr << "missing value after " << name << "\n";
        std::exit(1);
      }
      return argv[++i];
    };
    if (arg == "-h" || arg == "--help") {
      opts->help = true;
      return true;
    } else if (arg == "--aig") {
      opts->input_aig = need_value(arg);
    } else if (arg == "--genlib") {
      opts->genlib = need_value(arg);
    } else if (arg == "--out") {
      opts->output_verilog = need_value(arg);
    } else if (arg == "--stats") {
      opts->stats_path = need_value(arg);
    } else if (arg == "--no-multioutput") {
      opts->map_multioutput = false;
    } else if (arg == "--delay-oriented") {
      opts->area_oriented = false;
    } else {
      std::cerr << "unknown option: " << arg << "\n";
      return false;
    }
  }
  return !opts->input_aig.empty() && !opts->genlib.empty() &&
         !opts->output_verilog.empty();
}

void write_stats(const Options& opts,
                 uint32_t size_before,
                 uint32_t depth_before,
                 double area_after,
                 double delay_after,
                 uint32_t multioutput_gates,
                 double runtime_sec) {
  if (opts.stats_path.empty()) {
    return;
  }
  std::ofstream out(opts.stats_path);
  if (!out) {
    std::cerr << "warning: cannot write stats file: " << opts.stats_path << "\n";
    return;
  }
  out << "input_aig=" << opts.input_aig << "\n";
  out << "genlib=" << opts.genlib << "\n";
  out << "output_verilog=" << opts.output_verilog << "\n";
  out << "gates_before=" << size_before << "\n";
  out << "depth_before=" << depth_before << "\n";
  out << "area_after=" << area_after << "\n";
  out << "delay_after=" << delay_after << "\n";
  out << "multioutput_gates=" << multioutput_gates << "\n";
  out << "map_multioutput=" << (opts.map_multioutput ? 1 : 0) << "\n";
  out << "area_oriented=" << (opts.area_oriented ? 1 : 0) << "\n";
  out << "runtime_sec=" << runtime_sec << "\n";
}

}  // namespace

int main(int argc, char** argv) {
  Options opts;
  if (argc == 1) {
    usage(argv[0]);
    return 1;
  }
  if (!parse_args(argc, argv, &opts)) {
    usage(argv[0]);
    return 1;
  }
  if (opts.help) {
    usage(argv[0]);
    return 0;
  }

  using namespace mockturtle;

  std::vector<gate> gates;
  std::ifstream genlib_in(opts.genlib);
  if (!genlib_in) {
    std::cerr << "cannot open genlib: " << opts.genlib << "\n";
    return 1;
  }
  if (lorina::read_genlib(genlib_in, genlib_reader(gates)) !=
      lorina::return_code::success) {
    std::cerr << "failed to parse genlib: " << opts.genlib << "\n";
    return 1;
  }

  tech_library_params tps;
  tps.ignore_symmetries = false;
  tps.verbose = false;
  tech_library<9> tech_lib(gates, tps);

  aig_network aig;
  if (lorina::read_aiger(opts.input_aig, aiger_reader(aig)) !=
      lorina::return_code::success) {
    std::cerr << "failed to read aiger: " << opts.input_aig << "\n";
    return 1;
  }

  aig_balancing_params bps;
  bps.minimize_levels = false;
  bps.fast_mode = true;
  aig_balance(aig, bps);

  const uint32_t size_before = aig.num_gates();
  const uint32_t depth_before = depth_view(aig).depth();

  emap_params ps;
  ps.matching_mode = emap_params::hybrid;
  ps.area_oriented_mapping = opts.area_oriented;
  ps.map_multioutput = opts.map_multioutput;
  ps.relax_required = 0;

  emap_stats st;
  const auto started = std::chrono::steady_clock::now();
  cell_view<block_network> mapped = emap<9>(aig, tech_lib, ps, &st);
  const auto finished = std::chrono::steady_clock::now();
  const double runtime_sec = to_seconds(finished - started);

  write_verilog_params vps;
  vps.module_name = "top";
  write_verilog_with_cell(mapped, opts.output_verilog, vps);

  const double area_after = mapped.compute_area();
  const double delay_after = mapped.compute_worst_delay();
  write_stats(opts, size_before, depth_before, area_after, delay_after,
              st.multioutput_gates, runtime_sec);

  std::cout << "mo_techmap completed\n"
            << "  input:             " << opts.input_aig << "\n"
            << "  genlib:            " << opts.genlib << "\n"
            << "  output:            " << opts.output_verilog << "\n"
            << "  gates_before:      " << size_before << "\n"
            << "  depth_before:      " << depth_before << "\n"
            << "  area_after:        " << area_after << "\n"
            << "  delay_after:       " << delay_after << "\n"
            << "  multioutput_gates: " << st.multioutput_gates << "\n"
            << "  runtime_sec:       " << runtime_sec << "\n";
  return 0;
}
