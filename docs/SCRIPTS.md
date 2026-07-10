# Scripts 使用說明

本文件描述 `scripts/` 目錄下各腳本與 ABC 模板的**功能、用法、輸出與彼此關係**。

> **維護規則**：新增、刪除或修改 `scripts/` 內任何檔案時，**必須同步更新本文件**（含快速對照表、範例命令、placeholder 說明、相依環境變數）。

---

## 快速對照

| 檔案 | 類型 | 功能摘要 | 主要呼叫者 |
|------|------|----------|-----------|
| [`run_abc_syn_map.sh`](../scripts/run_abc_syn_map.sh) | Bash | ABC 合成 + `&nf` / `&nf -Y` mapping，批次跑 EPFL | 使用者 / CI |
| [`run_abc_mockturtle_map.sh`](../scripts/run_abc_mockturtle_map.sh) | Bash | ABC balance 合成（僅 AIG）+ mockturtle `mo_techmap` | 使用者 |
| [`run_abc_emap_map.sh`](../scripts/run_abc_emap_map.sh) | Bash | ABC balance 合成 + ABC-native `emap -Y` match dump + Verilog | 使用者 |
| [`run_fair_nf_emap_compare.sh`](../scripts/run_fair_nf_emap_compare.sh) | Bash | **公平比較**：共用一份 `synth.aig` → map-only `&nf -Y` 與 `emap -Y` → Liberty STA | 使用者 |
| [`compare_graduate_abc_emap.sh`](../scripts/compare_graduate_abc_emap.sh) | Bash | 比對 standalone `third_party/abc` 與 `graduate-abc` 的 ABC-native `emap` 結果 | 開發者 / CI |
| [`compare_nf_emap_map.sh`](../scripts/compare_nf_emap_map.sh) | Bash | 比對 `&nf -Y` vs `emap -Y` mapping QoR，輸出 markdown | 使用者 |
| [`validate_emap_mog_root_overlap.py`](../scripts/validate_emap_mog_root_overlap.py) | Python | 驗證 emap `nf_y_multi` 的 FA/HA root-pair **不重疊**（無 `[a,b]`∩`[b,c]`） | 使用者 / CI |
| [`list_epfl_benchmarks.sh`](../scripts/list_epfl_benchmarks.sh) | Bash | 從 `data/epfl/*.yaml` 列出或解析 benchmark | 上述 runners |
| [`abc_syn_map_resyn2.abc`](../scripts/abc_syn_map_resyn2.abc) | ABC | resyn2 合成 + `&nf` → Verilog | `run_abc_syn_map.sh --flow resyn2` |
| [`abc_syn_map_deepsyn.abc`](../scripts/abc_syn_map_deepsyn.abc) | ABC | `&deepsyn` 合成 + `&nf` → Verilog | `run_abc_syn_map.sh --flow deepsyn` |
| [`abc_syn_map_balance.abc`](../scripts/abc_syn_map_balance.abc) | ABC | balance 合成 + `&nf -Y` match + Verilog | `run_abc_syn_map.sh --flow balance` |
| [`abc_syn_balance.abc`](../scripts/abc_syn_balance.abc) | ABC | balance 合成 only → `synth.aig`（無 mapping） | `run_abc_mockturtle_map.sh` / fair compare |
| [`abc_map_nf_y.abc`](../scripts/abc_map_nf_y.abc) | ABC | map-only：`read synth.aig` → `&nf -Y` → Verilog | `run_fair_nf_emap_compare.sh` |
| [`abc_map_emap_y.abc`](../scripts/abc_map_emap_y.abc) | ABC | map-only：`read synth.aig` → `emap -Y` → Verilog | `run_fair_nf_emap_compare.sh` |
| [`abc_emap_map.abc`](../scripts/abc_emap_map.abc) | ABC | balance 合成 + `emap -Y` → Verilog | `run_abc_emap_map.sh` |
| [`generate_libcell_info_v2_multi_output.py`](../scripts/generate_libcell_info_v2_multi_output.py) | Python | Liberty → `libcell_info_v2_multi_output`（含 FA/HA） | 使用者（離線產 libcell） |
| [`test_command.sh`](../scripts/test_command.sh) | 參考 | 早期 ABC 實驗腳本與驗證備註（非 runner） | 開發者參考 |

---

## 管線總覽

```mermaid
flowchart LR
  subgraph inputs
    AIG[EPFL .aig]
    LIB[asap7.lib]
    GENLIB[multioutput.genlib]
  end

  subgraph abc_gradmap["ABC → GradMap 管線"]
    R1[run_abc_syn_map.sh]
    T1[abc_syn_map_*.abc]
    V1[mapped Verilog]
    M1[match .txt 僅 balance]
    R1 --> T1 --> V1
    T1 --> M1
  end

  subgraph abc_mo["ABC → mockturtle 管線"]
    R2[run_abc_mockturtle_map.sh]
  end

  subgraph phase1["Phase 1: ABC synth"]
    T2[abc_syn_balance.abc]
    SA[synth.aig]
    T2 --> SA
  end

  subgraph phase2["Phase 2: emap"]
    MT[build/mo_techmap]
    V2[*_mo_mapped.v]
    MT --> V2
  end

  AIG --> R1
  AIG --> R2
  LIB --> R1
  LIB --> R2
  R2 --> T2
  SA --> MT
  GENLIB --> MT
```

---

## 共用前置條件

### 路徑與依賴

| 項目 | 預設路徑 | 說明 |
|------|----------|------|
| `graduate-abc` | `third_party/GRADUATE/build_abc_frontend/graduate-abc` | ABC 需從 GRADUATE 目錄執行（載入 `abc.rc`） |
| Liberty | `third_party/GRADUATE/third_party/gradmap_libs/asap7.lib` | `read_lib` / `&nf` 用 |
| EPFL benchmarks | `third_party/benchmarks/EPFL/` | 通常為 symlink |
| `mo_techmap` | `build/mo_techmap` | 專案根目錄 CMake 建置（見 [`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md)） |
| GENLIB | `third_party/mockturtle/experiments/cell_libraries/multioutput.genlib` | mockturtle emap 用 |

### EPFL scale 定義

由 `data/epfl/{tiny,small,medium,large}.yaml` 定義（`--scale all` = 四個 scale 聯集）：

| Scale | AND gates |
|-------|-----------|
| `tiny` | &lt; 1,000 |
| `small` | 1,000 – 4,999 |
| `medium` | 5,000 – 19,999 |
| `large` | ≥ 20,000 |

詳見 [`data/epfl/README.md`](../data/epfl/README.md)。

### 共用環境變數

| 變數 | 用途 |
|------|------|
| `GRADUATE_ABC` | 覆寫 `graduate-abc` 路徑 |
| `GRADUATE_LIBERTY` | 覆寫 Liberty 路徑 |
| `GRADUATE_REC_LIB` | `rec_start3` 用的 `.aig`（選用） |
| `GRADUATE_DIR` | GRADUATE 根目錄 |
| `BENCH_ROOT` | benchmark 根目錄 |
| `DEEPSYN_ARGS` | 覆寫 `&deepsyn` 參數 |
| `OUT_ROOT` | 覆寫輸出目錄 |
| `JOBS` | 平行 job 數 |
| `MO_TECHMAP` | 覆寫 `mo_techmap` 路徑 |
| `MO_GENLIB` | 覆寫 GENLIB 路徑 |

---

## Bash runners

### `run_abc_syn_map.sh`

**功能**：對 EPFL（或其他）`.aig` 批次執行 ABC **合成 + technology mapping**，輸出 mapped Verilog；`balance` flow 另產 GradMap 用的 `&nf -Y` match file。

**Flows**：

| `--flow` | ABC 模板 | 合成 | Mapping | 額外輸出 |
|----------|----------|------|---------|----------|
| `resyn2` | `abc_syn_map_resyn2.abc` | IWLS resyn2 | `&nf` | Verilog |
| `deepsyn` | `abc_syn_map_deepsyn.abc` | `&deepsyn` | `&nf` | Verilog |
| `balance` | `abc_syn_map_balance.abc` | `&if` + resyn2 + `&deepsyn` | `&nf -Y` | match `.txt` + Verilog |

**常用選項**：

```bash
./scripts/run_abc_syn_map.sh --flow balance --scale tiny --parallel
./scripts/run_abc_syn_map.sh --flow resyn2 --cases "adder bar ctrl"
./scripts/run_abc_syn_map.sh --flow deepsyn --out output/my_run --jobs 4
./scripts/run_abc_syn_map.sh --flow balance --rec-start3   # 需 GRADUATE_REC_LIB
./scripts/run_abc_syn_map.sh --flow deepsyn --if-preprocess
```

| 選項 | 說明 |
|------|------|
| `--flow resyn2\|deepsyn\|balance` | 選擇合成/mapping 後端 |
| `--scale tiny\|small\|medium\|large\|all` | 從 yaml 載入 case 清單 |
| `--cases "a b c"` | 手動指定 benchmark 名稱（不含 `.aig`） |
| `--suite NAME` | 限定 EPFL 子目錄（如 `arithmetic`） |
| `--out DIR` | 輸出根目錄（預設 `output/abc_syn_map_<timestamp>/`） |
| `--jobs N` / `--parallel` | 平行執行 |
| `--timeout SEC` | 每 case 逾時（預設 600） |
| `--rec-start3` | 合成前 `rec_start3` |
| `--if-preprocess` | deepsyn 前 `&if -y -K 6` + resyn2（僅 deepsyn flow） |

**輸出結構**（每 case）：

```text
output/abc_syn_map_<timestamp>/<case>/
  run.abc              # 渲染後的 ABC 腳本
  run.log
  <case>_<flow>.v      # mapped Verilog
  <case>.txt            # 僅 balance：&nf -Y match dump
  report.line           # 彙整進 report.md
```

**報告**：`output/.../report.md`

**相關文件**：[`GRADUATE.md`](GRADUATE.md)、[`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md)（`&nf -Y` 語意）

---

### `run_abc_mockturtle_map.sh`

**功能**：兩階段管線——(1) ABC balance **僅合成** → `synth.aig`；(2) 專案 `mo_techmap` 做 **mockturtle multi-output emap** → mapped Verilog。

等同 `run_abc_syn_map.sh --flow balance` **去掉** `&nf -Y` 與 `write_verilog` 段。

**常用選項**：

```bash
./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder --cec
./scripts/run_abc_mockturtle_map.sh --scale tiny --parallel
./scripts/run_abc_mockturtle_map.sh --map-only --cases adder   # 需已有 synth.aig
./scripts/run_abc_mockturtle_map.sh --skip-synth --cases adder
```

| 選項 | 說明 |
|------|------|
| `--build-mo-techmap` | 若缺少 binary，執行 `cmake -S . -B build` 並建置 `mo_techmap` |
| `--mo-techmap PATH` | 指定 `mo_techmap`（預設 `build/mo_techmap`） |
| `--genlib PATH` | GENLIB 路徑 |
| `--skip-synth` | 跳過 ABC（`synth.aig` 已存在時） |
| `--map-only` | 只做 Phase 2 mapping |
| `--delay-oriented` | emap 改為 delay-oriented（預設 area-oriented） |
| `--no-multioutput` | 關閉 multi-output cell mapping |
| `--cec` | mapping 後用 `graduate-abc cec` 驗證 |
| `--scale` / `--cases` / `--jobs` / `--parallel` / `--out` / `--rec-start3` | 同 `run_abc_syn_map.sh` |

**輸出結構**（每 case）：

```text
output/abc_mockturtle_map_<timestamp>/<case>/
  synth.abc
  synth.log
  synth.aig
  <case>_mo_mapped.v
  stats.txt              # area, delay, multioutput_gates, runtime
  map.log
  cec.log                # 僅 --cec
```

**相關文件**：[`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md)、[`MOCKTURTLE.md`](MOCKTURTLE.md)

---

### `list_epfl_benchmarks.sh`

**功能**：讀取 `data/epfl/*.yaml`，列出 benchmark 名稱、yaml 路徑或解析成絕對 `.aig` 路徑。

```bash
./scripts/list_epfl_benchmarks.sh small
./scripts/list_epfl_benchmarks.sh medium large
./scripts/list_epfl_benchmarks.sh --path tiny adder
./scripts/list_epfl_benchmarks.sh --yaml all
```

| 模式 | 行為 |
|------|------|
| （預設） | 印出所有 `name:` |
| `--path <scale> <name>` | 印出絕對路徑 |
| `--yaml <scale>` | 印出使用的 yaml 檔路徑 |

---

## ABC 腳本模板（`.abc`）

這些檔案**不要直接執行**；含 `__PLACEHOLDER__`，由 Bash runner 以 `sed` 替換後寫入各 case 的 `run.abc` / `synth.abc`，再從 **GRADUATE 根目錄**執行：

```bash
cd third_party/GRADUATE && ./build_abc_frontend/graduate-abc -f /path/to/rendered.abc
```

### Placeholder 對照

| Placeholder | 用於 | 替換內容 |
|-------------|------|----------|
| `__INPUT_AIG__` | 全部 | 輸入 `.aig` 絕對路徑 |
| `__LIBERTY__` | 全部 | `asap7.lib` 路徑 |
| `__OUTPUT_V__` | `*_map_*.abc` | mapped Verilog 路徑 |
| `__OUTPUT_AIG__` | `abc_syn_balance.abc` | 合成後 AIG 路徑 |
| `__MATCH_FILE__` | `abc_syn_map_balance.abc` | `&nf -Y` match dump 路徑 |
| `__DEEPSYN_ARGS__` | balance / deepsyn | 預設 balance/deepsyn 各不同 |
| `__REC_START3__` | balance / deepsyn | `rec_start3 <aig>` 或空 |
| `__PRE_DEEPSYN__` | deepsyn only | `&if -y -K 6; &put; resyn2; resyn2; &get` 或空 |

### `abc_syn_map_resyn2.abc`

resyn2（展開版 `balance; rewrite; refactor; ...`）→ `read_lib` → `&nf` → `write_verilog` → `stime`。

### `abc_syn_map_deepsyn.abc`

`&deepsyn` → `&nf` → Verilog。可選 `--if-preprocess`、`--rec-start3`。

### `abc_syn_map_balance.abc`

`&if -y -K 6` + resyn2 + `&deepsyn -T 120` → `&nf -Y`（match dump）→ `write_verilog`。GradMap / cover 實驗用。

### `abc_syn_balance.abc`

與 balance 合成段相同，但**不做** `&nf`；最後 `write_aiger __OUTPUT_AIG__`。供 mockturtle 管線 Phase 1。

---

## Python 工具

### `generate_libcell_info_v2_multi_output.py`

**功能**：從 Liberty 產生 **`libcell_info_v2_multi_output`** 格式，保留 multi-output cell（FA/HA 等）。延伸自 GRADUATE 的 `generate_libcell_info_v2.py`。

```bash
./scripts/generate_libcell_info_v2_multi_output.py \
  third_party/GRADUATE/third_party/gradmap_libs/asap7.lib \
  -o output/asap7_libcell_info_v2_multi_output.txt
```

| 選項 | 說明 |
|------|------|
| `libs`（位置參數） | 一個或多個 `.lib` |
| `-o` / `--output` | 輸出檔路徑（必填） |
| `--include-tie-cells` | 保留 TIEHI/TIELO |

**詳細格式說明**：[`GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md`](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md)

> 截至目前 GradMap **尚未**讀取此格式；主要供本專案後續 timing / binding model 使用。

---

## 參考檔案

### `test_command.sh`

早期 GradMap 導向的 ABC 實驗腳本與**驗證備註**（非可執行 runner）。記錄了：

- 合成 → mapping 概念正確性
- 純 Verilog 用 `&nf`；GradMap match dump 用 `&nf -Y`
- `strash`、`read -m` + `stime` 等慣例

正式可執行流程請改用 `abc_syn_map_*.abc` 與 `run_abc_syn_map.sh`。

---

## `compare_graduate_abc_emap.sh`

**功能**：在相同 AIG 與 GENLIB 上，分別對 standalone [`third_party/abc`](../third_party/abc) 與 [`graduate-abc`](../third_party/GRADUATE/build_abc_frontend/graduate-abc) 執行 ABC-native `emap`，比對：

- `emap -amv` 的 verbose 摘要行（`ABC-native emap mapped ...`）
- `print_stats` 輸出
- 正規化後的 BLIF（略過 `# Benchmark` 時間戳行）

用於驗證 GRADUATE bundled ABC 已正確整合 `src/map/emap/`。預設 flags 為 `-av`（area + verbose，**保留** MOG；勿用 `-m`，會關掉 multi-output）。

**範例**：

```bash
./scripts/compare_graduate_abc_emap.sh
./scripts/compare_graduate_abc_emap.sh --cases "adder c1355 multiplier"
./scripts/compare_graduate_abc_emap.sh --scale tiny --bench-root third_party/mockturtle/experiments/benchmarks
```

**環境變數**：`STANDALONE_ABC`、`GRADUATE_ABC`、`EMAP_GENLIB`、`EMAP_FLAGS`（預設 `-av`）。

**輸出**：`output/emap_equiv_<timestamp>/` 內含各 case 的 BLIF、log 與 `.norm.blif`。

---

## `run_fair_nf_emap_compare.sh`

**功能**：**公平**比對 `&nf -Y` vs `emap -Y`——每個 case **只合成一次**（或重用既有 `synth.aig`），再分別做 map-only，最後呼叫 `compare_nf_emap_map.sh` 做 Liberty `stime`。

```text
EPFL .aig
   │
   ▼
abc_syn_balance.abc  ──►  synth/<case>/synth.aig   （或 --reuse-synth-from）
   │
   ├──────────────────────┬──────────────────────┐
   ▼                      ▼                      │
abc_map_nf_y.abc     abc_map_emap_y.abc          │
&nf -Y               emap -Y                     │
   │                      │                      │
   ▼                      ▼                      │
nf/<case>/            emap/<case>/               │
*_nf.v + match        *_emap.v + matches         │
   │                      │                      │
   └──────────┬───────────┘                      │
              ▼                                  │
   compare_nf_emap_map.sh  → compare_nf_emap.md  │
```

**範例**：

```bash
# 重用先前 emap 跑出的 synth.aig（跳過 deepsyn；推薦）
./scripts/run_fair_nf_emap_compare.sh --scale all --parallel \
  --reuse-synth-from output/abc_emap_map_20260710_162632

# 從頭 deepsyn（慢；AND 仍保證兩邊相同）
./scripts/run_fair_nf_emap_compare.sh --cases "adder ctrl" --jobs 2

# smoke
./scripts/run_fair_nf_emap_compare.sh --cases "adder ctrl" --jobs 2 \
  --reuse-synth-from output/abc_emap_map_20260710_162632 \
  --out output/fair_nf_emap_smoke --cec
```

**輸出**：

```text
output/fair_nf_emap_<ts>/
  synth/<case>/synth.aig
  nf/<case>/{synth.aig, synth_and.txt, <case>_nf.v, <case>.txt, run.log}
  emap/<case>/{synth.aig, synth_and.txt, <case>_emap.v, matches.nf_y_multi.txt, run.log}
  report.md
  compare_nf_emap.md
```

兩邊 `synth_and.txt` 相同 ⇒ 報告中 `ΔAND%` 必為 `+0.0%`。

---

## `compare_nf_emap_map.sh`

**功能**：比對兩個 mapping 輸出目錄（`&nf -Y` vs `emap -Y`），並用**同一份 ASAP7 Liberty `stime`** 重跑 STA。建議輸入來自 `run_fair_nf_emap_compare.sh`（共用 `synth.aig`）；亦可比對舊的獨立 balance / emap 跑次（AND 可能因 `&deepsyn -T` 而不同）。

**STA 流程**（兩邊相同）：

```text
read_lib asap7.lib
read -m <mapped.v>     # emap 先做 Liberty 相容前處理
topo
stime                  # Gates / Area / Delay（同一單位）
```

emap 前處理：合併 twin FA/HA、補齊未用 CON/SN；`MAJIx2`→`MAJIxp5`；`XNOR3x1`→`XNOR2x1` cascade（僅為 STA 可跑）。

**範例**：

```bash
./scripts/compare_nf_emap_map.sh \
  --nf-dir output/abc_syn_map_20260709_201016 \
  --emap-dir output/abc_emap_map_20260710_162632 \
  --jobs 8

./scripts/compare_nf_emap_map.sh \
  --nf-dir output/abc_syn_map_20260709_201016 \
  --emap-dir output/abc_emap_map_20260710_162632 \
  --force-stime --out output/compare_nf_emap.md
```

**報告欄位**：post-synth AND、Liberty gates/area/delay、Δ%、emap MBIND。

**快取**：每 case 寫入 `<case>/stime_asap7.txt`（emap 另存 `*_emap_merged.v`）。

**預設輸出**：`<emap-dir>/compare_nf_emap.md`

---

## `validate_emap_mog_root_overlap.py`

**功能**：檢查 emap `matches.nf_y_multi.txt` 裡 FA/HA（MOG）的 **root-pair 是否形成 matching**——不同 binding 不可共用 AIG node。例如 `[a,b]→FA` 與 `[b,c]→HA` 會判為 FAIL。同一 root-pair 的多個 `BIND`（pin permutation / 不同 fanin 排列）視為合法替代，不算重疊。

**檢查範圍**（串流讀檔，可處理 GB 級 dump）：

1. `# --- MOG tuple candidates ---` 的 `BIND` + `ROOTS`
2. `# --- multi-output bindings (selected) ---` 的 `BIND` + `ROOTS`
3. `MBIND` 與 selected `BIND` id／cell 一致性，以及 MBIND 之間的 node 重疊

**範例**：

```bash
# 驗證 consolidated fair 跑次的 emap -M 3 dump
./scripts/validate_emap_mog_root_overlap.py output/fair_nf_emap_asap7genlib/emap

# 單一 case
./scripts/validate_emap_mog_root_overlap.py \
  output/fair_nf_emap_asap7genlib/emap/adder/matches.nf_y_multi.txt

# 連 emap_l1 一起查
./scripts/validate_emap_mog_root_overlap.py output/fair_nf_emap_asap7genlib --include-l1
```

**退出碼**：全部通過 `0`；任一 overlap／格式問題 `1`。

---

## `run_abc_emap_map.sh` / `abc_emap_map.abc`

**功能**：與 [`abc_syn_map_balance.abc`](../scripts/abc_syn_map_balance.abc) **共用同一段** balance 合成（`&if -y -K 6` + resyn2 + `&deepsyn -T 120`），只在 mapping 換成 `emap -Y`。用於公平比較 `&nf -Y` vs `emap -Y`。

```text
abc_syn_map_balance.abc          abc_emap_map.abc
─────────────────────            ────────────────
read; strash; read_lib           (identical)
&if + resyn2; &deepsyn           (identical)
strash; write_aiger synth.aig    (identical)
&get; &nf -Y; &put               read_genlib; emap -Y
write_verilog                    write_verilog
```

**範例**：

```bash
# 與 output/abc_syn_map_20260709_201016 相同的 EPFL 全集
./scripts/run_abc_emap_map.sh --scale all --parallel --dump-level 1

./scripts/run_abc_emap_map.sh --cases "adder ctrl" --dump-level 1 --cec
./scripts/run_abc_emap_map.sh --dump-level 3   # 預設也是 --scale all
```

**選項**：

| 選項 | 說明 |
|------|------|
| `--scale` / `--cases` | 預設 `--scale all`（arithmetic + random_control） |
| `--dump-level 1\|2\|3` | `emap -M`：1=warm start；2=+MOG tuples；3=+full SO cuts |
| `--emap-flags STR` | 預設 `-a -v`（area + verbose；MOG 預設開啟） |
| `--genlib PATH` | multioutput GENLIB |
| `--cec` | 對 mapped Verilog 與 `synth.aig` 做 CEC |

**輸出**（每 case）：

| 檔案 | 內容 |
|------|------|
| `synth.aig` | 與 `&nf -Y` 流程相同的 post-synth AIG |
| `matches.nf_y_multi.txt` | `emap -Y` match dump（含 `BIND` / `MBIND` / `M`） |
| `*_emap.v` | mapped Verilog |
| `run.abc` / `run.log` | 實際 ABC script 與 log |

**`emap -Y` 格式摘要**（`nf_y_multi_v1`）：

```text
# format: nf_y_multi_v1
<root_lit> <cell> <area> <n_fanins> <fanins...> 0 [BIND:<id>]
BIND <id> <cell> <area> <n_fanins> <fanins...> <root0> <root1>
  ROOTS ...
  ROLES CON SN
  FANINS ...
  COVER 0
M<root_lit> <cell> <area> <fanins...>
MBIND <id> <cell> <area> <fanins...>
```

---

## 規劃中（尚未實作）

以下見 [`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md) Phase 3：

| 項目 | 用途 |
|------|------|
| GradMap `nf_y_multi` parser | 讀 `BIND` / `MBIND`，binding-level softmax |
| `libcell_info_v2_multi_output` loader | MapLibrary 支援 FA/HA |

---

## 新增腳本時的檢查清單

新增或修改 `scripts/` 檔案時，請確認：

- [ ] 更新本文件**快速對照表**
- [ ] 新增獨立章節（功能、用法、選項、輸出、相依）
- [ ] 若為 ABC 模板，記錄 placeholder 與呼叫它的 runner
- [ ] 更新上方**管線總覽**（若流程有變）
- [ ] 在相關專題文件（如 `ABC_MOCKTURTLE_MULTI_OUTPUT.md`）加上交叉連結
- [ ] 腳本檔頭 comment 加上：`# See docs/SCRIPTS.md`

---

## 相關文件

| 文件 | 內容 |
|------|------|
| [`GRADUATE.md`](GRADUATE.md) | GRADUATE / GradMap / `graduate-abc` 建置 |
| [`GRADMAP.md`](GRADMAP.md) | GradMap 詳細說明（match file、訓練、multi-output） |
| [`MOCKTURTLE.md`](MOCKTURTLE.md) | mockturtle 子模組與 emap |
| [`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md) | ABC emap match dump + GradMap 整合規劃 |
| [`ASAP7_MULTI_OUTPUT_CELLS.md`](ASAP7_MULTI_OUTPUT_CELLS.md) | ASAP7 multi-output cell 盤點 |
| [`GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md`](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md) | libcell_info 格式細節 |
