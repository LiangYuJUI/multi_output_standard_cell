# multi_output_standard_cell

Research workspace for ASAP7 multi-output standard cells, GRADUATE technology mapping, and mockturtle integration.

## Setup

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/LiangYuJUI/multi_output_standard_cell.git
cd multi_output_standard_cell
```

If already cloned without submodules:

```bash
git submodule update --init --recursive
```

### Local symlinks (not submodules)

```bash
ln -s /path/to/OpenROAD-flow-scripts/flow/platforms/asap7/lib/NLDM third_party/asap7_lib
ln -s /path/to/benchmarks third_party/benchmarks
```

Extracted RVT FF NLDM libraries live in `third_party/asap7_RVT_FF_nldm/` (gitignored).

## Third-party dependencies

| Path | Source |
|------|--------|
| `third_party/GRADUATE` | [Pathfinder-86/GRADUATE](https://github.com/Pathfinder-86/GRADUATE) (submodule) |
| `third_party/mockturtle` | [lsils/mockturtle](https://github.com/lsils/mockturtle) (submodule) |
| `third_party/asap7_lib` | Local symlink to ORFS NLDM liberty directory |
| `third_party/asap7_RVT_FF_nldm` | Extracted `*RVT_FF*nldm*` `.lib` files |
| `third_party/benchmarks` | Local symlink to EPFL / hdl-benchmarks (`~/tools/benchmarks`) |

## Documentation

See [`docs/`](docs/) for detailed notes on ASAP7 multi-output cells, GRADUATE, and mockturtle.
