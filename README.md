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

### ASAP7 cell library (local symlink)

`third_party/asap7sc7p5t_28` is a symlink to a local ASAP7 library checkout (not a git submodule):

```bash
ln -s /path/to/asap7sc7p5t_28 third_party/asap7sc7p5t_28
```

## Third-party dependencies

| Path | Source |
|------|--------|
| `third_party/GRADUATE` | [Pathfinder-86/GRADUATE](https://github.com/Pathfinder-86/GRADUATE) (submodule) |
| `third_party/mockturtle` | [lsils/mockturtle](https://github.com/lsils/mockturtle) (submodule) |
| `third_party/asap7sc7p5t_28` | Local symlink to ASAP7 7.5nm cell library |

## Documentation

See [`docs/`](docs/) for detailed notes on ASAP7 multi-output cells, GRADUATE, and mockturtle.
