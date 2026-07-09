# ABC × mockturtle Multi-Output Mapping 整合規劃

本文件說明在 **目前專案狀態** 下，如何將 `third_party/GRADUATE` 的 `graduate-abc` 與 `third_party/mockturtle` 的 `emap` 整合，以產生 **multi-output standard cell**（FA/HA）映射結果；並規劃如何產生與 ABC `&nf -Y` **相容、可擴充** 的 match file（`.txt`），作為 GradMap 輸入。

> **相關文件**：[GRADUATE.md](GRADUATE.md)、[MOCKTURTLE.md](MOCKTURTLE.md)、[ASAP7_MULTI_OUTPUT_CELLS.md](ASAP7_MULTI_OUTPUT_CELLS.md)、[GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md)

---

## 目錄

1. [現狀摘要](#現狀摘要)
2. [目標與非目標](#目標與非目標)
3. [整體架構](#整體架構)
4. [現階段可執行流程（Phase 0）](#現階段可執行流程phase-0)
5. [`&nf -Y` match file 語意回顧](#nf--y-match-file-語意回顧)
6. [Multi-Output 的核心問題](#multi-output-的核心問題)
7. [提議：`nf_y_multi` 擴充格式](#提議nf_y_multi-擴充格式)
8. [ABC literal 對齊規則](#abc-literal-對齊規則)
9. [mockturtle → match file 轉換規劃](#mockturtle--match-file-轉換規劃)
10. [GradMap 擴充規劃](#gradmap-擴充規劃)
11. [實作階段路線圖](#實作階段路線圖)
12. [驗證策略](#驗證策略)
13. [風險與限制](#風險與限制)
14. [附錄：檔案與命令速查](#附錄檔案與命令速查)

---

## 現狀摘要

### 已有、可直接使用

| 元件 | 路徑 | 能力 |
|------|------|------|
| `graduate-abc` | `third_party/GRADUATE/build_abc_frontend/graduate-abc` | ABC 合成、`&nf`、`&nf -Y`、GradMap |
| balance flow | `scripts/run_abc_syn_map.sh --flow balance` | 產生 `&nf -Y` match + Verilog |
| mockturtle | `third_party/mockturtle` | `emap` multi-output 映射（GENLIB） |
| multi-output libcell | `output/asap7_libcell_info_v2_multi_output.txt` | 含 FA/HA（**GradMap 尚未能讀**） |
| EPFL benchmarks | `third_party/benchmarks/EPFL/` | 透過 `data/epfl/*.yaml` 選取 |

### 尚未實作

| 項目 | 說明 |
|------|------|
| ABC ↔ mockturtle 單一命令整合 | 無 `graduate-abc` 內建 emap |
| mockturtle → `&nf -Y` 轉換器 | mockturtle 不原生輸出此格式 |
| GradMap multi-output binding | 選擇單位仍是 per-root literal |
| `libcell_info_v2_multi_output` loader | `MapLibrary` 僅支援 single-output |
| 根目錄 `mo_techmap` 工具 | `docs/MOCKTURTLE.md` 中規劃，尚未建立 |

### 關鍵事實

```text
asap7.lib
  ├─ 167 個 single-output cell  → ABC &nf -Y + GradMap ✓
  └─ 2 個 multi-output cell (FA, HA)  → mockturtle emap ✓
                                       → 現有 GradMap ✗
```

ABC `&nf -Y` 對 FA/HA 即使出現在 `asap7.lib`，也會因 `asap7_libcell_info.txt` 不含 FA/HA 而在 GradMap 訓練階段失敗。multi-output 必須走 mockturtle 或擴充後的 GradMap 路徑。

---

## 目標與非目標

### 目標

1. **短期**：用 `graduate-abc` 合成 + mockturtle `emap` 產生含 FA/HA 的 mapped Verilog，驗證 area 收益。
2. **中期**：產生與 `&nf -Y` **語意相容** 的 `.txt`，讓 GradMap 能讀取並優化（含 multi-output）。
3. **長期**：GradMap 支援 **binding-level** 聯合選擇，解決同一 FA/HA 出現在多個 root literal 的機率耦合問題。

### 非目標（目前階段）

- 在 `graduate-abc` 內直接連結 mockturtle（可作為 Phase 4 選項）
- 取代 ABC `&nf` 的全部候選列舉邏輯（emap 與 `&nf` 候選空間不完全相同）
- 一次完成所有 AOI/OAI multi-output（ASAP7 庫僅 FA/HA 為 true multi-output）

---

## 整體架構

### 目標管線（完整版）

```text
                    ┌──────────────────────────┐
  design.aig ──────►│ graduate-abc             │
                    │  strash / resyn2 /       │
                    │  balance / deepsyn       │
                    └────────────┬─────────────┘
                                 │ synth.aig（單一真相來源）
           ┌─────────────────────┼─────────────────────┐
           ▼                     ▼                     ▼
  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
  │ ABC &nf -Y      │  │ mockturtle emap │  │ literal map     │
  │ (SO candidates) │  │ (MO mapping)    │  │ AIG↔ABC lit     │
  └────────┬────────┘  └────────┬────────┘  └────────┬────────┘
           │                    │                      │
           └──────────┬─────────┴──────────────────────┘
                      ▼
           ┌─────────────────────────┐
           │ mo_match_exporter       │  ← 待實作
           │  merge → nf_y_multi.txt │
           └────────────┬────────────┘
                        ▼
           ┌─────────────────────────┐
           │ graduate-abc gradmap    │  ← 需擴充
           │  binding-aware training │
           └────────────┬────────────┘
                        ▼
                  mapped Verilog
```

### 現階段可跑通的簡化管線（Phase 0）

```text
graduate-abc（合成）→ synth.aig
mockturtle emap（multi-output GENLIB）→ mapped.v
graduate-abc cec（等價驗證）
```

此管線 **不產生** GradMap 可用的 match file，但可驗證 multi-output mapping 正確性與 QoR。

---

## 現階段可執行流程（Phase 0）

> 腳本細節見 [`SCRIPTS.md`](SCRIPTS.md)。

### 一鍵管線（推薦）

```bash
cd ~/research/multi_output_standard_cell

# 建置 mo_techmap + 跑 balance 合成 + mockturtle emap
./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder

# 批次（tiny scale，平行）
./scripts/run_abc_mockturtle_map.sh --scale tiny --parallel --cec
```

輸出目錄結構（每個 case）：

```
output/abc_mockturtle_map_<timestamp>/<case>/
  synth.aig              # ABC balance 合成後 AIG（無 &nf）
  synth.log
  <case>_mo_mapped.v     # mockturtle emap 映射 Verilog
  stats.txt              # area / delay / multioutput_gates
  map.log
```

此管線等同 `run_abc_syn_map.sh --flow balance` **去掉** `&nf -Y` 與 `write_verilog`，改由 `mo_techmap` 做 multi-output mapping。

### Step 1：ABC 合成（僅 AIG）

專用 ABC script：`scripts/abc_syn_balance.abc`

```bash
./scripts/run_abc_mockturtle_map.sh --cases adder --out output/synth_adder
# 或只合成、稍後再 map：
./scripts/run_abc_mockturtle_map.sh --cases adder --skip-synth  # 需已有 synth.aig
```

手動從 `graduate-abc` 匯出合成後 AIG（與 balance flow 合成段相同）：

```bash
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read ../benchmarks/EPFL/arithmetic/adder.aig; st; \
   read_lib third_party/gradmap_libs/asap7.lib; \
   &get; &if -y -K 6; &put; balance; rewrite; refactor; balance; \
   rewrite; rewrite -z; balance; refactor -z; rewrite -z; balance; \
   &get; &deepsyn -T 120; strash; \
   write_aiger /path/to/output/synth/adder.aig; ps"
```

### Step 2：建置 mo_techmap

`mo_techmap` 是本 repo 自己的工具（`src/mo_techmap.cpp`），由**專案根目錄**的 `CMakeLists.txt` 建置，產物落在 **`build/mo_techmap`**（repo root 下的 `build/`，不是 `third_party/mockturtle/build/`）。

#### 為什麼是 `build/`，不是 `third_party/mockturtle/build/`？

本專案目前有**兩套獨立的 CMake build tree**，用途不同：

| Build 目錄 | CMake 入口 | 主要產物 | 用途 |
|------------|-----------|---------|------|
| **`build/`**（repo root） | `./CMakeLists.txt` | `build/mo_techmap` | 讀任意 `synth.aig`，跑 multi-output emap，輸出 mapped Verilog |
| **`third_party/mockturtle/build/`** | `third_party/mockturtle/CMakeLists.txt` | `experiments/emap` 等 | mockturtle 上游 experiment；只吃內建 EPFL benchmark 清單 |

根目錄 `CMakeLists.txt` 透過 `add_subdirectory(third_party/mockturtle)` **嵌入** mockturtle 當函式庫（header-only + `libabcsat` / `libabcesop`），只編譯 `mo_techmap` 需要的部分；**不會**建 `MOCKTURTLE_BUILD_EXPERIMENTS=ON` 的 `emap` experiment。

因此：

- 你在 `third_party/mockturtle/build` 編好的 `emap` **不能**直接拿來 map 自訂 `synth.aig`。
- `run_abc_mockturtle_map.sh` 預設找的是 **`$ROOT_DIR/build/mo_techmap`**（可用 `--mo-techmap` 或環境變數 `MO_TECHMAP` 覆寫）。

#### 建置命令

在 repo root 執行（`-S .` = source 目錄為當前專案，`-B build` = build 產物寫入 `./build/`）：

```bash
cd ~/research/multi_output_standard_cell

cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc) --target mo_techmap
# 產物：./build/mo_techmap
```

或用腳本自動建置（內部同樣是 `cmake -S $ROOT_DIR -B $ROOT_DIR/build`）：

```bash
./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder
```

`build/` 為本機編譯產物，不需 commit；若已存在 `third_party/mockturtle/build/`，兩者互不影響，可並存。

若只想跑 mockturtle 上游 EPFL 回歸（非本管線），仍可在 mockturtle 子目錄單獨建置：

```bash
cd third_party/mockturtle
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DMOCKTURTLE_BUILD_EXPERIMENTS=ON
cmake --build build -j$(nproc) --target emap
# 產物：third_party/mockturtle/build/experiments/emap
```

### Step 3：mockturtle multi-output 映射

使用 repo root 建出的 `mo_techmap`（預設路徑）：

```bash
./build/mo_techmap \
  --aig output/.../adder/synth.aig \
  --genlib third_party/mockturtle/experiments/cell_libraries/multioutput.genlib \
  --out output/.../adder/adder_mo_mapped.v \
  --stats output/.../adder/stats.txt
```

GENLIB 路徑在 `third_party/mockturtle/...` 是因為 cell library **檔案**放在 mockturtle 子模組內；與 binary 建在 `build/` 無關。

參數要點（見 `emap.hpp`，已寫死在 `src/mo_techmap.cpp`）：

```cpp
ps.map_multioutput = true;
ps.area_oriented_mapping = true;  // 算術電路較易選到 FA/HA（預設）
// --delay-oriented 可改為 delay-oriented mapping
```

### Step 4：等價驗證

```bash
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read -m mapped.v; read_aiger synth.aig; cec"
```

---

## `&nf -Y` match file 語意回顧

現有 GradMap 消費的格式（見 `third_party/GRADUATE/docs/gradmap_refactor.md`）：

### 記錄類型

| 類型 | 格式 | 範例 |
|------|------|------|
| PI | `<lit> input <area>` | `2 input 0.00` |
| 候選 | `<root_lit> <cell> <area> <n_fanins> <fanins...> <n_cover> <cover...>` | `16 AND2x2... 2 8 10 0` |
| PO | `<po_lit> output <area> <driver_lit>` | `198 output 0.00 140` |
| 已選 | `M<root_lit> <cell> <area> <fanins...>` | `M16 AND2x2... 0.09 8 10` |

### 關鍵語意

- **`root_lit`**：ABC literal（`2*node + phase`），一個候選只服務 **一個** root。
- **`M` 記錄**：ABC mapper 的 warm start；GradMap 預設 `abc_selected_logit_prob` 策略讀取。
- **候選列舉**：`&nf -Y` 對每個 AIG AND 節點的每個相位列舉多個 cell 實作，GradMap 在 per-root softmax 群組內優化。

參考實例：`output/abc_syn_map_20260709_201016/ctrl/ctrl.txt`（1646 行，含候選 + `M` 記錄）。

---

## Multi-Output 的核心問題

### 問題 1：一個 cell、多個 root

以 `FAx1_ASAP7_75t_R` 為例，同一物理 instance 有兩個輸出：

| 輸出 pin | 邏輯角色 | 在 AIG 中 |
|----------|----------|-----------|
| `CON` | carry（反相） | 某 internal node 的 literal `lit_c` |
| `SN` | sum（反相） | 另一 internal node 的 literal `lit_s` |

在 **現有 GradMap** 中，`lit_c` 與 `lit_s` 是 **兩個獨立的 softmax 群組**：

```text
root = lit_c  →  { FAx1@fanins, XOR+AND 分解, ... }   ← 獨立機率
root = lit_s  →  { FAx1@fanins, XOR+AND 分解, ... }   ← 獨立機率
```

這會導致：

1. **不一致選擇**：`lit_c` 選 FAx1，`lit_s` 選 XOR+AND 分解
2. **面積重複計算**：兩個 root 各選一次 FAx1 → area 被算兩次
3. **語意錯誤**：FAx1 是單一 instance，不能獨立為兩個輸出各選一次

這就是你提到的：**同一個 multi-output match selection 會出現在多個 AIG root node 的候選裡**，但它們必須 **綁定在一起選**，不能獨立優化。

### 問題 2：候選如何「出現多次」

對一個 FA binding `B = (FAx1, fanins={A,B,CI})`，在 match file 中應表達為：

```text
# 同一 binding 出現在兩個 root 的候選列表中
lit_c  FAx1_ASAP7_75t_R  0.20412  3  lit_A lit_B lit_CI  0  BIND:42  ROLE:CON
lit_s  FAx1_ASAP7_75t_R  0.20412  3  lit_A lit_B lit_CI  0  BIND:42  ROLE:SN

# 單輸出分解替代（僅出現在各自 root）
lit_c  AND3x1...  ...
lit_c  XOR2x2...  ...
lit_s  XOR2x2...  ...
```

兩條 `FAx1` 候選共享 **`BIND:42`**，GradMap 訓練時對 binding 42 只維護 **一組** 機率權重。

### 問題 3：mockturtle 與 ABC 候選空間不同

| 來源 | 候選生成 | Multi-output |
|------|----------|--------------|
| ABC `&nf -Y` | cut + library match，完整列舉 | 不支援 FA/HA（libcell 限制） |
| mockturtle `emap` | emap cut + GENLIB | 支援 FA/HA binding |

因此務實策略是 **混合**：

- **SO 候選**：沿用 ABC `&nf -Y`（覆蓋率高、與現有 GradMap 相容）
- **MO 候選 + 初始映射**：由 mockturtle `emap` 注入，並標註 `BIND` id

---

## 提議：`nf_y_multi` 擴充格式

在不破壞現有 `nf_y_parser` 的前提下，建議新格式 `nf_y_multi`（或於檔頭宣告版本）。

### 檔頭

```text
# format: nf_y_multi_v1
# source_aig: /path/to/synth.aig
# liberty: asap7.lib
# libcell: asap7_libcell_info_v2_multi_output.txt
# mo_mapper: mockturtle_emap
# so_candidates: abc_nf_y
```

### 候選記錄（擴充欄位，向後相容策略）

**方案 A（推薦）：獨立 binding 表 + 精簡候選行**

候選行維持現有格式，額外在檔尾增加 binding 區塊：

```text
# --- candidates (compatible with nf_y v1) ---
16 AND2x2_ASAP7_75t_R 0.09 2 8 10 0
...

# --- multi-output bindings ---
BIND 42 FAx1_ASAP7_75t_R 0.20412 3 8 10 12 48 50
  ROOTS 48 50
  ROLES CON SN
  FANINS 8 10 12
  COVER 0

MBIND 42 FAx1_ASAP7_75t_R 0.20412 8 10 12
```

欄位說明：

| 記錄 | 語意 |
|------|------|
| `BIND <id> <cell> <area> <n_fanins> <fanins...> <root_lit_1> <root_lit_2> ...` | 定義一個 MO binding |
| `ROOTS` | 此 binding 驅動的所有 ABC root literal |
| `ROLES` | 對應輸出 pin 名稱（CON/SN） |
| `FANINS` | 共用輸入 literal（順序與 Liberty pin 一致） |
| `COVER` | cover 節點數（可為 0，與現有格式一致） |
| `MBIND` | mockturtle/emap 或 ABC 選中的 binding warm start |

**方案 B：候選行重複 + 共享 binding id**

在現有候選行尾加可選欄位：

```text
<root_lit> <cell> <area> <n_leaves> <leaves...> <n_cover> <cover...> <bind_id>
```

- `bind_id = 0`：一般 single-output 候選（與現有相同）
- `bind_id > 0`：屬於某 MO binding；同一 `bind_id` 可出現在多個 `root_lit` 行

GradMap parser 看到相同 `bind_id` 時，不把它們當獨立 softmax 變數，而合併為一個 **binding group**。

### `M` 記錄的擴充

現有：

```text
M<root_lit> <cell> <area> <fanins...>
```

建議新增：

```text
MB<bind_id> <cell> <area> <fanins...>
```

- `M`：single-output warm start（保持不變）
- `MB`：multi-output binding warm start（一個 binding 只寫一次）

### HA 範例

```text
BIND 7 HAxp5_ASAP7_75t_R 0.13122 2 4 6 22 24
  ROOTS 22 24
  ROLES CON SN
  FANINS 4 6
  COVER 0

MBIND 7 HAxp5_ASAP7_75t_R 0.13122 4 6
```

---

## ABC literal 對齊規則

match file 中的 literal **必須與 GradMap 讀取的 AIG 一致**。因此：

### 規則 1：單一 AIG 真相來源

```text
graduate-abc 合成 → write_aiger synth.aig
                              ↓
         所有後續步驟（&nf -Y、emap、gradmap）都讀此檔
```

### 規則 2：literal 編碼

```text
abc_lit = 2 * gia_obj_id + phase
node    = abc_lit >> 1
phase   = abc_lit & 1
```

與 `graduate::map::map_literal_from_abc_lit()` 一致（見 `nf_y_parser.cpp`）。

### 規則 3：mockturtle node → ABC literal 映射表

`mo_match_exporter` 需產生 sidecar 檔 `literal_map.tsv`：

```text
# mockturtle_node  abc_lit  note
42                 96       AND node
43                 98       inverted phase
```

建立方式：

1. 讀取 `synth.aig` 進 ABC 與 mockturtle（lorina）
2. 對每個 mockturtle internal node，用布林函式/simulation 對齊 ABC `gia` node
3. 對 adder 提取後的 `fa`/`ha` 節點，對齊到對應的 sum/carry driver literals

這是 **Phase 2 最關鍵的工程步驟**；沒有對齊表就不能產生正確的 `&nf -Y` 相容檔。

---

## mockturtle → match file 轉換規劃

### 元件：`mo_match_exporter`（待實作）

建議路徑：`src/mo_match_exporter.cpp` 或 `scripts/export_mo_matches.py`（若先用 Python 原型）。

#### 輸入

| 輸入 | 說明 |
|------|------|
| `synth.aig` | ABC 合成後 AIG |
| `so_matches.txt` | 可選；既有 `&nf -Y` 輸出（SO 候選） |
| `emap_result` | mockturtle `cell_view<block_network>` 或 serialized mapping |
| `genlib` / `liberty` | cell 面積、pin 順序 |
| `libcell_info_v2_multi_output` | timing 驗證用 |

#### 輸出

| 輸出 | 說明 |
|------|------|
| `matches.nf_y_multi.txt` | 合併後 match file |
| `literal_map.tsv` | mockturtle ↔ ABC literal |
| `bindings.json` | 結構化 binding 描述（除錯用） |

#### 演算法概要

```text
1. 若提供 so_matches.txt：
     載入 PI / PO / SO 候選 / M 記錄
2. 遍歷 emap 結果中的 multi-output instances：
     對每個 FA/HA instance：
       a. 查 literal_map 得 root_lit_CON, root_lit_SN
       b. 查 fanin literals（A, B, CI）
       c. 分配 bind_id
       d. 寫入 BIND / MBIND 區塊
       e. 在 root_lit_CON、root_lit_SN 各追加一條候選（相同 bind_id）
3. 對未綁定區域，保留 SO 候選
4. 驗證：nf_y_multi parser dry-run
```

#### 候選列舉來源（務實分級）

| 級別 | SO 候選 | MO 候選 | 說明 |
|------|---------|---------|------|
| L1 | ABC `&nf -Y` | emap 已選 mapping  only | 最快；MO 只有 warm start，無替代候選 |
| L2 | ABC `&nf -Y` | emap 已選 + SO 分解替代 | 手動加入 XOR+AND 分解候選 |
| L3 | ABC `&nf -Y` | emap cut 列舉 | 需從 emap 內部提取 cut matches（工作量大） |

**建議先做 L1**，驗證 GradMap binding 訓練路徑；再升級 L2/L3。

---

## GradMap 擴充規劃

### 1. `MapLibrary`：載入 multi-output libcell

- 讀取 `libcell_info_v2_multi_output`（見 `scripts/generate_libcell_info_v2_multi_output.py`）
- 每個 cell 支援多個 output pin 的 timing arc

### 2. `MapMatch` / `MapBinding` 資料結構

```text
現有：MapMatch { root, cell_name, fanins, cover }
新增：MapBinding {
  bind_id,
  cell_name,
  fanins,
  roots: [lit_c, lit_s],
  roles: [CON, SN],
  matches: [match_id_c, match_id_s]  // 指向重複候選
}
```

### 3. 機率模型：從 per-root 到 per-binding

| 層級 | 選擇變數 | softmax 群組 |
|------|----------|--------------|
| 現有 SO | 每個 root literal | 該 root 下所有候選 |
| 新增 MO | 每個 `bind_id` | 該 binding 的替代實作（FAx1 vs 分解） |
| 跨 root 耦合 | 同一 `bind_id` 的兩條候選 | **共享同一權重** |

訓練時：

```text
softmax_group(binding=42) = { FAx1@fanins, XOR2+AND_decomp, ... }
選中 FAx1 → lit_c 與 lit_s 同時生效
area(binding=42) 只計一次 0.20412
```

### 4. `gradmap` 命令擴充

```text
gradmap -match matches.nf_y_multi.txt -match-format nf_y_multi \
        -libcell output/asap7_libcell_info_v2_multi_output.txt \
        -skip-nf-y
```

- `-skip-nf-y`：不重新跑 ABC `&nf -Y`，直接讀取提供之 match file
- 需確保 ABC frame 中已載入與 match file 對應的 `synth.aig`

### 5. warm start

- `M` 記錄 → 現有 per-root warm start（不變）
- `MB` / `MBIND` 記錄 → binding-level warm start（新增）

---

## 實作階段路線圖

```text
Phase 0  [現在可做]  ABC 合成 + mockturtle emap → Verilog + CEC
Phase 1  [1–2 週]    建 mo_techmap CLI；讀 synth.aig + GENLIB → mapped.v + binding JSON
Phase 2  [2–4 週]    literal_map 對齊；mo_match_exporter L1 → nf_y_multi.txt
Phase 3  [4–8 週]    GradMap：libcell MO loader + binding parser + 訓練耦合
Phase 4  [8+ 週]    候選列舉 L2/L3；與 ABC &nf -Y 合併；根目錄 CMake 統一建置
```

### Phase 0 檢查清單

- [ ] `graduate-abc` 已建置
- [ ] mockturtle `emap` experiment 已建置
- [ ] 對 `adder` 跑通 synth.aig → emap → mapped.v
- [ ] `cec` 通過

### Phase 1 檢查清單

- [ ] 根目錄 `CMakeLists.txt` + `src/mo_techmap.cpp`
- [ ] 支援 `--aig`、`--genlib`、`--output`、`--map-multioutput`
- [ ] 輸出 `bindings.json` 列出 FA/HA instances

### Phase 2 檢查清單

- [ ] `literal_map.tsv` 產生器
- [ ] `nf_y_multi_v1` 寫入器
- [ ] 與現有 `ctrl.txt`（SO-only）格式並存驗證

### Phase 3 檢查清單

- [ ] `MapLibrary` 讀取 `libcell_info_v2_multi_output`
- [ ] `nf_y_multi` parser
- [ ] `MapBinding` + 聯合 softmax / 聯合 area 計費
- [ ] `gradmap -skip-nf-y -match <file>`

---

## 驗證策略

### 功能驗證

| 檢查 | 方法 |
|------|------|
| 合成正確 | ABC `ps` 前後 and/level |
| MO mapping 正確 | mockturtle stats `multioutput_gates > 0` on adder |
| 等價性 | `graduate-abc cec` |
| match file 可解析 | GradMap parser dry-run |
| binding 一致性 | 選中 FA 後兩個 root 皆有 driver |

### QoR 驗證

對 `data/epfl/` 的 arithmetic suite：

| 指標 | 比較 |
|------|------|
| Area | SO map（ABC `&nf`）vs MO emap vs GradMap MO |
| Delay | `stime` / mockturtle arrival times |
| FA/HA 用量 | emap stats vs 預期（adder 約 61 個 MO gates） |

### 回歸

- 現有 SO flow 不受影響：`run_abc_syn_map.sh --flow balance` 產物與現有 `ctrl.txt` 格式一致
- GradMap 現有 benchmark 在無 `BIND` 區塊時行為不變

---

## 風險與限制

| 風險 | 影響 | 緩解 |
|------|------|------|
| literal 對齊失敗 | match file 無法被 GradMap 使用 | 先做 adder 等小型 case；產生 `literal_map.tsv` 人工抽查 |
| emap 不列舉完整候選 | GradMap 無 MO 替代可優化 | L1 僅 warm start；L2 手動加入分解候選 |
| ASAP7 僅 2 個 MO cell | 收益限於 FA/HA 結構 | 符合目前研究範圍；見 `ASAP7_MULTI_OUTPUT_CELLS.md` |
| CON/SN 反相邏輯 | 等價但影響 CEC/時序 | 文件中追蹤極性；必要時插入 INV |
| 記憶體 / 平行 | 大 benchmark 多 process emap | 使用 `data/epfl/` scale 分級跑 |

---

## 附錄：檔案與命令速查

### 現有命令

```bash
# SO match + Verilog（balance flow）
./scripts/run_abc_syn_map.sh --flow balance --scale tiny

# 列出 benchmark
./scripts/list_epfl_benchmarks.sh all
```

### 規劃中命令

```bash
# Phase 1：mockturtle multi-output mapping
./build/mo_techmap \
  --aig output/synth/adder.aig \
  --genlib third_party/mockturtle/experiments/cell_libraries/multioutput.genlib \
  --output output/mo_map/adder \
  --map-multioutput

# Phase 2：產生 nf_y_multi
./build/mo_match_exporter \
  --aig output/synth/adder.aig \
  --so-matches output/abc_syn_map_*/adder/adder.txt \
  --emap-bindings output/mo_map/adder/bindings.json \
  --out output/mo_map/adder/matches.nf_y_multi.txt

# Phase 3：GradMap（擴充後）
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read output/synth/adder.aig; st; \
   gradmap -skip-nf-y -match output/mo_map/adder/matches.nf_y_multi.txt \
           -libcell ../output/asap7_libcell_info_v2_multi_output.txt \
           -work output/gradmap/adder"
```

### 相關原始碼

| 檔案 | 用途 |
|------|------|
| `third_party/GRADUATE/src/map/nf_y_parser.cpp` | 現有 match 解析 |
| `third_party/GRADUATE/src/map/warm_start.cpp` | ABC `M` 記錄 warm start |
| `third_party/GRADUATE/src/map/weight_engine.cpp` | per-root softmax 分組 |
| `third_party/mockturtle/include/mockturtle/algorithms/emap.hpp` | multi-output emap |
| `scripts/generate_libcell_info_v2_multi_output.py` | MO libcell 產生 |

---

## 一句話總結

**現在**可以把 `graduate-abc` 與 mockturtle `emap` 用檔案交接跑通 multi-output mapping；**要產生 GradMap 可用的 match file**，需要新增 `mo_match_exporter` 與 `nf_y_multi` 格式，並在 GradMap 中把選擇單位從 per-root 擴充為 **binding-level**，讓同一 FA/HA 出現在多個 root literal 的候選透過共享 `bind_id` 聯合優化，而不是獨立 softmax。
