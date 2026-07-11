# generate_libcell_info_v2_multi_output 使用說明

本文件說明工作區腳本 `scripts/py/generate_libcell_info_v2_multi_output.py`。  
它仿造 GRADUATE 的 `third_party/GRADUATE/scripts/generate_libcell_info_v2.py`，但**保留 multi-output standard cell**（例如 ASAP7 的 `FAx1_ASAP7_75t_R`、`HAxp5_ASAP7_75t_R`）。

---

## 與 GRADUATE 原版差異

| 項目 | `generate_libcell_info_v2.py` | `generate_libcell_info_v2_multi_output.py` |
|------|------------------------------|------------------------------------------|
| 輸出格式 | `format: libcell_info_v2` | `format: libcell_info_v2_multi_output` |
| 輸出 pin | 每 cell 僅 1 個 `output_pin` + `function` | `outputs_num` + 多個 `output:` 區塊 |
| Multi-output cell | 跳過（FA/HA 不會輸出） | **保留** |
| Timing arc | 每個 Liberty `timing()` 一筆 | 相同，且每筆帶 `output_pin` |
| Tie cell（TIEHI/TIELO） | 跳過 | 預設跳過；加 `--include-tie-cells` 可保留 |

> **注意**：截至目前，GRADUATE 的 `MapLibrary::load_libcell_info_v2()` **尚未實作** `libcell_info_v2_multi_output` 讀取。此腳本主要供本專案後續擴展 GradMap / timing model 使用。

---

## 輸出格式摘要

```text
format: libcell_info_v2_multi_output

libcell: FAx1_ASAP7_75t_R
area: ...
max_leakage: ...
input_pins_num: 3
pin: A rise_cap ... fall_cap ... cap ...
pin: B rise_cap ... fall_cap ... cap ...
pin: CI rise_cap ... fall_cap ... cap ...
outputs_num: 2
output:
pin: CON
function: (!A * !B) + (!A * !CI) + (!B * !CI)
output:
pin: SN
function: (A * B * !CI) + (A * !B * CI) + (!A * B * CI) + (!A * !B * !CI)
timing_arcs_num: 12

arc:
input_pin: A
output_pin: CON
timing_sense: negative_unate
luts_num: 4
lut:
...
```

Single-output cell 使用相同結構，只是 `outputs_num: 1`。

---

## 基本用法

### 1. 從 GradMap 預設 `asap7.lib` 產生

```bash
cd /path/to/multi_output_standard_cell

python3 scripts/py/generate_libcell_info_v2_multi_output.py \
  third_party/GRADUATE/third_party/gradmap_libs/asap7.lib \
  -o output/asap7_libcell_info_v2_multi_output.txt
```

預期結果（以目前 `asap7.lib` 為準）：

- `cells=167`（165 single-output + 2 multi-output）
- `skipped=2`（`TIEHIx1`、`TIELOx1`，無 timing arc）
- `multi_output=2`（`FAx1_ASAP7_75t_R`、`HAxp5_ASAP7_75t_R`）

### 2. 從原始 RVT FF NLDM 庫產生

若要先合併四個 combinational `.lib` 成 `asap7.lib`，請參考 `docs/GRADUATE.md`。  
合併後再執行：

```bash
python3 scripts/py/generate_libcell_info_v2_multi_output.py \
  path/to/asap7.lib \
  -o output/asap7_libcell_info_v2_multi_output.txt
```

或直接指定 SIMPLE 庫（僅含 FA/HA 與基本邏輯閘）：

```bash
python3 scripts/py/generate_libcell_info_v2_multi_output.py \
  third_party/asap7_RVT_FF_nldm/asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib \
  -o output/simple_libcell_info_v2_multi_output.txt
```

### 3. 多個 Liberty 檔一次輸入

```bash
python3 scripts/py/generate_libcell_info_v2_multi_output.py \
  third_party/GRADUATE/third_party/gradmap_libs/asap7.lib \
  third_party/asap7_RVT_FF_nldm/asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib \
  -o output/asap7_with_seq_libcell_info_v2_multi_output.txt
```

後者會嘗試解析 sequential cell；能否成功取決於 Liberty pin / timing 結構是否符合腳本假設。

### 4. 保留 tie cell

```bash
python3 scripts/py/generate_libcell_info_v2_multi_output.py \
  third_party/GRADUATE/third_party/gradmap_libs/asap7.lib \
  --include-tie-cells \
  -o output/asap7_with_tie_libcell_info_v2_multi_output.txt
```

Tie cell 會被寫入但 `timing_arcs_num: 0`。

---

## 驗證輸出

```bash
# 確認格式標頭
head -1 output/asap7_libcell_info_v2_multi_output.txt

# 列出 multi-output cell
grep -E '^libcell: (FAx|HAx)' output/asap7_libcell_info_v2_multi_output.txt

# 檢查某個 FA 的輸出 pin 定義
awk '/^libcell: FAx1_ASAP7_75t_R$/,/^libcell:/' \
  output/asap7_libcell_info_v2_multi_output.txt | head -30
```

---

## 跳過規則

腳本會跳過以下 cell：

1. 沒有任何邏輯 `function` 的 output pin
2. 有輸入但所有 output pin 都沒有完整 timing LUT（非 tie cell）
3. Tie cell 且未指定 `--include-tie-cells`
4. Liberty 解析錯誤（會印 `warning: skipping cell ...`）

Power-ground 約束 `(!VDD) + (VSS)` 不視為邏輯輸出。

---

## 相關文件

| 文件 | 說明 |
|------|------|
| [ASAP7_MULTI_OUTPUT_CELLS.md](ASAP7_MULTI_OUTPUT_CELLS.md) | ASAP7 FA/HA multi-output cell 分析 |
| [GRADUATE.md](GRADUATE.md) | GradMap 流程與原版 `generate_libcell_info_v2.py` |
| `third_party/GRADUATE/scripts/generate_libcell_info_v2.py` | 僅 single-output 的參考實作 |

---

## 後續工作（本專案）

1. 擴展 GRADUATE `MapLibrary` 以載入 `libcell_info_v2_multi_output`
2. 在 GradMap timing / reconstruction 路徑支援多輸出 pin
3. 與 mockturtle `emap` multi-output GENLIB 對齊驗證
