# mockturtle 使用指南

本文件說明如何在 `multi_output_standard_cell` 專案中使用位於 `third_party/mockturtle` 的 mockturtle 函式庫。mockturtle 是 EPFL 開發的 **C++17 header-only 邏輯合成函式庫**，提供多種邏輯網路表示（AIG、MIG、XAG、k-LUT 等）與通用合成/最佳化演算法。

對本專案而言，mockturtle 最重要的價值在於 **`emap`（Extended Mapper）**：它原生支援 **multi-output standard cell** 的技術映射（technology mapping），可將 FA、HA 等雙輸出標準元件作為單一節點映射，彌補傳統 ABC `map` / `if` 流程主要面向 single-output cell 的限制。

> **專案位置**：`third_party/mockturtle` 為指向 `~/tools/mockturtle` 的符號連結。以下路徑均以 mockturtle 根目錄為基準；在 `multi_output_standard_cell` 中請使用 `third_party/mockturtle`。

---

## 目錄

1. [整體架構](#整體架構)
2. [與 ABC / GRADUATE 的關係](#與-abc--graduate-的關係)
3. [環境需求](#環境需求)
4. [安裝與建置](#安裝與建置)
5. [快速驗證](#快速驗證)
6. [典型工作流程（Multi-Output Tech Mapping）](#典型工作流程multi-output-tech-mapping)
7. [可用功能總覽](#可用功能總覽)
8. [Multi-Output 技術映射詳解](#multi-output-技術映射詳解)
9. [整合到本專案](#整合到本專案)
10. [常見問題](#常見問題)
11. [參考文件](#參考文件)

---

## 整體架構

mockturtle 採用四層設計（詳見官方 `docs/philosophy.rst`）：

```text
網路介面（network interface）
  │
  ▼
通用演算法（algorithms，template 實作）
  │
  ▼
網路實作（AIG / MIG / XAG / k-LUT / block 等）
  │
  ▼
View 包裝（cell_view / binding_view / mapping_view 等）
```

**技術映射相關的核心元件**：

```text
輸入 AIG（或其他 subject graph）
  │
  ▼
前處理（可選：aig_balance / rewrite / refactor 等）
  │
  ▼
讀取 GENLIB / SUPER 函式庫
  → tech_library<N>（Boolean matching hash table）
  → get_standard_cells()（將同名多輸出 gate 分組）
  │
  ▼
emap / map（技術映射）
  │
  ├─ emap + map_multioutput=true
  │    → cell_view<block_network>（保留 multi-output 節點）
  │
  └─ emap_klut / map
       → binding_view<klut_network>（單輸出 k-LUT 表示）
  │
  ▼
輸出（write_verilog_with_cell / write_verilog 等）
```

**主要目錄結構**：

```text
third_party/mockturtle/
├── include/mockturtle/
│   ├── algorithms/          # 合成與映射演算法（emap.hpp, mapper.hpp 等）
│   ├── networks/            # 網路型別（aig.hpp, block.hpp, klut.hpp 等）
│   ├── utils/               # tech_library.hpp, standard_cell.hpp 等
│   ├── views/               # cell_view.hpp, binding_view.hpp 等
│   └── io/                  # GENLIB / AIGER / Verilog 讀寫
├── lib/                     # 內建依賴（kitty, lorina, percy, bill, abcsat 等）
├── examples/                # 小型範例程式
├── experiments/             # 演算法 benchmark 驅動程式
│   └── cell_libraries/      # 測試用 GENLIB（含 multioutput.genlib）
├── test/                    # Catch2 單元測試
└── docs/                    # Sphinx 官方文件
```

---

## 與 ABC / GRADUATE 的關係

| 面向 | mockturtle | ABC | GRADUATE（本專案 third_party/GRADUATE） |
|------|-----------|-----|----------------------------------------|
| 性質 | C++ **函式庫**（header-only） | C **命令列工具** + 腳本 shell | ABC 前端 + 梯度合成/映射 |
| 技術映射 | `emap`（multi-output）、`map` | `map`、`if`、`&nf` 等 | `gradmap`（透過 ABC `&nf -Y`） |
| Multi-output cell | **原生支援**：`block_network` + `cell_view` + `map_multioutput` | 傳統 `map` 以 single-output 為主；`&nf` 匹配語意不同 | 目前 GradMap 消費 `&nf -Y` 匹配，**非 multi-output 優先** |
| 使用方式 | 在 C++ 專案中 `#include` 並呼叫 API | `abc -c "read; map; ..."` | `graduate-abc` shell 中 `gradsyn` / `gradmap` |
| 等價檢查 | 內建 simulation / miter；實驗常呼叫外部 `abc` CEC | 內建 `cec` / `dsec` | 透過 ABC |

**本專案的定位建議**：

- **GRADUATE**：梯度引導的邏輯合成 + 基於 ABC 的技術映射管線（見 [`docs/GRADUATE.md`](GRADUATE.md)）。
- **mockturtle**：作為 **multi-output standard cell technology mapping 的參考實作與開發基礎**，`emap` 演算法可直接嵌入自訂 C++ 工具，或作為驗證 GRADUATE / ABC 管線的對照基準。

mockturtle 許多演算法由 Alan Mischenko（ABC 主要貢獻者）參與設計，與 ABC 在演算法層面高度相關，但 **不是 ABC 的替代品**，而是可組合的程式庫。

---

## 環境需求

| 項目 | 版本 / 說明 |
|------|-------------|
| CMake | ≥ 3.8 |
| C++ 編譯器 | 支援 C++17（官方測試 Clang 12+、GCC 9/10） |
| Git | 建置時用於版本資訊（可選） |
| ABC（可選） | 執行 experiments 時用於 CEC；不影響演算法本身 |

mockturtle 為 **header-only**，無需額外安裝系統套件；所有依賴已隨 `lib/` 目錄內建。

---

## 安裝與建置

所有命令請在 mockturtle 根目錄執行：

```bash
cd ~/research/multi_output_standard_cell/third_party/mockturtle
```

### 基本建置（Examples）

```bash
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j$(nproc)
```

預設會建置 `examples/` 下的程式，例如 `cut_enumeration`、`draw`、`minimize` 等。

### 建置 Experiments（含 emap benchmark）

```bash
cmake -DCMAKE_BUILD_TYPE=Release -DMOCKTURTLE_BUILD_EXPERIMENTS=ON ..
make -j$(nproc) emap mapper lut_mapper
```

### 建置單元測試

```bash
cmake -DCMAKE_BUILD_TYPE=Release -DMOCKTURTLE_BUILD_TESTS=ON ..
make -j$(nproc) run_tests
```

### CMake 選項摘要

| 選項 | 預設 | 說明 |
|------|------|------|
| `MOCKTURTLE_BUILD_EXAMPLES` | ON | 建置 examples |
| `MOCKTURTLE_BUILD_TESTS` | OFF | 建置 Catch2 測試 |
| `MOCKTURTLE_BUILD_EXPERIMENTS` | OFF | 建置 experiments（emap、mapper 等） |
| `MOCKTURTLE_ENABLE_ABC` | OFF | 連結完整 ABC static lib（需額外下載 `libabc.a`） |
| `MOCKTURTLE_ENABLE_NAUTY` | OFF | percy 精確合成用 Nauty |
| `BILL_Z3` | OFF | bill SAT 介面啟用 Z3 |

---

## 快速驗證

### 1. 執行範例程式

```bash
cd build
./examples/cut_enumeration
# 預設讀取 ../experiments/benchmarks/adder.aig 並列印 cuts
```

### 2. 執行 emap 單元測試（multi-output 相關）

```bash
cd build
./test/run_tests "[emap]"
# 預期：All tests passed (23 test cases)
```

其他相關測試標籤：

```bash
./test/run_tests "[tech_library]"        # 函式庫解析與 multi-output 分組
./test/run_tests "[decompose_multioutput]"  # multi-output 分解實驗功能
./test/run_tests "[mapper]"              # 傳統 map 映射
```

### 3. 執行 emap benchmark（EPFL benchmarks + multioutput.genlib）

```bash
cd build
./experiments/emap
```

此程式會：

1. 載入 `experiments/cell_libraries/multioutput.genlib`（ASAP7 風格，含 FA/HA 等 50 個 gate）
2. 對 EPFL combinational benchmarks 執行 `emap`，`map_multioutput = true`
3. 輸出 area、delay、multioutput gate 數量等統計表

輸出範例欄位：`benchmark | size | area_after | depth | delay_after | multioutput | runtime | cec`

> **注意**：`cec` 欄位需系統 PATH 中有 `abc` 命令；若未安裝 ABC，演算法仍正常執行，但 CEC 結果為 `false`。

---

## 典型工作流程（Multi-Output Tech Mapping）

以下為 mockturtle 官方 `experiments/emap.cpp` 精簡後的標準流程，可直接作為本專案實作的起點：

```cpp
#include <fstream>
#include <vector>

#include <lorina/aiger.hpp>
#include <lorina/genlib.hpp>
#include <mockturtle/algorithms/aig_balancing.hpp>
#include <mockturtle/algorithms/emap.hpp>
#include <mockturtle/io/aiger_reader.hpp>
#include <mockturtle/io/genlib_reader.hpp>
#include <mockturtle/io/write_verilog.hpp>
#include <mockturtle/networks/aig.hpp>
#include <mockturtle/networks/block.hpp>
#include <mockturtle/utils/tech_library.hpp>
#include <mockturtle/views/cell_view.hpp>
#include <mockturtle/views/depth_view.hpp>

using namespace mockturtle;

int main()
{
  // 1. 讀取 AIG
  aig_network aig;
  lorina::read_aiger( "design.aig", aiger_reader( aig ) );

  // 2. 前處理（可選）
  aig_balancing_params bps;
  bps.fast_mode = true;
  aig_balance( aig, bps );

  // 3. 讀取 GENLIB 函式庫
  std::vector<gate> gates;
  std::ifstream in( "multioutput.genlib" );
  lorina::read_genlib( in, genlib_reader( gates ) );

  tech_library_params tps;
  tps.load_multioutput_gates = true;   // 預設即為 true
  tech_library<9> tech_lib( gates, tps );

  // 4. 執行 emap（multi-output 映射）
  emap_params ps;
  ps.matching_mode = emap_params::hybrid;
  ps.area_oriented_mapping = false;  // false = delay-oriented
  ps.map_multioutput = true;         // 啟用 multi-output cell 映射
  emap_stats st;

  cell_view<block_network> mapped = emap<9>( aig, tech_lib, ps, &st );

  // 5. 輸出統計
  // st.multioutput_gates：使用了多少個 multi-output 標準元件
  // mapped.compute_area() / mapped.compute_worst_delay()

  // 6. 寫出 Verilog（需 names_view 包裝以保留訊號名）
  // write_verilog_with_cell( mapped, "mapped.v" );

  return 0;
}
```

**命令列等效流程（使用 experiments）**：

```bash
# 建置並執行完整 benchmark sweep
cd third_party/mockturtle/build
cmake -DCMAKE_BUILD_TYPE=Release -DMOCKTURTLE_BUILD_EXPERIMENTS=ON ..
make emap
./experiments/emap
```

---

## 可用功能總覽

### 邏輯網路（Networks）

| 網路型別 | 標頭檔 | 說明 |
|---------|--------|------|
| `aig_network` | `networks/aig.hpp` | And-Inverter Graph，技術映射最常用的 subject graph |
| `mig_network` | `networks/mig.hpp` | Majority-Inverter Graph |
| `xag_network` / `xmg_network` | `networks/xag.hpp` / `xmg.hpp` | XOR-based 網路 |
| `klut_network` | `networks/klut.hpp` | k-LUT 網路，映射結果的常見表示 |
| **`block_network`** | `networks/block.hpp` | **支援 multi-output 節點的網路**，`emap` 原生輸出格式 |
| `sequential_network` | `networks/sequential.hpp` | 時序邏輯支援 |

### 技術映射演算法

| 演算法 | 標頭檔 | 說明 |
|--------|--------|------|
| **`emap`** | `algorithms/emap.hpp` | Extended mapper；支援 >6 inputs、multi-output cell、hybrid matching |
| `map` | `algorithms/mapper.hpp` | 傳統技術映射（類 ABC `map`）；single-output 為主 |
| `lut_map` | `algorithms/lut_mapper.hpp` | FPGA LUT 映射（delay + area） |
| `lut_mapping` | `algorithms/lut_mapping.hpp` | 面積導向 LUT 映射 |
| `satlut_mapping` | `algorithms/satlut_mapping.hpp` | SAT 最佳化 LUT 映射 |
| `seq_map` | `algorithms/mapper.hpp` | 時序電路技術映射 |

### 合成與最佳化（映射前常用）

| 演算法 | 說明 |
|--------|------|
| `rewrite` / `refactoring` | 結構重寫 |
| `resubstitution` | 節點替換 |
| `balancing` / `aig_balance` | 邏輯深度平衡 |
| `cut_rewriting` | 基於 cut 的重寫 |
| `extract_adders` | 萃取半加器/全加器結構（有利於 FA/HA 映射） |
| `equivalence_checking` | 等價檢查 |
| `decompose_multioutput`（experimental） | 將 multi-output 節點分解為 single-output 網路 |

### I/O 支援

| 格式 | 讀取 | 寫入 |
|------|------|------|
| AIGER | `lorina/aiger.hpp` + `aiger_reader` | `write_aiger` |
| GENLIB | `lorina/genlib.hpp` + `genlib_reader` | `write_genlib` |
| SUPER | `lorina/super.hpp` + `super_reader` | — |
| Verilog | `lorina/verilog.hpp` | `write_verilog` / `write_verilog_with_cell` |
| BLIF | `lorina/blif.hpp` | `write_blif` |

### Experiments 可執行檔（`MOCKTURTLE_BUILD_EXPERIMENTS=ON`）

| 程式 | 用途 |
|------|------|
| **`emap`** | Multi-output 技術映射 benchmark |
| `mapper` | 傳統 `map` vs graph mapping 比較 |
| `lut_mapper` / `lut_mapping` / `satlut` | LUT 映射實驗 |
| `extract_adders` | 加法器結構萃取 |
| `rewrite` / `refactoring` / `balancing` | 各種最佳化實驗 |
| `equivalence_checking` | 等價檢查 benchmark |
| `aig_resubstitution` / `mig_resubstitution` / `xag_resubstitution` | Resubstitution 實驗 |

### 內建測試用 Cell Library

路徑：`experiments/cell_libraries/`

| 檔案 | 說明 |
|------|------|
| **`multioutput.genlib`** | ASAP7 風格，50 gates，含 `FAx1`（CON/SN）、`HAxp5` 等 multi-output cell |
| `mcnc.genlib` | 經典 MCNC 函式庫 |
| `asap7.genlib` | ASAP7 single-output 版本 |
| `sky130.genlib` | Sky130 函式庫 |

**Multi-output GENLIB 格式範例**（同名 GATE 定義多個輸出）：

```text
GATE FAx1_ASAP7_75t_R  0.24  CON=(!A * !B) + (!A * !CI) + (!B * !CI);
GATE FAx1_ASAP7_75t_R  0.24  SN=(A * B * !CI) + (A * !B * CI) + (!A * B * CI) + (!A * !B * !CI);
```

`get_standard_cells()` 會將同名條目合併為一個 `standard_cell`，其 `gates` 向量包含各輸出 pin 的邏輯函式。

---

## Multi-Output 技術映射詳解

### 核心 API

#### `emap_params` 重要參數

| 參數 | 預設 | 說明 |
|------|------|------|
| **`map_multioutput`** | `false` | **設為 `true` 啟用 multi-output cell 映射** |
| `area_oriented_mapping` | `false` | `false` = delay-oriented；`true` = area-oriented |
| `matching_mode` | `hybrid` | `boolean`（≤6 inputs）、`structural`（DSD pattern）、`hybrid` |
| `relax_required` | `0` | Required time 放寬百分比（如 `10` = 10%） |
| `area_flow_rounds` | `3` | Area flow 最佳化輪數 |
| `ela_rounds` | `2` | Exact area 最佳化輪數 |
| `remove_overlapping_multicuts` | `false` | 移除重疊的 multi-output cut |
| `verbose` | `false` | 輸出詳細日誌 |

#### `tech_library_params` 重要參數

| 參數 | 預設 | 說明 |
|------|------|------|
| **`load_multioutput_gates`** | `true` | 載入 multi-output gate 至函式庫 |
| `load_multioutput_gates_single` | `false` | 將 multi-output gate 以 single-output 形式也加入函式庫 |
| `ignore_symmetries` | `false` | 設 `true` 可大幅加速映射（延遲略增） |

#### 輸出格式選擇

| 函式 | 回傳型別 | 適用場景 |
|------|---------|---------|
| `emap<N>()` | `cell_view<block_network>` | **保留 multi-output 節點**；適合輸出含 FA/HA 的閘級網表 |
| `emap_klut()` | `binding_view<klut_network>` | 以 single-output k-LUT 表示；與 `map` 輸出格式相容 |
| `emap_node_map()` | `binding_view<klut_network>` | 節點級映射變體 |

#### `emap_stats` 統計

- `area` / `delay`：映射後面積與延遲
- **`multioutput_gates`**：使用的 multi-output 標準元件數量
- `time_total`：執行時間

### 演算法行為摘要

1. **Cut enumeration**：對每個節點枚舉 fanin cut（預設 cut limit = 16，最大 19）。
2. **Boolean / Pattern matching**：透過 `tech_library` hash table 比對 cut 的 truth table 與函式庫 gate。
3. **Multi-output matching**（`map_multioutput=true`）：額外枚舉可同時覆蓋多個相關輸出的 cut 組合，嘗試映射為 FA、HA 等雙輸出 cell。
4. **Delay / Area optimization**：多輪 area flow 與 exact area 最佳化。
5. **網路建構**：將映射結果實例化為 `block_network`（multi-output）或 `klut_network`（single-output）。

### 驗證案例：8-bit Ripple-Carry Adder

`test/algorithms/emap.cpp` 中的測試案例：

- 輸入：8-bit RCA AIG（16 PI + 1 carry out）
- 函式庫：含 `ha`、`fa` multi-output gate 的 test GENLIB
- 參數：`map_multioutput=true`，`area_oriented_mapping=true`
- 預期：`st.multioutput_gates == 8`（8 個 full-adder 被映射為 multi-output cell）

---

## 整合到本專案

目前 `multi_output_standard_cell` 根目錄尚無 CMake 或應用程式碼，僅有 `third_party/` 依賴與 `docs/`。建議整合步驟：

### 1. 建立根目錄 CMakeLists.txt

```cmake
cmake_minimum_required(VERSION 3.16)
project(multi_output_standard_cell LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_subdirectory(third_party/mockturtle)

add_executable(mo_techmap src/mo_techmap.cpp)
target_link_libraries(mo_techmap PRIVATE mockturtle)
```

### 2. 實作 `src/mo_techmap.cpp`

以本文 [典型工作流程](#典型工作流程multi-output-tech-mapping) 的程式碼為基礎，加入：

- 命令列參數（輸入 AIG、GENLIB 路徑、輸出 Verilog）
- Liberty → GENLIB 轉換（若需使用 ASAP7 Liberty 而非現成 GENLIB）
- 與 GRADUATE 管線的介面（例如：GRADUATE 合成後輸出 AIG → mockturtle `emap` 映射）

### 3. 建議開發順序

```text
Phase 1：驗證 mockturtle emap 行為
  → 跑通 test/algorithms/emap.cpp 對應場景
  → 用 multioutput.genlib 映射 EPFL benchmarks

Phase 2：接入自訂 cell library
  → 從 Liberty 產生 GENLIB（或擴充現有轉換工具）
  → 確認 multi-output pin（CON/SN 等）正確分組

Phase 3：與 GRADUATE / ABC 管線整合
  → GradSyn 輸出 AIG → emap 映射 → Verilog
  → 以 ABC cec 或 mockturtle equivalence_checking 驗證等價性
  → 比較 single-output map vs multi-output emap 的 area/delay

Phase 4：擴充映射目標
  → 支援更多 multi-output cell 類型（AOI、OAI 等）
  → 評估 area-oriented vs delay-oriented 策略
```

### 4. 與 GRADUATE 協作的可能架構

```text
                    ┌─────────────────┐
  Verilog / AIG ──► │ GRADUATE        │
                    │  gradsyn        │  邏輯合成（AIG 最佳化）
                    └────────┬────────┘
                             │ optimized.aig
                             ▼
                    ┌─────────────────┐
                    │ mockturtle emap │  Multi-output tech mapping
                    │  map_multioutput│
                    └────────┬────────┘
                             │ mapped.v (block_network)
                             ▼
                    ┌─────────────────┐
                    │ ABC cec / 計時  │  驗證與分析
                    └─────────────────┘
```

---

## 常見問題

### 編譯時記憶體不足或時間過長

`emap.hpp` 等標頭檔較大，建議使用 Release 模式並限制平行編譯數：

```bash
cmake -DCMAKE_BUILD_TYPE=Release ..
make -j4 emap
```

### `abc: command not found`（experiments CEC 失敗）

不影響映射演算法。若要 CEC 驗證，安裝 [Berkeley ABC](https://github.com/berkeley-abc/abc) 並加入 PATH。

### `map_multioutput=true` 但 `multioutput_gates == 0`

可能原因：

1. GENLIB 中無 multi-output cell（同名多輸出 gate 未正確定義）
2. Subject graph 中無適合的 FA/HA 結構（可嘗試 `extract_adders` 前處理）
3. `load_multioutput_gates=false` 或 `load_multioutput_gates_single` 設定不當
4. Delay-oriented 映射時，multi-output cell 可能不被選中（可改 `area_oriented_mapping=true` 測試）

### `matching_mode=structural` 與 multi-output

`map_multioutput` 在 `structural` 模式下不會執行 multi-output matching。請使用 `boolean` 或 `hybrid`。

### 大型 cell（>6 inputs）未被載入

`tech_library<N>` 的模板參數 `N` 必須 ≥ 最大輸入數。例如 ASAP7 的 8-input NAND 需 `tech_library<9>` 或更大。

### 與 ABC `map` 結果如何比較

可執行 `experiments/mapper` 做對照；或分別用 ABC `map` 與 mockturtle `emap` 映射同一 AIG，比較 area/delay，並用 `cec` 驗證等價性。

---

## 參考文件

### mockturtle 官方資源

| 資源 | 連結 / 路徑 |
|------|------------|
| 線上文件 | https://mockturtle.readthedocs.io |
| emap 演算法說明 | `third_party/mockturtle/docs/algorithms/mapper.rst`（含 emap 章節） |
| Getting Started | `third_party/mockturtle/docs/getting_started.rst` |
| GitHub | https://github.com/lsils/mockturtle |
| EPFL Logic Synthesis Libraries Showcase | https://github.com/lsils/lstools-showcase |

### 本專案相關文件

| 文件 | 內容 |
|------|------|
| [`docs/GRADUATE.md`](GRADUATE.md) | GRADUATE 梯度合成與 ABC 技術映射管線 |
| `third_party/mockturtle/experiments/emap.cpp` | Multi-output 映射完整範例 |
| `third_party/mockturtle/test/algorithms/emap.cpp` | 23 個 emap 單元測試（含 multi-output 案例） |
| `third_party/mockturtle/experiments/cell_libraries/multioutput.genlib` | 測試用 multi-output GENLIB |

### 關鍵原始碼入口

| 檔案 | 用途 |
|------|------|
| `include/mockturtle/algorithms/emap.hpp` | emap 演算法主體 |
| `include/mockturtle/utils/tech_library.hpp` | 函式庫 Boolean matching |
| `include/mockturtle/utils/standard_cell.hpp` | Multi-output cell 資料結構 |
| `include/mockturtle/networks/block.hpp` | Multi-output 網路表示 |
| `include/mockturtle/views/cell_view.hpp` | 映射結果與 cell 綁定 |

---

## 快速參考卡

```bash
# 進入專案
cd ~/research/multi_output_standard_cell/third_party/mockturtle

# 建置（首次）
mkdir -p build && cd build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DMOCKTURTLE_BUILD_EXPERIMENTS=ON \
      -DMOCKTURTLE_BUILD_TESTS=ON ..
make -j$(nproc) emap run_tests

# Multi-output 單元測試
./test/run_tests "[emap]"

# Multi-output benchmark（EPFL + multioutput.genlib）
./experiments/emap

# 基本範例
./examples/cut_enumeration
```

**啟用 multi-output 映射的最小程式碼片段**：

```cpp
emap_params ps;
ps.map_multioutput = true;
cell_view<block_network> res = emap<9>( aig, tech_lib, ps );
```
