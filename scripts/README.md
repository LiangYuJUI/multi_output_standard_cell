# scripts/

Project runners and templates, grouped by file type:

| Directory | Contents |
|-----------|----------|
| [`sh/`](sh/) | Bash runners and libs |
| [`py/`](py/) | Python validators and tools |
| [`abc/`](abc/) | ABC command templates (placeholders expanded by runners) |

Examples:

```bash
./scripts/sh/run_fair_nf_emap_compare.sh --cases adder
./scripts/sh/redump_emap_y_fair.sh --dump-level 3 --so-dedup nf-like --so-cut-topk 16
./scripts/sh/cec_fair_nf_emap.sh --cases ctrl
python3 scripts/py/validate_emap_nf_y_multi.py --formal output/fair_nf_emap_asap7genlib/emap
```

Full documentation: [`docs/SCRIPTS.md`](../docs/SCRIPTS.md).
