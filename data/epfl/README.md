# EPFL benchmark scales

Path references to `third_party/benchmarks/EPFL/{arithmetic,random_control}`.  
No benchmark files are copied into `data/`.

## Files

| File | Description |
|------|-------------|
| `manifest.yaml` | Full catalog (20 benchmarks) with stats and scale labels |
| `tiny.yaml` | Fastest smoke tests (AND &lt; 1,000) |
| `small.yaml` | Quick smoke / CI set (1,000 ≤ AND &lt; 5,000) |
| `medium.yaml` | Regular experiments (5,000 ≤ AND &lt; 30,000) |
| `large.yaml` | Stress / QoR evaluation (AND ≥ 30,000) |

## Scale thresholds

Classification uses **AND gate count** after `strash` (from `graduate-abc ps`).

| Scale | AND gates | Count |
|-------|-----------|-------|
| tiny | &lt; 1,000 | 6 |
| small | 1,000 – 4,999 | 4 |
| medium | 5,000 – 29,999 | 6 |
| large | ≥ 30,000 | 4 |

### tiny (6)

| Suite | Benchmarks |
|-------|------------|
| random_control | ctrl, int2float, dec, router, cavlc, priority |

### small (4)

| Suite | Benchmarks |
|-------|------------|
| arithmetic | adder, max, bar |
| random_control | i2c |

### medium (6)

| Suite | Benchmarks |
|-------|------------|
| arithmetic | sin, square, sqrt, multiplier |
| random_control | arbiter, voter |

### large (4)

| Suite | Benchmarks |
|-------|------------|
| arithmetic | log2, div, hyp |
| random_control | mem_ctrl |

## Usage

List case names from a scale file:

```bash
./scripts/list_epfl_benchmarks.sh tiny
# ctrl int2float dec router cavlc priority
```

Run ABC syn→map on a scale set:

```bash
CASES="$(./scripts/list_epfl_benchmarks.sh small)" \
  ./scripts/run_abc_syn_map.sh --flow resyn2
```

Resolve absolute path for one benchmark:

```bash
./scripts/list_epfl_benchmarks.sh --path small adder
# /home/.../third_party/benchmarks/EPFL/arithmetic/adder.aig
```

## YAML entry format

```yaml
benchmarks:
  - id: arithmetic/adder          # unique id: <suite>/<name>
    name: adder                   # basename without extension
    suite: arithmetic             # arithmetic | random_control
    path: third_party/benchmarks/EPFL/arithmetic/adder.aig
    and_gates: 1020               # optional quick reference
```

Paths are **relative to the repository root**.
