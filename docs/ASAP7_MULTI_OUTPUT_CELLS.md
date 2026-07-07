# ASAP7 Multi-Output Standard Cell 參考手冊

本文件整理 GRADUATE 預設技術映射函式庫 `third_party/GRADUATE/third_party/gradmap_libs/asap7.lib` 中 **multi-output standard cell** 的完整資訊，並說明其與 mockturtle `emap`、GradMap 管線的關係。

> **資料來源**：`asap7.lib` 由 ABC 於 2025-01-24 從 ASAP7 7.5nm 製程 Liberty 檔合併產生（註解標明來源為 `asap7sc7p5t_SIMPLE_RVT_FF` 等原始庫）。本分析以目前工作區中的檔案為準。

---

## 目錄

1. [結論摘要](#結論摘要)
2. [原始 NLDM 函式庫分析（RVT FF）](#原始-nldm-函式庫分析rvt-ff)
3. [函式庫整體統計](#函式庫整體統計)
4. [Multi-Output Cell 一覽](#multi-output-cell-一覽)
5. [FAx1_ASAP7_75t_R（全加器）](#fax1_asap7_75t_r全加器)
6. [HAxp5_ASAP7_75t_R（半加器）](#haxp5_asap7_75t_r半加器)
7. [邏輯極性與 Truth Table](#邏輯極性與-truth-table)
8. [與 Single-Output 分解的成本比較](#與-single-output-分解的成本比較)
9. [GENLIB 表示（mockturtle 用）](#genlib-表示mockturtle-用)
10. [GradMap / libcell_info 的限制](#gradmap--libcell_info-的限制)
11. [對本專案的意義](#對本專案的意義)
12. [附錄：相關檔案](#附錄相關檔案)

---

## 結論摘要

**是的——不僅 `asap7.lib`，整個 ASAP7 RVT FF NLDM 原始函式庫中，combinational multi-output standard cell 也僅有 FA（全加器）與 HA（半加器）兩種。**

| 項目 | 數值 |
|------|------|
| `asap7.lib` 總 cell 數 | **169**（combinational） |
| `asap7_unified_FF.lib` 總 cell 數 | **202**（含 33 個 sequential） |
| Single-output combinational | **167** |
| **Multi-output combinational** | **2**（`FAx1_ASAP7_75t_R`、`HAxp5_ASAP7_75t_R`） |
| 輸出 pin 命名 | `CON`（carry）、`SN`（sum） |
| 驅動強度變體 | FA 僅 `x1`；HA 僅 `xp5`（無其他 drive 可選） |

這與 mockturtle 測試用 `multioutput.genlib` 一致——該 GENLIB 的 50 個 gate 中，**僅 FA 與 HA 以同名多輸出形式定義**；其餘皆為 single-output 標準閘。

AOI、OAI、AO、OA 等複合閘在原始 NLDM 庫中雖種類繁多，但**全部為 single-output**（僅一個邏輯輸出 pin `Y`）。

---

## 原始 NLDM 函式庫分析（RVT FF）

`asap7.lib` 的註解標明其來源為 `third_party/asap7sc7p5t_28/LIB/NLDM/` 中以下四個 combinational 庫的合併（不含 SEQ）：

| 原始檔案（`.7z`） | 解壓後 Cell 數 | Multi-output cell |
|------------------|---------------|-------------------|
| `asap7sc7p5t_SIMPLE_RVT_FF_nldm_211120.lib` | 56 | **FAx1、HAxp5**（僅此庫有） |
| `asap7sc7p5t_INVBUF_RVT_FF_nldm_220122.lib` | 37 | 0 |
| `asap7sc7p5t_AO_RVT_FF_nldm_211120.lib` | 42 | 0 |
| `asap7sc7p5t_OA_RVT_FF_nldm_211120.lib` | 34 | 0 |
| `asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib` | 33 | 0（sequential，見下） |
| **合計（unified）** | **202** | **2** |

### 與合併檔的對應關係

```text
asap7sc7p5t_SIMPLE  ─┐
asap7sc7p5t_INVBUF  ─┼─► asap7_merged_FF.lib (169 cells) ──► asap7.lib (169, ABC 簡化)
asap7sc7p5t_AO      ─┤
asap7sc7p5t_OA      ─┘
asap7sc7p5t_SEQ     ────► 僅在 asap7_unified_FF.lib (202 cells) 中
```

`asap7_merged_FF.lib` 與 `asap7.lib` 的 169 個 cell 相同（combinational）；`asap7_unified_FF.lib` 額外包含 33 個 sequential cell（DFF、ICG 等）。

### 判定標準

Multi-output standard cell 的判定條件：**同一 cell 內有 ≥2 個 `direction: output` 的 pin，且各自帶有獨立的組合邏輯 `function`**。

### 為何許多 cell 看起來有「多個 function」卻不是 multi-output

原始 Liberty 中大量 cell 有 2–4 個 `function` 欄位，但多數**不是** multi-output：

| 情況 | 範例 | 說明 |
|------|------|------|
| 電源接地函式 | 所有 cell 的輸出 pin | 第二個 `function: "(!VDD) + (VSS)"` 為 power-ground 約束，非邏輯輸出 |
| Sequential 內部狀態 | `DFFHQNx1` 的 `QN` pin | `function: "IQN"` 為 flip-flop 內部狀態，非組合邏輯輸出 |
| 單一邏輯輸出 | `AND2x2`、`AOI21` 等 | 僅一個 `Y` 輸出 pin |

### Sequential 庫（SEQ）的特殊情況

`asap7sc7p5t_SEQ_RVT_FF_nldm_220123.lib` 含 33 個時序 cell，輸出 pin 分佈：

| 輸出 Pin | Cell 數 | 說明 |
|---------|--------|------|
| `Q` | 8 | 正相輸出（如 `DFFHQx4`） |
| `QN` | 15 | 反相輸出（如 `DFFHQNx1`） |
| `GCLK` | 10 | 時鐘閘控輸出（ICG 系列） |

**沒有任何 sequential cell 同時提供 `Q` 與 `QN` 兩個輸出 pin**——每個 DFF 變體只提供其中一種。因此 SEQ 庫也不存在 combinational 意義上的 multi-output cell。

### FA/HA 僅存在於 SIMPLE 庫

在 SIMPLE 庫的 56 個 cell 中，FA/HA 是唯一具有兩個邏輯輸出（`CON`、`SN`）的 cell，且**無其他 drive 變體**（例如無 `FAx2`、`HAx1` 等）。

---

## 函式庫整體統計

### 檔案資訊

```text
路徑: third_party/GRADUATE/third_party/gradmap_libs/asap7.lib
格式: Liberty (.lib)
產生工具: ABC (2025-01-24)
原始來源: ASAP7 sc7p5t RVT FF NLDM
時間單位: 1 ps
電容單位: 1 ff
```

### Single-Output Cell 主要族群（167 個）

| 族群 | 數量 | 說明 |
|------|------|------|
| BUF | 12 | 緩衝器（多種 drive） |
| CKINVDC | 10 | 時鐘反相器 |
| INV | 9 | 反相器 |
| AND / NAND / OR / NOR | 各 3–12 | 基本二/三/四/五輸入閘 |
| AOI / OAI / AO / OA | 各 13–21 | 複合閘（皆 single-output） |
| XOR / XNOR | 各 2–3 | 二輸入異或/同或 |
| MAJ | 2 | 多數閘 |
| HB | 4 | Hierarchical buffer |
| TIEHI / TIELO | 各 1 | 常數 tie cell |

所有 AOI、OAI、AO、OA 等複合結構在此庫中均以 **single-output** 形式提供，**不是** multi-output cell。

### 不在 libcell_info 中的 cell

`asap7_libcell_info.txt`（GradMap 用）由 `generate_libcell_info_v2.py` 產生，**僅接受恰好 1 個輸出 pin 的 cell**。因此以下 cell 存在於 `asap7.lib` 但**未**出現在 `libcell_info` 中：

| Cell | 原因 |
|------|------|
| `FAx1_ASAP7_75t_R` | 2 個輸出（CON, SN） |
| `HAxp5_ASAP7_75t_R` | 2 個輸出（CON, SN） |
| `TIEHIx1_ASAP7_75t_R` | 常數 cell（無輸入 pin） |
| `TIELOx1_ASAP7_75t_R` | 常數 cell（無輸入 pin） |

---

## Multi-Output Cell 一覽

| Cell 名稱 | 類型 | 輸入數 | 輸出數 | 輸入 Pin | 輸出 Pin | Area (µm²) | Leakage |
|-----------|------|--------|--------|----------|----------|------------|---------|
| `FAx1_ASAP7_75t_R` | Full Adder | 3 | 2 | A, B, CI | CON, SN | 0.20412 | 303.42 |
| `HAxp5_ASAP7_75t_R` | Half Adder | 2 | 2 | A, B | CON, SN | 0.13122 | 197.73 |

### 命名規則

```text
FAx1_ASAP7_75t_R
│ │  │       │  └─ 製程角/版本 (RVT FF)
│ │  │       └──── 金屬層/閾值 (75t)
│ │  └──────────── PDK 名稱 (ASAP7)
│ └─────────────── 驅動強度 (x1 = 1x)
└───────────────── 功能 (FA = Full Adder)

HAxp5_ASAP7_75t_R
                 └─ xp5 = 0.5x 驅動（較小驅動）
```

### Pin 語意

| Pin | 全名推測 | 邏輯角色 |
|-----|---------|---------|
| `A`, `B` | 加數輸入 | 第一、第二個加數位元 |
| `CI` | Carry In | 進位輸入（僅 FA） |
| `CON` | Carry Out (inverted) | 進位輸出（**反相邏輯**） |
| `SN` | Sum (inverted) | 和輸出（**反相邏輯**） |

ASAP7 的 FA/HA 採用 **反相輸出極性**（negative logic outputs），詳見 [邏輯極性與 Truth Table](#邏輯極性與-truth-table)。

---

## FAx1_ASAP7_75t_R（全加器）

### 基本參數

| 屬性 | 值 |
|------|-----|
| Cell 名稱 | `FAx1_ASAP7_75t_R` |
| 輸入 | `A`, `B`, `CI`（3 個） |
| 輸出 | `CON`, `SN`（2 個） |
| Area | 0.20412 µm² |
| Cell leakage power | 303.42 nW |
| Drive strength | x1 |

### 輸入 Pin 電容

| Pin | Rise capacitance (ff) | Fall capacitance (ff) |
|-----|----------------------|----------------------|
| A | 1.9956 | 1.9978 |
| B | 2.1737 | 2.1764 |
| CI | 1.6097 | 1.6139 |

### 輸出 Pin 邏輯函式

Liberty 中的 `function` 欄位（`+` = OR，`*` = AND，`!` = NOT）：

| 輸出 | Liberty Function | Truth Table |
|------|-----------------|-------------|
| **CON** | `(!A * !B) + (!A * !CI) + (!B * !CI)` | `0x17` |
| **SN** | `(A * B * !CI) + (A * !B * CI) + (!A * B * CI) + (!A * !B * !CI)` | `0x69` |

### 輸出 Pin 時序特性

| 輸出 | max_capacitance (ff) | timing_sense | 輸入弧數 |
|------|---------------------|--------------|---------|
| CON | 46.08 | `negative_unate` | 3（A, B, CI 各一組 timing arc） |
| SN | 46.08 | `positive_unate` | 3（A, B, CI 各一組 timing arc） |

每個輸出 pin 對每個輸入 pin 各有一組完整 NLDM 時序表（`cell_rise`, `cell_fall`, `rise_transition`, `fall_transition`），共 7×7 的 slew/load 索引表。

### 等效邏輯（考慮反相）

以標準全加器符號表示（`⊕` = XOR）：

```text
CON = NOT( A·B + A·CI + B·CI )    // 反相的進位
SN  = NOT( A ⊕ B ⊕ CI )           // 反相的和
```

---

## HAxp5_ASAP7_75t_R（半加器）

### 基本參數

| 屬性 | 值 |
|------|-----|
| Cell 名稱 | `HAxp5_ASAP7_75t_R` |
| 輸入 | `A`, `B`（2 個） |
| 輸出 | `CON`, `SN`（2 個） |
| Area | 0.13122 µm² |
| Cell leakage power | 197.73 nW |
| Drive strength | xp5（0.5x，較小驅動） |

### 輸入 Pin 電容

| Pin | Rise capacitance (ff) | Fall capacitance (ff) |
|-----|----------------------|----------------------|
| A | 1.0641 | 1.0559 |
| B | 0.9137 | 0.9955 |

### 輸出 Pin 邏輯函式

| 輸出 | Liberty Function | Truth Table |
|------|-----------------|-------------|
| **CON** | `(!A) + (!B)` | `0x7` |
| **SN** | `(A * B) + (!A * !B)` | `0x9` |

### 輸出 Pin 時序特性

| 輸出 | max_capacitance (ff) | timing_sense | 輸入弧數 |
|------|---------------------|--------------|---------|
| CON | 23.04 | `negative_unate` | 2（A, B） |
| SN | 23.04 | `positive_unate` | 2（A, B） |

### 等效邏輯（考慮反相）

```text
CON = NOT( A · B )     // NAND(A,B)，即反相的進位
SN  = NOT( A ⊕ B )     // XNOR(A,B)，即反相的和
```

---

## 邏輯極性與 Truth Table

ASAP7 的 FA/HA 輸出為 **反相邏輯**（與教科書上「Sum = A⊕B、Carry = A·B」的正邏輯表示不同）。以下以 3 輸入（A, B, CI）的位元順序 `{A,B,CI}` 列出 truth table（bit i 對應輸入組合的第 i 種）。

### Full Adder Truth Table

| A | B | CI | CON（庫定義） | SN（庫定義） | 標準 Cout | 標準 Sum |
|---|---|----|--------------|-------------|-----------|----------|
| 0 | 0 | 0 | 1 | 1 | 0 | 0 |
| 1 | 0 | 0 | 1 | 0 | 0 | 1 |
| 0 | 1 | 0 | 1 | 0 | 0 | 1 |
| 1 | 1 | 0 | 0 | 1 | 1 | 0 |
| 0 | 0 | 1 | 1 | 0 | 0 | 1 |
| 1 | 0 | 1 | 0 | 1 | 0 | 0 |
| 0 | 1 | 1 | 0 | 1 | 0 | 0 |
| 1 | 1 | 1 | 0 | 0 | 1 | 1 |

觀察：

- `CON = NOT(Cout)`，truth table `0x17` = `NOT(0xE8)`
- `SN = NOT(A ⊕ B ⊕ CI)`，truth table `0x69` = `NOT(0x96)`

### Half Adder Truth Table

| A | B | CON（庫定義） | SN（庫定義） | 標準 Carry | 標準 Sum |
|---|----|--------------|-------------|-----------|----------|
| 0 | 0 | 1 | 1 | 0 | 0 |
| 1 | 0 | 1 | 0 | 0 | 1 |
| 0 | 1 | 1 | 0 | 0 | 1 |
| 1 | 1 | 0 | 0 | 1 | 0 |

觀察：

- `CON = NAND(A,B) = NOT(A·B)`，truth table `0x7`
- `SN = XNOR(A,B) = NOT(A⊕B)`，truth table `0x9`

### 對 Technology Mapping 的影響

1. **mockturtle `emap`** 使用 Liberty/GENLIB 中的 `function` 字串做 Boolean matching，會正確匹配反相輸出形式；映射時需注意下游是否需要額外插入 INV。
2. **GRADUATE GradMap** 目前不支援這兩個 cell（見下節），因此現有管線會將加法器結構分解為 single-output XOR/AND 閘。
3. 若要在網表輸出時還原為正邏輯訊號名，可能需要在 `CON`/`SN` 後串接反相器，或在上游合成時預先吸收極性。

---

## 與 Single-Output 分解的成本比較

若以同函式庫中的 single-output cell 分解 FA/HA，面積成本如下：

### Half Adder

| 映射方式 | 使用的 Cell | 總 Area (µm²) | 相對 HAxp5 |
|---------|------------|--------------|-----------|
| **Multi-output** | `HAxp5_ASAP7_75t_R` | **0.13122** | 1.00× |
| Single-output 分解 | `XOR2x2` + `AND2x2` | 0.24786 | 1.89× |

**HA multi-output 映射可節省約 47% 面積。**

### Full Adder

| 映射方式 | 使用的 Cell | 總 Area (µm²) | 相對 FAx1 |
|---------|------------|--------------|----------|
| **Multi-output** | `FAx1_ASAP7_75t_R` | **0.20412** | 1.00× |
| Single-output 分解 | `2× XOR2x2` + `AND3x1` | 0.40824 | 2.00× |
| Single-output 分解（較小驅動） | `2× XOR2xp5` + `AND3x1` | 0.34992 | 1.71× |

**FA multi-output 映射可節省約 50% 面積**（相對於 2×XOR2x2 + AND3x1 的 naive 分解）。

這也是實作 multi-output technology mapping 的核心動機：在 ripple-carry adder、multiplier 等算術電路中，大量 FA/HA 實例若能以 multi-output cell 映射，面積收益顯著。

---

## GENLIB 表示（mockturtle 用）

mockturtle `emap` 使用 GENLIB 格式，multi-output cell 以 **同名 GATE 條目、不同輸出函式** 表示。`experiments/cell_libraries/multioutput.genlib` 中的定義與 `asap7.lib` 邏輯一致：

```text
GATE FAx1_ASAP7_75t_R  0.24  CON=(!A * !B) + (!A * !CI) + (!B * !CI);
    PIN  A  UNKNOWN  ...
    PIN  B  UNKNOWN  ...
    PIN CI  UNKNOWN  ...
GATE FAx1_ASAP7_75t_R  0.24  SN=(A * B * !CI) + (A * !B * CI) + (!A * B * CI) + (!A * !B * !CI);
    PIN  A  UNKNOWN  ...
    PIN  B  UNKNOWN  ...
    PIN CI  UNKNOWN  ...

GATE HAxp5_ASAP7_75t_R  0.19  CON=(!A) + (!B);
    PIN  A  UNKNOWN  ...
    PIN  B  UNKNOWN  ...
GATE HAxp5_ASAP7_75t_R  0.19  SN=(A * B) + (!A * !B);
    PIN  A  UNKNOWN  ...
    PIN  B  UNKNOWN  ...
```

| 項目 | asap7.lib | multioutput.genlib |
|------|-----------|-------------------|
| FA area | 0.20412 | 0.24（含時序權重的近似值） |
| HA area | 0.13122 | 0.19 |
| 邏輯函式 | 相同 | 相同 |
| 輸出 pin 名 | CON, SN | CON, SN |

mockturtle 的 `get_standard_cells()` 會將同名 `GATE` 條目合併為一個 `standard_cell`，`gates` 向量包含 CON 與 SN 兩個輸出的邏輯。

---

## GradMap / libcell_info 的限制

### 為何 GradMap 目前無法映射 FA/HA

`scripts/generate_libcell_info_v2.py` 在解析 Liberty 時有明確限制：

```python
output_pins_with_function = [pin for pin in output_pins if pin.attr("function")]
if len(output_pins_with_function) != 1:
    return None  # 跳過多輸出 cell
```

因此：

- `FAx1_ASAP7_75t_R` 和 `HAxp5_ASAP7_75t_R` **不會**出現在 `asap7_libcell_info.txt` 中
- GradMap 的 `&nf -Y` 匹配流程以 `libcell_info` 為基礎，**目前僅支援 single-output cell**
- 這正是本專案要解決的問題：擴展技術映射以支援 multi-output standard cell

### libcell_info 與 asap7.lib 的差異

| 項目 | asap7.lib | asap7_libcell_info.txt |
|------|-----------|----------------------|
| Cell 數量 | 169 | 187 |
| 含 sequential cell | 否 | 是（DFF 等 22 個，來自其他來源） |
| 含 FA/HA | 是 | **否**（被跳過） |
| 含 TIEHI/TIELO | 是 | 否 |

`libcell_info` 的 187 個 cell 與 `asap7.lib` 的 169 個 cell **不是一一對應**；libcell_info 額外包含時序 cell，且缺少 multi-output 與 tie cell。

---

## 對本專案的意義

### 現狀

```text
asap7.lib
  ├─ 167 個 single-output cell  → GradMap 可映射 ✓
  └─ 2 個 multi-output cell (FA, HA)  → GradMap 不支援 ✗
                                         mockturtle emap 可映射 ✓
```

### 建議實作路線

1. **短期驗證**：使用 mockturtle `emap` + `multioutput.genlib`（或從 `asap7.lib` 轉出的 GENLIB）驗證 multi-output 映射行為與面積收益。
2. **Liberty → GENLIB 轉換**：為 `asap7.lib` 中的 FA/HA 建立正確的 GENLIB 條目（邏輯函式已確認一致）。
3. **擴展 GradMap**：修改 `generate_libcell_info_v2.py` 與 GradMap 後端，支援每個 cell 多個輸出 pin 與對應 timing arc。
4. **極性處理**：在映射與 Verilog 輸出流程中處理 CON/SN 的反相邏輯，確保等價性。

### 預期收益場景

根據 mockturtle `experiments/emap` 在 EPFL benchmarks 上的結果，啟用 `map_multioutput=true` 後：

| Benchmark | Multi-output gates 使用數 |
|-----------|--------------------------|
| adder | 61 |
| hyp | 11,026 |
| log2 | 914 |
| multiplier | 708 |
| square | 1,205 |
| voter | 205 |

算術密集型電路受益最大，與 FA/HA 在庫中僅有這兩種 multi-output cell 的事實一致。

---

## 附錄：相關檔案

| 檔案 | 說明 |
|------|------|
| `third_party/asap7sc7p5t_28/LIB/NLDM/` | ASAP7 原始 NLDM 函式庫（`.7z` 壓縮） |
| `third_party/asap7sc7p5t_28/asap7_merged_FF.lib` | 合併後的 combinational 庫（169 cells） |
| `third_party/asap7sc7p5t_28/asap7_unified_FF.lib` | 含 sequential 的完整庫（202 cells） |
| `third_party/GRADUATE/third_party/gradmap_libs/asap7.lib` | GradMap 用 ABC 簡化版（169 cells） |
| `third_party/GRADUATE/third_party/gradmap_libs/asap7_libcell_info.txt` | GradMap 用 flattened timing（不含 FA/HA） |
| `third_party/GRADUATE/scripts/generate_libcell_info_v2.py` | libcell_info 產生器（跳過多輸出 cell） |
| `third_party/mockturtle/experiments/cell_libraries/multioutput.genlib` | mockturtle emap 測試用 GENLIB |
| `docs/MOCKTURTLE.md` | mockturtle 使用指南（含 emap 流程） |
| `docs/GRADUATE.md` | GRADUATE / GradMap 使用指南 |

### 快速查詢命令

```bash
# 列出 asap7.lib 中所有 multi-output cell
grep 'n_outputs = 2' third_party/GRADUATE/third_party/gradmap_libs/asap7.lib

# 確認 FA/HA 不在 libcell_info 中
grep -E 'FAx|HAx' third_party/GRADUATE/third_party/gradmap_libs/asap7_libcell_info.txt
# （應無輸出）

# 執行 mockturtle emap 測試
cd third_party/mockturtle/build
./test/run_tests "[emap]"
./experiments/emap
```
