# GradMap 詳細說明

本文件說明 GRADUATE 框架中的 **GradMap**（梯度引導技術映射）：它做什麼、如何與 ABC `&nf -Y` 銜接、match file 語意、**映射圖資料結構**、**如何張量化到 GPU**、訓練模型、函式庫格式，以及在本專案 multi-output 研究中的限制與擴充方向。

> **相關文件**  
> - [GRADUATE.md](GRADUATE.md) — 建置、`graduate-abc`、GradSyn/GradMap 命令總覽  
> - [ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md) — ABC emap match dump、`nf_y_multi` 擴充規劃  
> - [NF_EMAP_CANDIDATE_ORDER.md](NF_EMAP_CANDIDATE_ORDER.md) — `&nf -Y`／`emap -Y` 候選枚舉與 dump 順序  
> - [GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md) — multi-output libcell 格式  
> - GRADUATE 上游：`third_party/GRADUATE/docs/gradmap_refactor.md`

---

## 目錄

1. [GradMap 是什麼](#gradmap-是什麼)
2. [在 GRADUATE 中的位置](#在-graduate-中的位置)
3. [端到端流程](#端到端流程)
4. [軟體架構](#軟體架構)
5. [ABC `&nf -Y` match file](#abc-nf--y-match-file)
6. [函式庫層：`MapLibrary`](#函式庫層maplibrary)
7. [映射圖：`MapCircuit`](#映射圖mapcircuit)
8. [Graph → GPU：`MapTorchCircuit`](#graph--gpumaptorchcircuit)
9. [機率選擇與訓練](#機率選擇與訓練)
10. [面積與延遲模型](#面積與延遲模型)
11. [Warm start](#warm-start)
12. [網表重建](#網表重建)
13. [命令與選項](#命令與選項)
14. [工作目錄與輸出檔案](#工作目錄與輸出檔案)
15. [與本專案腳本的關係](#與本專案腳本的關係)
16. [Multi-output 限制與擴充](#multi-output-限制與擴充)
17. [原始碼地圖](#原始碼地圖)
18. [常見問題](#常見問題)

---

## GradMap 是什麼

**GradMap** 是 GRADUATE 的 **第二階段：technology mapping（技術映射）**。

與 GradSyn（邏輯合成：在 AIG 上選 rewrite/refactor/resub/balance 等變換）不同，GradMap 在 **已合成的 AIG** 上，從標準元件庫（ASAP7 等）的 **多種閘級實作候選** 中，用 **可微分的機率選擇（probability selection）** 訓練出一組權重，使 **面積（area）與延遲（delay）** 的加權目標（預設 ADP）改善，最後 **硬選擇（hard selection）** 重建 mapped Verilog。

一句話：

```text
AIG + 標準元件候選（&nf -Y）→ softmax 訓練選擇 → mapped Verilog
```

GradMap **不負責** AIG 結構優化（那是 GradSyn / ABC `resyn2` / `&deepsyn` 的事）。它假設輸入 AIG 已固定，只在 **映射候選空間** 內搜尋更好的閘級實作組合。

---

## 在 GRADUATE 中的位置

```text
輸入 AIG
  │
  ├─（可選）GradSyn ──► 優化後 AIG
  │
  ▼
ABC &nf -Y ──► matches.nf_y.txt（候選 + ABC 已選 M 記錄）
  │
  ▼
GradMap
  ├─ NfYParser        解析 match file → MapCircuit
  ├─ MapLibrary       libcell_info 時序/面積
  ├─ MapTorchOptimizer  Adam + temperature 訓練 raw weights
  └─ MapReconstructor   硬選擇 → best.v
  │
  ▼
mapped Verilog（讀回 graduate-abc 或寫檔）
```

與 GradSyn 的 **分工**（見 `gradmap_refactor.md`）：

| 階段 | Provider 範圍 |
|------|----------------|
| **GradSyn** | `rewrite`, `refactor`, `resub`, `balance`（AIG 變換候選） |
| **GradMap** | `source mapping`, `techmap / &nf` 候選（標準元件實作） |

兩者共用 GRADUATE 的機率選擇概念（softmax、required 傳播、accumulated weight、Adam），但 **不共用 provider pool**。

---

## 端到端流程

在 `graduate-abc` shell 中執行 `gradmap` 時，內部步驟如下（`Graduate_CommandGradMap` → `run_gradmap_from_nf_y`）：

```text
1. export_current_aig
      將目前 ABC 網路寫入 <work>/current.aig

2. ABC 命令（自動組裝）：
      read_lib <asap7.lib>;
      [rec_start3 <rec.aig>;]   # 可選
      strash; &get; &nf -Y <work>/matches.nf_y.txt; &put

3. MapLibrary::load_libcell_info(<asap7_libcell_info.txt>)

4. NfYParser::parse_file(matches.nf_y.txt)
      → MapCircuit（節點、候選 match、M 記錄）

5. MapTorchOptimizer::run(circuit, library, train_config)
      → best_raw_weights（訓練後最佳 checkpoint）

6. MapReconstructor::write_verilog(...)
      → <work>/best.v

7. （預設）將 best.v 讀回 ABC；或 -no-readback 保留原 AIG
```

**前置條件**：

- 目前 ABC frame 中已有 **GIA/AIG**（通常先 `read` / `strash` / 合成）
- `third_party/gradmap_libs/asap7.lib` 與 `asap7_libcell_info.txt` 已就緒
- 建置時 **`GRADUATE_ENABLE_TORCH=ON`**（GradMap 依賴 LibTorch）

---

## 軟體架構

```text
graduate-abc (ABC shell)
  └─ Graduate_CommandGradMap          src/abc/abc_commands.cpp
       └─ run_gradmap_from_nf_y       src/abc/abc_actions.cpp
            ├─ MapLibrary            include/graduate/map/library.h
            ├─ NfYParser             include/graduate/map/nf_y_parser.h
            ├─ MapTorchOptimizer     include/graduate/map/torch_optimizer.h
            │    ├─ MapWeightEngine  （CPU 參考：required / timing / area）
            │    └─ MapTorchCircuit  （GPU/CPU 張量訓練）
            └─ MapReconstructor      include/graduate/map/reconstructor.h
```

### 核心資料結構

| 類型 | 檔案 | 角色 |
|------|------|------|
| `Literal` | `graduate/common/circuit.h` | `node + phase`（`inverted`）；張量索引用 ABC lit = `2*node+phase` |
| `MapMatch` | `mapping_graph.h` | 一個 root literal 上的一種 cell 實作候選（圖上的一條「超邊」） |
| `MapSelectedRecord` | `mapping_graph.h` | ABC `M` 行：mapper 已選的 warm start |
| `MapNode` | `mapping_graph.h` | base node（PI/內部）+ 掛在其上的 match id 列表 |
| `MapCircuit` | `mapping_graph.h` | CPU 端完整映射圖（PI/PO/節點 + matches） |
| `MapLibrary` / `MapCell` | `library.h` | 從 libcell_info 載入面積、pin cap、LUT 時序 |
| `MapMatchWeight` | `weight_engine.h` | CPU 參考：每個 match 的 raw / prob / accumulated / delay |
| `MapTorchCircuit` | `torch_circuit.h` | GPU/CPU 張量版圖：flat match 陣列 + level 排程 |
| `MapTorchLibrary` | `torch_library.h` | Liberty LUT 打包成張量，供 GPU 查表 |

### Provider 演進方向

目前 match 來自 **檔案**（`NfYFileProvider` 語意，實作於 `NfYParser`）。長期目標是 **記憶體內** `AbcNfMemoryProvider`（直接從 `Gia_Man` + `Nf_Man` 讀取，無需寫檔）。本專案 Phase 2 規劃的 **ABC emap `-Y`** 也屬於檔案 provider 路徑的擴充。

---

## ABC `&nf -Y` match file

GradMap 預設消費 ABC **`&nf -Y <file>`** 產生的文字檔（工作目錄中為 `matches.nf_y.txt`）。格式定義見 `third_party/GRADUATE/docs/gradmap_refactor.md` 與 `giaNf.c` 的 `Nf_ManDumpMatchesCovers()`。  
候選**如何枚舉／寫出順序**（以及與 `emap -Y` 的差異）見 [NF_EMAP_CANDIDATE_ORDER.md](NF_EMAP_CANDIDATE_ORDER.md)。

### 記錄類型

| 類型 | 格式 | 範例 |
|------|------|------|
| **PI** | `<lit> input <area>` | `2 input 0.00` |
| **候選** | `<root_lit> <cell> <area> <n_fanins> <fanin_lits...> <n_cover> <cover_lits...>` | `16 AND2x2_ASAP7_75t_R 0.09 2 8 10 0` |
| **PO** | `<po_lit> output <area> <driver_lit>` | `198 output 0.00 140` |
| **已選** | `M<root_lit> <cell> <area> <fanin_lits...>` | `M16 AND2x2_ASAP7_75t_R 0.09 8 10` |

### Literal 編碼

```text
abc_lit = 2 * gia_obj_id + phase
base_node = abc_lit >> 1
phase     = abc_lit & 1
```

- `root_lit` 與 `fanin_lits` 都是 **帶相位的 ABC literal**，不是單純 node id。
- 例如 literal `18` 與 `19` 屬於同一 base node 的正/反相位，在 `MapCircuit` 中合併為一個 base node，相位存在 `Literal` 內。
- **Fanin 順序**與 Liberty pin 順序一致（影響 pin capacitance 與 timing arc 索引）。

### 候選行的語意

對每個 AIG **AND 節點**的每個 **相位（正/反）** 作為 root，`&nf -Y` 列舉多種 **cut + cell** 實作：

```text
root_lit  cell_name  cell_area  num_leaves  leaf_lit...  num_cover  cover_lit...
```

- `num_cover = 0` 表示無額外 cover 節點。
- `num_cover > 0` 時，`cover_lit...` 列出 mapping cover 中的內部節點 literal。
- 同一 `root_lit` 下的多行候選形成 GradMap 的 **一個 softmax 群組**。

### `M` 記錄（warm start）

`M<root_lit> <cell> <area> <fanins...>` 表示 ABC `&nf` mapper **已選定** 的實作。GradMap 解析後存入 `MapSelectedRecord`，訓練前用於 **warm start**（見下文）。

### 本專案參考實例

`output/abc_syn_map_20260709_201016/ctrl/ctrl.txt`（由 `run_abc_syn_map.sh --flow balance` 產生，約 1600+ 行）。

產生方式（腳本內部等效）：

```text
read_lib asap7.lib
&get
&if -y -K 6; ... &deepsyn -T 120
&nf -Y ctrl.txt
&put
write_verilog ctrl_balance.v
```

---

## 函式庫層：`MapLibrary`

GradMap **不直接解析 Liberty** 做訓練；它讀取預處理過的 **`libcell_info.txt`**（格式 `libcell_info_v2`）。

### 載入路徑

```text
.lib  ──►  scripts/generate_libcell_info_v2.py  ──►  asap7_libcell_info.txt
                                                          │
                                                          ▼
                                              MapLibrary::load_libcell_info()
```

預設路徑：`third_party/GRADUATE/third_party/gradmap_libs/asap7_libcell_info.txt`（環境變數 `GRADUATE_LIBCELL_INFO` 可覆寫）。

### `MapCell` 內容

每個 cell 包含：

| 欄位 | 用途 |
|------|------|
| `name` | 與 match file 中 `cell_name` 對齊 |
| `area` | 面積計費 |
| `function` | 等價 cell 分組 |
| `input_pins[]` | pin 名稱、rise/fall capacitance |
| `output_pin` | 單一輸出 pin（**v2 格式限制**） |
| `timing_arcs[]` | Liberty LUT：`cell_rise/fall`, `rise/fall_transition` |

預設輔助 cell：`default_inv`、`default_buf`、`wire`（用於相位修復與連線）。

### Parser 驗證

`NfYParser` 對每個候選與 `M` 記錄會：

1. 確認 `cell_name` 存在於 `MapLibrary`
2. 確認 fanin 數量 = cell 的 `input_pins` 數量
3. 確認 cell 有完整 timing LUT
4. 從 library 填入 `cell_area` 與各 pin `capacitance`

**因此**：match file 中出現但 **libcell_info 不含** 的 cell（例如 FA/HA）會在 parse 階段失敗——這是本專案 multi-output 的主要痛點。

---

## 映射圖：`MapCircuit`

`MapCircuit` 是 GradMap 的問題實例，由 `NfYParser` 從 match file 建構。這是 **CPU 端的圖結構**；訓練時再由 `MapTorchCircuit::build()` 壓成張量放到 GPU（見下一節）。

### Graph 結構

GradMap 的映射圖是 **候選覆蓋圖（candidate cover graph）**：每個 **root literal**（AIG 節點 + 相位）掛上多個 match candidate；每個 candidate 是一條「fanin literals → root literal」的超邊，並標註所用 cell。同一 base node 的正/反相位（`n+` / `n!`）各自形成獨立的 softmax 群組。圖上的依賴邊來自 match 的 fanin→root，而非原始 AIG 的 AND 結構邊。

```text
                    ┌─ match0: AND2x2  fanins=[a+, b+]
  root lit r+  ────┼─ match1: NAND2x1 fanins=[a+, b+]   ← 同一 root 的 softmax 群組
                    └─ match2: AOI21   fanins=[...]

  root lit r!  ────┼─ match3: INV     fanins=[r+]       ← 另一個獨立 softmax 群組
                    └─ match4: NOR2   fanins=[...]
```

### 節點種類

| `MapNodeKind` | 來源 |
|---------------|------|
| `kConst` | CONST0/CONST1 |
| `kPi` | `input` 行 |
| `kInternal` | 候選 root 的 base node |

`MapNode` 以 **base node id** 索引（正負相位合併在同一 node），其 `matches` 向量列出掛在該 node 上的 match id（可能含正/反 root）。

### 完整欄位（CPU）

```text
Literal { node, inverted }          // abc_lit = 2*node + (inverted?1:0)

MapPrimaryInput  { raw_lit, literal }
MapPrimaryOutput { raw_lit, driver }  // driver 是驅動此 PO 的 literal

MapMatch {
  id, source_line
  root: Literal                     // 此候選服務的 root literal
  cell_name
  dumped_area                       // match file 寫的 area（參考）
  cell_area                         // 從 MapLibrary 填入（訓練用）
  fanins: Literal[]                 // pin 順序 = Liberty input pin 順序
  pin_capacitances: double[]        // 各 fanin pin cap
  cover: Literal[]                  // mapping cover 內部節點（重建用；GPU 訓練不直接用）
  source: kCandidate | kSelectedSynthetic | kSizing | kDefaultInverter
}

MapSelectedRecord {                 // 來自 M 行
  root, cell_name, fanins, dumped_area
  matching_candidate                // 對回的 MapMatch id（或 -1）
}

MapCircuit {
  nodes_[]                          // MapNode：kind + matches[]
  primary_inputs_[]
  primary_outputs_[]
  matches_[]                        // 全域 match 列表（訓練參數維度 = 此長度）
  selected_records_[]
}
```

`resolve_selected_records()` 將 `M` 記錄對回候選列表；若找不到完全匹配，可合成 `kSelectedSynthetic` match。

### Per-root softmax 群組

`MapWeightEngine`（CPU）與 `MapTorchTimingEngine`（GPU）都依 **`root literal`（ABC lit 索引）** 分組：

```text
matches_by_root_literal[abc_lit] = [ match_id_0, match_id_1, ... ]
```

對每個 root literal 獨立做 softmax → 機率在該群組內歸一。這也是 multi-output 問題的根源（見 [Multi-output 限制](#multi-output-限制與擴充)）：FA 的 CON/SN 若分成兩個 root 群組，會各自選、面積可能雙計。

### 依賴邊如何定義

為了 required 反向傳播與 arrival 正向傳播，依賴圖定義為：

```text
對每個 match m:
  對每個 fanin lit f ∈ m.fanins（且 f ≠ m.root）:
    加一條依賴邊  f → m.root
```

- **正向（timing）**：依 literal 拓樸層級，從 PI 往 PO 算 arrival/slew。
- **反向（required）**：從 PO driver 往 fanin 傳播 required / accumulated weight。

若此依賴圖有環，`MapTorchCircuit::build` 會丟錯（`literal dependency graph has a cycle`）。

---

## Graph → GPU：`MapTorchCircuit`

訓練不在 CPU 上逐 match 迴圈；而是把 `MapCircuit` **張量化** 後，用 LibTorch 在 `cuda` 或 `cpu` device 上做可微 forward。

### 轉換管線

```text
MapCircuit (CPU 物件圖)
    │
    ▼  MapTorchCircuit::build(circuit, library, torch_library, device)
    │
    ├─ 掃描所有 match → 決定 num_matches, max_fanins, num_literals
    ├─ 把每個 MapMatch 寫入 flat 陣列（root / fanins / cell / caps / area）
    ├─ clone 成 torch::Tensor 並 .to(device)
    ├─ raw_weights[num_matches] 設為可學習參數（requires_grad）
    └─ finalize_groups()：建 per-root 分組 + level_match_indices_asc/desc
    │
    ▼
MapTorchTimingEngine::forward(...)
    soft: softmax → required → load → timing → area/delay
    │
    ▼
loss (ADP 等) → backward → Adam 更新 raw_weights
```

原始碼：`include/graduate/map/torch_circuit.h`、`src/map/torch_circuit.cpp`、`src/map/torch_timing.cpp`。

### 張量布局（把圖「攤平」）

GPU 上 **沒有** 顯式 adjacency list；圖資訊全部編進以 **match 為列** 的張量，再用 root/fanin 當索引做聚合。

| 張量 | shape | dtype | 語意 |
|------|-------|-------|------|
| `match_root_lits` | `[M]` | long | match `i` 的 root ABC lit |
| `match_fanin_lits` | `[M, P]` | long | fanin lit；不足 pad `-1` |
| `match_unique_fanin_lits` | `[M, P]` | long | 去重後的 fanin（required 傳播用） |
| `match_cell_ids` | `[M]` | long | 對應 `MapTorchLibrary` 的 cell 索引 |
| `match_pin_caps` | `[M, P]` | float | 各 pin capacitance |
| `match_pin_rise_caps` / `match_pin_fall_caps` | `[M, P]` | float | rise/fall pin cap |
| `match_areas` | `[M]` | float | cell area |
| `po_driver_lits` | `[#PO]` | long | 各 PO 的 driver lit |
| `raw_weights` | `[M]` | float | **可學習參數**（softmax 前的 logit） |
| `level_match_indices_asc` | `vector<Tensor>` | long | 各拓樸層的 match id（正向 timing） |
| `level_match_indices_desc` | `vector<Tensor>` | long | 反向層級（required） |

其中 `M = num_matches`，`P = max_fanins`，`L = num_literals`（`max_abc_lit + 1`）。

對應關係：

```text
CPU:  matches_[i].root / .fanins / .cell_name / .cell_area
GPU:  match_*[i]  （同一 match 索引 i）

CPU:  matches_by_root_literal[lit] = {i0, i1, ...}
GPU:  用 match_root_lits 做 scatter_reduce / index_add，等價於「依 root 分組」
```

### Softmax 如何在 GPU 上「按 root 分組」

不需要顯式 CSR group 指標；用 `match_root_lits` 當索引即可：

```text
logits[i] = raw_weights[i] / temperature

# 每個 root lit 上取 max（數值穩定）
literal_max[lit] = amax over { logits[i] | root(i)=lit }

# 每個 root lit 上求和
literal_sum[lit] = sum  over { exp(logits[i]-max) | root(i)=lit }

prob[i] = exp(logits[i]-max[root(i)]) / (literal_sum[root(i)] + eps)
```

實作：`scatter_reduce_(..., "amax")` + `index_add_`（見 `MapTorchTimingEngine::compute_softmax`）。Hard 模式則改為 per-root one-hot（取最大 logit 的 match）。

### Level 排程：為何需要 `level_match_indices_*`

同一層內的 match 可批次算；跨層有資料依賴：

```text
finalize_groups():
  1. 依 fanin→root 建 literal 依賴圖
  2. Kahn 拓樸排序，得到每個 literal 的 level
  3. 把「以該 lit 為 root 的所有 match」丟進同一 level bucket
  4. asc  = level 0 → max   （arrival 正向）
  5. desc = max → level 0   （required 反向）
```

```text
level_match_indices_asc[k] = 該層所有 match id 的 1D long tensor（已在 device 上）
```

Forward 時對每一層 `index_select` 出該層的 fanin/root/cell，向量化算完再 `index_add_` 回 literal 狀態。

### GPU forward 與 CPU 傳播的對照

| 步驟 | CPU `MapWeightEngine` | GPU `MapTorchTimingEngine` |
|------|----------------------|----------------------------|
| 機率 | 逐 root 群組 softmax | `scatter`/`index_add` 全域 softmax |
| Required | 反向拓樸逐 lit | `level_match_indices_desc` 逐層 |
| Accumulated weight | `req(root) * prob(match)` | 同左，張量版 |
| Load | AW × pin cap 加到 fanin | `index_add_` 到 `literal_load` |
| Timing | 正向拓樸 + LUT 查表 | `level_match_indices_asc` + `MapTorchLibrary` LUT 張量 |
| Area | `Σ AW × cell_area` | `sum(match_accumulated * match_areas)` |
| Delay | PO arrival 聚合 | `po_driver_lits` 上 `max` / `sum` |

`MapTorchLibrary` 另把各 cell 的 Liberty LUT、timing sense 等打包成大張量，依 `match_cell_ids` 批次查 delay/slew（含 rise/fall、unate/non-unate）。

結構對應：

```text
Graph：
  節點 = ABC literal（含相位）
  超邊 = MapMatch（fanins → root，標註 cell）
  決策 = 每個 root literal 的 softmax 選一條超邊

GPU：
  超邊列表 → 長度 M 的 flat tensors
  分組 / 傳播 → 用 root/fanin 索引做 scatter/gather + level 批次
  可微參數 → raw_weights[M]
```

---

## 機率選擇與訓練

### 訓練配置（`MapTorchTrainConfig`）

| 參數 | 預設 | 說明 |
|------|------|------|
| `steps` | 150 | 訓練步數 |
| `eval_interval` | 10 | 每隔 N 步評估 hard cost |
| `learning_rate` | 0.05 | Adam 學習率 |
| `temperature_start` / `end` | 1.2 / 0.7 | softmax 溫度退火 |
| `loss_type` | `ADP` | 目標函數（area-delay product 類） |
| `gradient_clip` | 0.3 | 梯度裁剪 |
| `device` | `auto` | `cuda` / `cpu` |

`gradmap -fast` 使用 `steps=1, eval=1, device=cpu`，僅驗證路徑。

### 訓練迴圈（概念）

```text
MapTorchCircuit::build(...)          # 圖 → 張量（一次）

for step in 1..steps:
  temperature = interpolate(temp_start, temp_end, step)

  soft path (GPU):
    MapTorchTimingEngine::forward(soft, temperature)
      → match_probs, required, AW, load, arrival, area, delay

  loss = ADP(soft_area, soft_delay)   # 可微

  backward + Adam update(raw_weights)

  if step % eval_interval == 0:
    hard select → reconstruct → eval hard area/delay
    keep best checkpoint
```

CPU `MapWeightEngine` 仍可作參考／除錯；正式訓練路徑走 `MapTorchCircuit`。

### CPU 參考傳播順序（`MapWeightEngine`）

```text
raw weights
  → softmax probability per root literal
  → literal required（從 PO 反向）
  → match accumulated weight (AW)
  → literal load（AW 加權 pin cap）
  → literal arrival/slew（Liberty LUT 查表）
  → total area = Σ (AW × cell_area)
  → PO delay sum
```

**注意**：timing 與 required 在 **literal 粒度** 運算（非僅 base node），因為 inverter cell 可在同一 base node 內實現 `n+ → n!`。

---

## 面積與延遲模型

### 面積

```text
area = Σ_match  (accumulated_weight(match) × cell_area(match))
```

標準元件 instance **不像 AIG 內部節點那樣結構共享**；共享透過 fanin 節點的 required/AW 體現。

### 延遲

對每個 match，在 fanin pin 上：

```text
arrival_at_root = max_pin ( arrival(fanin_pin) + arc_delay(cell, pin, load) )
```

PO 延遲為各輸出 driver 的 arrival 之和（或依 loss 定義加權）。第一版 **不含** placement / wire delay。

---

## Warm start

ABC `&nf` 已選的 `M` 記錄用於初始化訓練權重，避免從均勻分布冷啟動。

### 策略（`MapWarmStartStrategy`）

| 策略 | 行為 |
|------|------|
| `kZero` | 均勻起點 |
| `kAbcSelected` | 硬選 ABC 候選 |
| `kAbcSelectedLogitProbability` | **預設**；對已選候選給高 softmax 機率 |

預設參數（`run_gradmap_from_nf_y`）：

```text
warm_start_selected_probability = 0.80
warm_start_selected_boost       = 2.0
```

流程：

```text
ensure_selected_candidates()   // M 記錄對回候選，必要時合成
make_map_initial_raw_weights() // 依策略設初始 logit
evaluate_map_warm_start()      // 統計 matched / mismatched / hard_mismatches
```

`gradmap -details` 會印出 warm-start 統計（`warm_selected_records`、`warm_hard_mismatches` 等）。

---

## 網表重建

`MapReconstructor::write_verilog()` 在訓練結束後，用 **best checkpoint 的 raw weights** 做 **hard selection**（每個 root literal 選機率最高且滿足 required 的 match），遞迴展開 fanin，必要時插入 **inverter**（當所需相位與候選提供相位不符）。

輸出：gate-level Verilog（`best.v`），模組名預設取自輸入 AIG 檔名。

---

## 命令與選項

在 `graduate-abc` 中：

```text
abc> gradmap [options]
```

### 常用選項

| 選項 | 預設 | 說明 |
|------|------|------|
| `-work <dir>` | `exp_output/abc_gradmap` | 工作目錄 |
| `-o <verilog>` | `<work>/best.v` | 輸出 Verilog |
| `-lib <path>` | `asap7.lib` | ABC `read_lib`（`&nf` 用） |
| `-libcell <path>` | `asap7_libcell_info.txt` | GradMap 時序庫 |
| `-rec <aig>` | — | 可選 `rec_start3` 錄製庫 |
| `-steps <n>` | 150 | 訓練步數 |
| `-eval <n>` | 10 | 評估間隔 |
| `-lr <x>` | 0.05 | 學習率 |
| `-device <name>` | `auto` | `cuda` / `cpu` |
| `-loss <name>` | `ADP` | 損失類型 |
| `-fast` | — | demo：`steps=1, eval=1, cpu` |
| `-no-readback` | — | 不將 `best.v` 讀回 ABC |
| `-details` | — | 顯示 match / warm-start 統計 |

### 環境變數

| 變數 | 說明 |
|------|------|
| `GRADUATE_LIBERTY` | 覆寫 `-lib` 預設 |
| `GRADUATE_LIBCELL_INFO` | 覆寫 `-libcell` 預設 |
| `GRADUATE_REC_LIB` | 覆寫 `-rec` 預設 |
| `TORCH_CMAKE_PREFIX_PATH` | LibTorch（建置用） |

### 範例

```bash
cd third_party/GRADUATE

# Smoke test
./build_abc_frontend/graduate-abc -c \
  "read testdata/smoke.aig; st; resyn2; gradsyn -fast; gradmap -fast; topo; stime; ps"

# 完整映射
./build_abc_frontend/graduate-abc -c \
  "read design.aig; st; resyn2; gradmap -steps 150 -device cuda -work exp_output/map1"

# 自訂庫
./build_abc_frontend/graduate-abc -c \
  "read design.aig; st; gradmap -lib /path/custom.lib -libcell /path/custom_libcell.txt"
```

### 規劃中選項（尚未實作）

見 [ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md)：

```text
gradmap -match matches.nf_y_multi.txt -match-format nf_y_multi \
        -libcell asap7_libcell_info_v2_multi_output.txt \
        -skip-nf-y
```

- `-skip-nf-y`：跳過內建 `&nf -Y`，直接讀外部 match file（例如 ABC `emap -Y` 產物）
- `-match-format nf_y_multi`：支援 `BIND` / `MBIND` binding

---

## 工作目錄與輸出檔案

`gradmap -work <dir>` 產生：

| 檔案 | 說明 |
|------|------|
| `current.aig` | 執行前 ABC 網路快照 |
| `matches.nf_y.txt` | `&nf -Y` 完整 match dump |
| `best.v` | 訓練後 mapped Verilog |

時序流程 `seq_flow` 會在 `<out>/gradmap/` 下建立類似結構，最終 wrapper 為 `reinserted.v`。

---

## 與本專案腳本的關係

### `run_abc_syn_map.sh --flow balance`

產生 **與 GradMap 相同格式** 的 match file + Verilog，但 **不執行 GradMap 訓練**：

```text
scripts/abc/abc_syn_map_balance.abc
  → &nf -Y <case>.txt
  → write_verilog <case>_balance.v
```

用途：

- 取得 `&nf -Y` match dump 供分析或餵給未來 GradMap
- 與 ABC mapper 的 baseline QoR 比較

### `run_abc_emap_map.sh` / fair compare

ABC `emap -Y` → `nf_y_multi.txt` →（未來）GradMap binding 訓練。見 [`ABC_MOCKTURTLE_MULTI_OUTPUT.md`](ABC_MOCKTURTLE_MULTI_OUTPUT.md)。

### 資料流對照

```text
                    GradMap 可消費？
run_abc_syn_map balance     matches.nf_y 格式    ✅（SO only，現有 parser）
ABC emap -Y（正式）         nf_y_multi          ⏳（需 parser 擴充）
```

---

## Multi-output 限制與擴充

### 現狀限制

| 項目 | 現狀 |
|------|------|
| `asap7_libcell_info.txt` | **僅 single-output** cell；FA/HA 被 `generate_libcell_info_v2.py` 跳過 |
| `MapCell` | 單一 `output_pin` |
| `NfYParser` | 每候選一個 `root`；**無 binding 語意** |
| `MapWeightEngine` | **per-root literal softmax** |
| `&nf -Y` | 不產生 MO binding；即使 Liberty 有 FA/HA，libcell 缺則 GradMap 失敗 |

### 為何 FA/HA 需要 binding

同一 `FAx1` 驅動兩個 root（CON、SN）。若分兩個 softmax 群組：

- 可能各選不同實作 → 語意錯誤
- 可能各選一次 FAx1 → **面積算兩次**

### 本專案擴充方向

1. **`libcell_info_v2_multi_output`** — `scripts/py/generate_libcell_info_v2_multi_output.py`（已存在）
2. **`nf_y_multi` match format** — `BIND` / `MBIND`（見 [ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md)）
3. **ABC `emap -Y`** — 利用 `TwinObj` 產生雙 root binding 候選
4. **GradMap `MapBinding`** — binding-level softmax + 聯合 area 計費

```text
現有：softmax_group(root = lit_c) 與 softmax_group(root = lit_s)  獨立
目標：softmax_group(binding = 42) = { FAx1@fanins, XOR+AND_decomp, ... }
      選中 FAx1 → lit_c 與 lit_s 同時生效
```

---

## 原始碼地圖

| 路徑 | 說明 |
|------|------|
| `src/abc/abc_commands.cpp` | `Graduate_CommandGradMap`、選項解析、`&nf -Y` 命令組裝 |
| `src/abc/abc_actions.cpp` | `run_gradmap_from_nf_y` 主流程 |
| `src/map/nf_y_parser.cpp` | match file 解析 |
| `src/map/warm_start.cpp` | M 記錄 warm start |
| `src/map/weight_engine.cpp` | CPU 參考 weight/timing |
| `src/map/torch_circuit.cpp` | `MapCircuit` → GPU 張量（`MapTorchCircuit::build`） |
| `src/map/torch_timing.cpp` | GPU softmax / required / load / timing forward |
| `src/map/torch_library.cpp` | Liberty LUT 張量化與批次查表 |
| `src/map/torch_optimizer.cpp` | LibTorch 訓練迴圈 |
| `src/map/reconstructor.cpp` | Verilog 重建 |
| `src/map/library.cpp` | libcell_info 載入 |
| `include/graduate/map/mapping_graph.h` | `MapCircuit` / `MapMatch` |
| `include/graduate/map/torch_circuit.h` | `MapTorchCircuit` 張量欄位 |
| `include/graduate/map/torch_timing.h` | `MapTorchTimingEngine` |
| `third_party/abc/.../gia/giaNf.c` | `&nf -Y` dump 實作（GRADUATE bundled ABC） |
| `third_party/abc/src/map/emap/` | ABC emap（repo root，**規劃併入 + `-Y`**） |

---

## 常見問題

### `gradmap requires GRADUATE_ENABLE_TORCH=ON`

建置時未啟用 LibTorch。設定 `TORCH_CMAKE_PREFIX_PATH` 後重新跑 `scripts/build_abc_frontend.sh`。

### `ABC &nf -Y produced no match file`

- bundled ABC 缺少 `&nf -Y` patch（需用 GRADUATE 內建 ABC，勿換上游 vanilla ABC）
- 未 `read_lib` 或目前無 GIA（需 `strash; &get`）

### `unknown cell: FAx1_...`

match 中有 FA/HA，但 `asap7_libcell_info.txt` 不含該 cell。需改用 multi-output libcell 並擴充 parser（尚未完成）。

### `GradMap parse failed: ... fanins`

候選 fanin 數與 libcell 定義的 input pin 數不一致；常為 match 與 libcell 版本不匹配。

### warm start `hard_mismatches > 0`

ABC `M` 記錄的 cell/fanin 組合在候選列表中找不到完全匹配；parser 可能已合成 synthetic match，訓練仍可进行但起點偏差較大。

### `gradmap` 與直接 `&nf` + `write_verilog` 的差別

| | ABC `&nf` | GradMap |
|---|-----------|---------|
| 選擇方式 | ABC mapper 啟發式一次決策 | 多候選 + 梯度訓練優化 ADP |
| 輸入 | 單一 mapping 結果 | 完整候選空間（`-Y` 檔） |
| 適用 | 快速 baseline | 研究 / QoR 探索 |

### 如何只產 match file、不訓練

使用本專案腳本：

```bash
./Nonescripts/sh/run_abc_syn_map.sh --flow balance --cases ctrl
# 產物：output/.../ctrl/ctrl.txt
```

或在 ABC 中手動：

```text
read_lib asap7.lib; &get; &nf -Y matches.txt; &put
```

---

## 一句話總結

**GradMap** 讀取 ABC **`&nf -Y` match file**，建成以 **root literal → 多個 match candidate（超邊）** 為核心的映射圖；再經 **`MapTorchCircuit`** 攤成張量，在 GPU/CPU 上做 **per-root softmax 訓練** 優化面積與延遲，輸出 **mapped Verilog**。本專案的 multi-output 工作需擴充為 **binding-level 選擇** 與 **`nf_y_multi` / ABC `emap -Y`**，方能正確處理 FA/HA。

---

## 維護說明

修改 GradMap 行為、match 格式、或本專案與 GradMap 的整合時，請同步更新：

- 本文件（`docs/GRADMAP.md`）
- [ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md)（若影響 match / binding）
- [GRADUATE.md](GRADUATE.md)（若變更命令列或建置）
- [SCRIPTS.md](SCRIPTS.md)（若變更產 match 的腳本）
