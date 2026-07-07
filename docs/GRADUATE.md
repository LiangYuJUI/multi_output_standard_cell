# GRADUATE 使用指南

本文件說明如何在 `multi_output_standard_cell` 專案中使用位於 `third_party/GRADUATE` 的 GRADUATE 工具鏈。GRADUATE 是一個以梯度為基礎的統一邏輯合成（logic synthesis）與技術映射（technology mapping）框架，以 ABC 作為互動式前端，使用者可在同一個 ABC shell 中執行標準 ABC 命令、`gradsyn`（梯度引導合成）與 `gradmap`（技術映射）。

> **專案位置**：`third_party/GRADUATE` 為指向 `~/tools/GRADUATE` 的符號連結。以下所有路徑均以 GRADUATE 根目錄為基準；在 `multi_output_standard_cell` 中請使用 `third_party/GRADUATE`。

---

## 目錄

1. [整體架構](#整體架構)
2. [環境需求](#環境需求)
3. [安裝與建置](#安裝與建置)
4. [快速驗證](#快速驗證)
5. [典型工作流程](#典型工作流程)
6. [可用命令與功能](#可用命令與功能)
7. [時序電路流程](#時序電路流程)
8. [環境變數](#環境變數)
9. [輸出檔案與工作目錄](#輸出檔案與工作目錄)
10. [進階用法](#進階用法)
11. [常見問題](#常見問題)
12. [參考文件](#參考文件)

---

## 整體架構

GRADUATE 將邏輯合成與技術映射統一為兩個階段，共用同一套機率選擇（probability-selection）訓練模型：

```text
輸入 AIG
  │
  ▼
GradSyn（邏輯合成）
  providers: rewrite, refactor, resub, balance
  輸出: 優化後的 AIG（Pareto 狀態）
  │
  ▼
ABC &nf -Y（提取標準元件匹配候選）
  │
  ▼
GradMap（技術映射）
  providers: source mapping, techmap / nf candidates
  輸出: 閘級 Verilog 網表
```

**命令流程示意**：

```text
ABC 命令流程
  read / strash / rewrite / refactor / ...
    → gradsyn
    → 更多 ABC 命令
    → gradmap
    → 閘級網表
```

**主要特色**：

| 功能 | 說明 |
|------|------|
| ABC 整合 | 單一可執行檔 `graduate-abc`，即帶有 GRADUATE 命令的 ABC shell |
| GradSyn | 將 rewrite / refactor / resub / balance 轉為 match 候選，以梯度模型優化選擇 |
| GradMap | 消費 ABC `&nf -Y` 標準元件匹配，訓練選擇模型並重建 Verilog |
| 時序橋接 | 透過 Yosys 提取 DFF 邊界，以組合邏輯方式優化後再重接 |
| 修補版 ABC | 內建支援 GradSyn provider hooks、`&deepsyn -M`、`&nf -Y`；上游 ABC 不足 |

**第一版刻意不包含**：DREAMPlace、DEF 匯出、placement writeback、Maplace 等物理優化功能。

---

## 環境需求

### 必要工具

| 項目 | 版本 / 說明 |
|------|-------------|
| CMake | 3.16+ |
| C++ 編譯器 | 支援 C++17（g++） |
| Python 3 | 用於安裝 PyTorch / 執行輔助腳本 |
| LibTorch | C++ 訓練核心；可透過 `pip install torch` 或本機 `~/tools/libtorch` |
| Git、make、timeout | 建置與測試腳本使用 |

### 建議安裝（互動式 shell）

- `libreadline-dev`（Ubuntu/Debian）：啟用 ABC shell 的命令列編輯與歷史紀錄

### GradMap 函式庫檔案（技術映射必備）

以下檔案**未納入 Git**，需手動取得並放入 `third_party/gradmap_libs/`：

```text
asap7.lib
asap7_libcell_info.txt
```

NTU ALCOM Lab 使用者可從實驗室 Google Drive 下載：

```text
https://drive.google.com/drive/folders/1sLhZpX0BWJNVWfpsRSjvmTcepiyfna-G
```

### 時序流程額外需求

- **Yosys**：僅在執行 `seq_extract`、`seq_flow` 等時序命令時需要；純組合 `gradsyn` / `gradmap` 不需要

### 修補版 ABC

GRADUATE 已內建於 `third_party/abc/abc`，無需另外 clone ABC。此版本必須同時包含：

- GradMap `&nf -Y` 支援
- GradSyn provider dump 命令與受控 `&deepsyn -M`

---

## 安裝與建置

所有命令請在 GRADUATE 根目錄執行：

```bash
cd ~/research/multi_output_standard_cell/third_party/GRADUATE
```

### 步驟 1：安裝 PyTorch / LibTorch

**方式 A（建議）**：使用 Python venv 安裝 PyTorch wheel，CMake 會自動找到 `TorchConfig.cmake`：

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install torch
```

**方式 B**：使用本機已有的 LibTorch（例如 `~/tools/libtorch`）：

```bash
export TORCH_CMAKE_PREFIX_PATH=~/tools/libtorch
```

### 步驟 2：安裝 GradMap 函式庫檔案

從本機下載目錄複製：

```bash
./scripts/fetch_gradmap_libs.sh --from-dir ~/Downloads/gradmap_libs
```

或從 tarball 安裝：

```bash
./scripts/fetch_gradmap_libs.sh --url https://example.com/gradmap_libs.tar.gz
```

### 步驟 3：檢查環境

```bash
./scripts/check_setup.sh
```

此腳本會檢查：主機工具、PyTorch/LibTorch、修補版 ABC 特徵、Liberty / libcell 檔案是否存在。

### 步驟 4：建置

```bash
./scripts/build_abc_frontend.sh
```

建置完成後產生：

```text
build_abc_frontend/graduate-abc
```

等效的手動 CMake 命令：

```bash
cmake -S . -B build_abc_frontend \
  -DGRADUATE_ENABLE_TORCH=ON \
  -DGRADUATE_ENABLE_ABC=ON \
  -DGRADUATE_BUILD_ABC_FRONTEND=ON
cmake --build build_abc_frontend -j
```

---

## 快速驗證

### 檢查命令是否註冊

```bash
./build_abc_frontend/graduate-abc -c "graduate"
```

應列出所有 GRADUATE 命令與選項說明。

### 最小端對端 smoke test（組合邏輯）

```bash
./build_abc_frontend/graduate-abc -c \
  "read testdata/smoke.aig; st; resyn2; st; gradsyn -fast; st; gradmap -fast; topo; stime; ps"
```

`-fast` 為刻意縮小的 CPU-only 預設值，用於驗證整合路徑是否正常，**不代表最佳 QoR**。

> **重要**：請從 GRADUATE 根目錄執行 `graduate-abc`，以便 ABC 載入同目錄下的 `abc.rc`（提供 `st`、`ps`、`resyn2` 等別名）。

### 互動式 demo

```bash
cd ~/research/multi_output_standard_cell/third_party/GRADUATE
./build_abc_frontend/graduate-abc
```

在 ABC shell 中：

```text
abc> read testdata/smoke.aig
abc> strash; ps
abc> resyn2; ps
abc> gradsyn -fast
abc> ps
abc> gradmap -fast
abc> topo; stime; ps
```

---

## 典型工作流程

### 組合邏輯：合成 → 映射

```text
abc> read design.aig
abc> strash
abc> resyn2                    # 可選：傳統 ABC 預處理
abc> gradsyn -iter 10 -rounds 2
abc> ps
abc> gradmap -steps 150
abc> topo; stime; ps
abc> write_verilog result.v
```

### 使用 `-no-readback` 只產生檔案

預設情況下，`gradsyn` 與 `gradmap` 會將結果讀回目前 ABC frame。若只想在工作目錄留下檔案、不覆寫目前網路：

```text
abc> gradsyn -work exp_output/my_syn -no-readback
abc> gradmap -work exp_output/my_map -no-readback
```

### 自動化批次 demo

```bash
GRADSYN_ITERATIONS=1 GRADSYN_ROUNDS=1 GRADSYN_STEPS=1 GRADSYN_EVAL_INTERVAL=1 \
MAP_STEPS=1 MAP_EVAL_INTERVAL=1 MAP_DEVICE=cpu \
./scripts/run_abc_owned_flow_demo.sh
```

預設使用 `testdata/smoke.aig`。可指定其他 benchmark：

```bash
CASE_ROOT=/path/to/benchmarks CASES="design1 design2" \
./scripts/run_abc_owned_flow_demo.sh
```

---

## 可用命令與功能

在 ABC shell 中輸入 `graduate` 可查看完整說明。以下為摘要。

### `graduate`

列印 GRADUATE 命令註冊與用法。

### `gradsyn` — 梯度引導邏輯合成

對目前 ABC 網路執行 GradSyn formal refinement。預設使用 providers `rewrite,refactor,resub,balance`，並將 `global_best.aig` 讀回 ABC。

**常用選項**：

| 選項 | 預設值 | 說明 |
|------|--------|------|
| `-backend <name>` | `native_formal` | `native_formal` / `native_selected` / `native_providers` |
| `-providers <list>` | `rewrite,refactor,resub,balance` | native_providers 模式的 provider 列表 |
| `-work <dir>` | `exp_output/abc_gradsyn` | 工作目錄 |
| `-fast` | — | demo 預設：`-iter 1 -rounds 1 -steps 1 -eval 1 -device cpu` |
| `-iter <n>` | 100 | 迭代次數 |
| `-rounds <n>` | 2 | 每輪訓練輪數 |
| `-steps <n>` | 4 | 每輪訓練步數 |
| `-eval <n>` | 2 | 評估間隔 |
| `-device <name>` | `cuda` | `auto` / `cuda` / `cpu` |
| `-lr <x>` | 0.02 | 學習率 |
| `-loss <name>` | `ADP` | 損失函數類型 |
| `-no-readback` | — | 不將 `global_best.aig` 讀回 ABC |
| `-details` | — | 顯示 provider 統計與內部輸出 |

**進階 provider 參數**（影響候選生成）：

- `-max-root <n>`：每個 root 最多 match 數（預設 4）
- `-refactor-N/M/C`：refactor 支援大小與節省節點門檻
- `-resub-K/N/M`：resub cut 大小與節點限制

**範例**：

```text
abc> gradsyn -fast
abc> gradsyn -iter 50 -rounds 2 -steps 4 -device cuda -work exp_output/syn_run
abc> gradsyn -backend native_providers -providers rewrite,balance -details
```

### `gradmap` — 梯度引導技術映射

對目前 ABC 網路執行 GradMap：呼叫 ABC `&nf -Y` 取得標準元件匹配、訓練選擇模型、重建 Verilog 並讀回 ABC。

**常用選項**：

| 選項 | 預設值 | 說明 |
|------|--------|------|
| `-work <dir>` | `exp_output/abc_gradmap` | 工作目錄 |
| `-lib <liberty>` | `third_party/gradmap_libs/asap7.lib` | ABC Liberty 路徑 |
| `-libcell <file>` | `asap7_libcell_info.txt` | GRADUATE libcell info |
| `-rec <aig>` | — | 可選：ABC `rec_start3` 錄製函式庫 |
| `-o <verilog>` | `work/best.v` | 輸出 Verilog 路徑 |
| `-fast` | — | demo 預設：`-steps 1 -eval 1 -device cpu` |
| `-steps <n>` | 150 | 訓練步數 |
| `-eval <n>` | 10 | 評估間隔 |
| `-lr <x>` | 0.05 | 學習率 |
| `-device <name>` | `auto` | `auto` / `cuda` / `cpu` |
| `-loss <name>` | `ADP` | 損失函數類型 |
| `-no-readback` | — | 不將輸出 Verilog 讀回 ABC |
| `-details` | — | 顯示 warm-start 與 match 統計 |

**範例**：

```text
abc> gradmap -fast
abc> gradmap -steps 150 -device cuda -work exp_output/map_run
abc> gradmap -lib /path/to/custom.lib -libcell /path/to/custom_libcell_info.txt
```

### 時序相關命令

| 命令 | 說明 |
|------|------|
| `seq_extract <seq.v>` | 用 Yosys 將 DFF 暴露為組合邊界埠，讀取提取後的 BLIF |
| `seq_reinsert` | 將優化後的組合區塊重接回 DFF 邊界，寫出時序 Verilog wrapper |
| `seq_check <seq.v>` | 對提取邊界執行組合 CEC，並在可能時執行 ABC `dsec` |
| `seq_flow <seq.v>` | 一鍵執行 `seq_extract → gradsyn → gradmap → seq_reinsert → seq_check` |

**時序共用選項**：

| 選項 | 說明 |
|------|------|
| `-top <name>` | 頂層模組名稱 |
| `-out <dir>` | 工作目錄 |
| `-yosys <bin>` | Yosys 執行檔路徑 |
| `-sv` | 使用 Yosys `read_verilog -sv` |
| `-no-readback` | 不將生成網路讀回 ABC |
| `-details` | 顯示後端腳本與內部輸出 |

### 標準 ABC 功能

`graduate-abc` 即完整 ABC，可使用所有標準命令與 `abc.rc` 別名，例如：

| 別名 / 命令 | 說明 |
|-------------|------|
| `st` | `strash` |
| `ps` | `print_stats` |
| `rw` / `rf` / `rs` / `b` | rewrite / refactor / resub / balance |
| `resyn2` | 標準 IWLS 合成腳本 |
| `read` / `write_aiger` / `write_verilog` | 讀寫網表 |
| `topo; stime` | 拓撲排序與時序分析（映射後） |

---

## 時序電路流程

GRADUATE 內部目前以組合邏輯為主；時序 benchmark 透過 Yosys 前處理：

```text
時序 Verilog
  → Yosys 將每個 DFF 暴露為 Q 輸入 / D 輸出 / clock 輸出
  → graduate-abc 優化提取出的組合區塊
  → 生成 Verilog wrapper 重接 DFF 邊界
  → ABC 對提取邊界做組合等價檢查
  → ABC dsec 對正規化時序網路做等價檢查（實驗性）
```

### 設定 Yosys

```bash
export GRADUATE_YOSYS=/path/to/yosys
```

### 快速時序 smoke test

```bash
./build_abc_frontend/graduate-abc -c \
  "seq_flow testdata/seq_and_dff_or.v -top seq_and_dff_or -out exp_output/demo_seq"
```

### 使用 Python 腳本（等效於 ABC 命令）

```bash
./scripts/run_sequential_flow.py testdata/seq_and_dff_or.v \
  --top seq_and_dff_or \
  --out exp_output/seq_and_dff_or
```

### 時序流程支援範圍

**目前支援**：

- Yosys 可接受的 gate-level 或簡單 RTL Verilog
- 簡單 DFF（`$dff`）
- 對 PI / state-Q 到 PO / state-D 區塊的組合優化

**尚未保證**：

- 保留原始 FF 實例名稱
- 非同步 reset、初始化語意
- memory 陣列、blackbox 模組
- 生產級 gate-level 時序 Verilog 輸出

---

## 環境變數

| 變數 | 說明 |
|------|------|
| `GRADUATE_LIBERTY` | Liberty 檔案路徑（覆寫預設 `asap7.lib`） |
| `GRADUATE_LIBCELL_INFO` | libcell info 檔案路徑 |
| `GRADUATE_REC_LIB` | 可選：ABC `rec_start3` 用的錄製函式庫 AIG |
| `GRADUATE_ABC_SOURCE_DIR` | 覆寫內建 ABC 原始碼路徑 |
| `GRADUATE_YOSYS` | Yosys 執行檔路徑 |
| `GRADUATE_PYTHON` | 時序腳本使用的 Python 直譯器 |
| `TORCH_CMAKE_PREFIX_PATH` | LibTorch CMake 前綴路徑 |
| `BUILD_DIR` | 建置目錄（預設 `build_abc_frontend`） |

### 使用自訂標準元件函式庫

```bash
# 1. 指定 Liberty
export GRADUATE_LIBERTY=/path/to/your.lib

# 2. 從同一 Liberty 產生 libcell info
python3 scripts/generate_libcell_info_v2.py \
  /path/to/your.lib \
  -o /path/to/your_libcell_info.txt

# 3. 設定環境變數
export GRADUATE_LIBCELL_INFO=/path/to/your_libcell_info.txt
```

---

## 輸出檔案與工作目錄

### GradSyn 工作目錄（`-work`）

| 檔案 | 說明 |
|------|------|
| `global_best.aig` | 最佳合成結果；預設會讀回 ABC |
| `current.aig` | 輸入 AIG 快照 |

### GradMap 工作目錄（`-work`）

| 檔案 | 說明 |
|------|------|
| `matches.nf_y.txt` | ABC `&nf -Y` 產生的匹配檔 |
| `best.v` | 映射後的 Verilog 網表 |
| `current.aig` | 輸入 AIG 快照 |

### 時序流程工作目錄（`-out`）

```text
exp_output/seq_demo/
  extracted/          # Yosys 提取的 BLIF 與 manifest
  gradsyn/            # GradSyn 工作目錄
  gradmap/            # GradMap 工作目錄
  reinserted.v        # 重接 DFF 後的時序 wrapper
```

> 目前實作刻意保留部分檔案交接以確保穩定性與回歸測試；長期目標是改為記憶體內 `Gia_Man_t` 直接傳遞。

---

## 進階用法

### 查看詳細內部輸出

GRADUATE 命令預設輸出簡潔摘要；加上 `-details` 可顯示 provider 統計、ABC 內部訊息與後端路徑：

```text
abc> gradsyn -fast -details
abc> gradmap -fast -details
abc> seq_flow testdata/seq_and_dff_or.v -top seq_and_dff_or -out exp_output/seq -details
```

### 模組結構

```text
include/graduate/common   共用機率 / 模型工具
include/graduate/syn      GradSyn 公開 API
include/graduate/map      GradMap 公開 API
include/graduate/abc      ABC 橋接 API
src/common                共用實作
src/syn                   GradSyn 實作
src/map                   GradMap 實作
src/abc                   ABC 整合 hooks
third_party/abc           內建修補版 ABC
third_party/gradmap_libs  Liberty / libcell 檔案（需手動安裝）
scripts/                  建置、檢查、demo 腳本
testdata/                 測試用例
```

### 測試資料

| 檔案 | 用途 |
|------|------|
| `testdata/smoke.aig` | 組合邏輯 smoke test |
| `testdata/seq_and_dff_or.v` | 時序 smoke test |
| `testdata/smoke_selected_matches.txt` | native_selected 後端測試 |
| `testdata/tiny_nfy_match.txt` | GradMap parser 單元測試 |

---

## 常見問題

### `find_package(Torch) failed`

安裝 PyTorch 或設定 LibTorch 路徑：

```bash
# 方式 A
source .venv/bin/activate && pip install torch

# 方式 B
export TORCH_CMAKE_PREFIX_PATH=~/tools/libtorch
```

或手動指定：

```bash
cmake ... -DCMAKE_PREFIX_PATH=$(python3 -c 'import torch; print(torch.utils.cmake_prefix_path)')
```

### `cannot load libcell info` / Liberty 缺失

執行：

```bash
./scripts/fetch_gradmap_libs.sh --from-dir ~/Downloads/gradmap_libs
```

或設定 `GRADUATE_LIBCELL_INFO` / `gradmap -libcell <file>`。

### `ABC &nf -Y produced no match file`

內建 ABC 缺少 GradMap `&nf -Y` 修補。請確認使用 GRADUATE 內建的 `third_party/abc/abc`，勿改用上游 ABC。

### `dump_rewrite_candidates: unknown command`

內建 ABC 缺少 GradSyn provider 修補。請以 `GRADUATE_ENABLE_ABC=ON` 重新建置，並確認 ABC 原始碼正確。

### `GradSyn failed before training`

檢查 ABC provider dump 命令是否存在，以及建置時是否啟用 `GRADUATE_ENABLE_ABC=ON`。

### ABC 別名（`st`、`ps`、`resyn2`）無法使用

請從 GRADUATE 根目錄啟動 `graduate-abc`，以便載入 `abc.rc`。

### CUDA 相關

- `gradsyn` 預設 `-device cuda`；若無 GPU，請使用 `-device cpu` 或 `-fast`
- `gradmap` 預設 `-device auto`；demo 可用 `-fast`（強制 CPU）

---

## 參考文件

GRADUATE 原始碼目錄內有更詳細的設計文件：

| 文件 | 內容 |
|------|------|
| `third_party/GRADUATE/README.md` | 專案總覽與 Quick Start |
| `third_party/GRADUATE/docs/setup.md` | 伺服器安裝、建置、自訂函式庫 |
| `third_party/GRADUATE/docs/architecture.md` | 架構設計與模組劃分 |
| `third_party/GRADUATE/docs/sequential_benchmarks.md` | 時序 benchmark 流程細節 |
| `third_party/GRADUATE/docs/gradmap_refactor.md` | GradMap 重構與 `&nf -Y` 語意 |

---

## 快速參考卡

```bash
# 進入專案
cd ~/research/multi_output_standard_cell/third_party/GRADUATE

# 建置（首次）
source .venv/bin/activate          # 若使用 venv
./scripts/fetch_gradmap_libs.sh --from-dir ~/Downloads/gradmap_libs
./scripts/check_setup.sh
./scripts/build_abc_frontend.sh

# 組合 smoke test
./build_abc_frontend/graduate-abc -c \
  "read testdata/smoke.aig; st; resyn2; gradsyn -fast; gradmap -fast; topo; stime; ps"

# 時序 smoke test（需 Yosys）
./build_abc_frontend/graduate-abc -c \
  "seq_flow testdata/seq_and_dff_or.v -top seq_and_dff_or -out exp_output/demo_seq"

# 互動式 shell
./build_abc_frontend/graduate-abc
```
