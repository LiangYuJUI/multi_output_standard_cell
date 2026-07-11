# ABC Multi-Output Mapping 整合規劃

本文件依 **repository 現況**（程式碼、腳本、真實 `matches.nf_y_multi.txt`、驗證結果）整理：如何以 **ABC-native `emap`** 產生含 multi-output binding 的 match file，以及 **GradMap Phase 3** 應如何以 **階層式、factorized binding decision** 消費該格式。

> **狀態標記**：`[confirmed]` 已由程式／輸出驗證；`[planned]` 設計已定、尚未實作；`[open]` 演算法／語意待確認。  
> **相關文件**：[GRADUATE.md](GRADUATE.md)、[GRADMAP.md](GRADMAP.md)、[MOCKTURTLE.md](MOCKTURTLE.md)、[SCRIPTS.md](SCRIPTS.md)、[ASAP7_MULTI_OUTPUT_CELLS.md](ASAP7_MULTI_OUTPUT_CELLS.md)、[GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md)、[**NF_EMAP_CANDIDATE_ORDER.md**](NF_EMAP_CANDIDATE_ORDER.md)（`&nf`／`emap` 候選枚舉與 dump 順序）

---

## 目錄

1. [專案現況](#1-專案現況)
2. [已完成的 emap / `emap -Y`](#2-已完成的-emap--emap--y)
3. [目前 `nf_y_multi` 格式](#3-目前-nf_y_multi-格式)
4. [GradMap 現有 SO 架構](#4-gradmap-現有-so-架構)
5. [Multi-output 問題](#5-multi-output-問題)
6. [已驗證的 root-pair invariant](#6-已驗證的-root-pair-invariant)
7. [新 GradMap factorized decision model](#7-新-gradmap-factorized-decision-model)
8. [CPU 資料模型](#8-cpu-資料模型)
9. [GPU / probability model](#9-gpu--probability-model)
10. [Area / load / timing](#10-area--load--timing)
11. [Required / accumulated weight（open）](#11-required--accumulated-weightopen)
12. [Warm start](#12-warm-start)
13. [Hard reconstruction](#13-hard-reconstruction)
14. [Literal / phase 規則](#14-literal--phase-規則)
15. [實作階段](#15-實作階段)
16. [驗證策略](#16-驗證策略)
17. [風險與限制](#17-風險與限制)
18. [檔案與命令速查](#18-檔案與命令速查)
19. [一句話總結](#19-一句話總結)

---

## 1. 專案現況

### 1.1 已完成 `[confirmed]`

| 項目 | 路徑／證據 |
|------|------------|
| ABC-native `emap` 併入 GRADUATE bundled ABC | `third_party/GRADUATE/third_party/abc/abc/src/map/emap/`（`emap.c` / `emapCore.c` / `emap.h`） |
| `graduate-abc` 同時具備 `&nf -Y`、`emap`、`emap -Y`、`emap -M` | `third_party/GRADUATE/build_abc_frontend/graduate-abc`（`emap -h`） |
| dump level 1 / 2 / 3 | `Emap_ManDumpMatches`；`-M 1|2|3` |
| `run_abc_emap_map.sh` / fair compare / CEC | `scripts/sh/run_abc_emap_map.sh`、`run_fair_nf_emap_compare.sh`、`cec_fair_nf_emap.sh` |
| GENLIB 由同一份 Liberty 經 ABC `read_lib; write_genlib` 產生 | `third_party/GRADUATE/third_party/gradmap_libs/asap7.genlib`（171 GATE，含 FA/HA twin） |
| multi-output libcell 檔已產生 | `third_party/GRADUATE/third_party/gradmap_libs/asap7_libcell_info_v2_multi_output.txt`（`format: libcell_info_v2_multi_output`） |
| MOG root-pair 不重疊驗證 | `scripts/py/validate_emap_mog_root_overlap.py`（fair `emap/` 20/20 OK） |
| mapped Verilog CEC | `output/fair_nf_emap_asap7genlib/cec_report.md`（nf 20/20、emap 20/20） |

### 1.2 尚未完成 `[planned]`

| 項目 | 現況 |
|------|------|
| GradMap 讀 `libcell_info_v2_multi_output` | `MapLibrary` 僅接受 `libcell_info_v2` + 單一 `output_pin` |
| GradMap 解析 `BIND` / `MBIND` / `nf_y_multi` | `NfYParser` 僅經典 `&nf -Y` |
| Binding-aware probability / soft cost | 僅 per-root-literal softmax |
| Multi-output reconstruction | `reconstructor` 每 root 一顆 SO cell |
| `gradmap -match` / `-skip-nf-y` / `-match-format` | `abc_commands.cpp` 硬編碼 `&nf -Y` → `matches.nf_y.txt` |

### 1.3 正式主路徑 vs 歷史背景

- **正式主路徑**：`graduate-abc` → `emap -Y` → `matches.nf_y_multi.txt` →（未來）GradMap binding 訓練。
- **Phase 0 歷史**：mockturtle `mo_techmap` + 測試用 `multioutput.genlib`（約 50 gates）曾用於 QoR／CEC smoke；**不再**作為 match-file 或成本模型的主要來源。保留於 [MOCKTURTLE.md](MOCKTURTLE.md)。

### 1.4 ABC 來源

| Tree | 路徑 | `emap -Y` | `&nf -Y` | 腳本預設 |
|------|------|-----------|----------|----------|
| GRADUATE bundled | `third_party/GRADUATE/third_party/abc/abc` | ✅ | ✅ | ✅ `graduate-abc`（**SoT**） |
| repo standalone | `third_party/abc` | 可能過期 | 視 patch | 非正式路徑；勿當 build 來源 |

---

## 2. 已完成的 emap / `emap -Y`

### 2.1 命令 `[confirmed]`

```text
emap [-amvh] [-Y <match.txt>] [-M <level>]
```

| Flag | 語意 |
|------|------|
| `-a` | area-oriented（無 required-time pruning） |
| `-m` | toggle multi-output（**預設開啟**；勿隨意加 `-m` 關掉） |
| `-v` | verbose |
| `-Y file` | dump `nf_y_multi_v1` |
| `-M 1\|2\|3` | dump 詳細度（預設 1） |
| `-D 0\|1\|2` | SO dump dedup：none／exact／nf-like（emap 預設 1；**腳本正式政策 nf-like**） |
| `-K <num>` | SO **export-only** cut top-K（emap 預設 0；**腳本正式政策 16**；不改內部 `EMAP_CUT_MAX=128`） |

### 2.2 Dump level `[confirmed]`

| Level | SO 候選 | MOG 候選 | `M`／`MBIND`／selected `BIND` |
|-------|---------|----------|----------------------------------|
| **1** | 僅已選 | 僅已選 | ✅ |
| **2** | 僅已選 | MOG tuple 列舉 | ✅ |
| **3** | cut × cell（受 `-D`／`-K`） | MOG tuple 列舉 | ✅ |

### 2.2b 正式 SO export 政策（Phase 4）`[confirmed]`

| 項目 | 政策 |
|------|------|
| Internal cuts | **128**（不變） |
| SO export top-K | **16**（protected 算入 K；`P≥K` 時可超過 K） |
| SO pin-perm | **nf-like**（selected-first，否則 first-enumerated） |
| SO exact dedup | 啟用（nf-like 路徑內含） |
| MO BIND | **semantic endpoint-order**（ROOTS/ROLES 換序合併；保留 ordered FANINS／真正 role swap／phase） |
| MOG enumeration | **不變** |

腳本：`--so-dedup nf-like --so-cut-topk 16`（預設）。回退：`--so-cut-topk 32` 或 `--so-dedup exact`／`none`。細節見 [`NF_EMAP_CANDIDATE_ORDER.md`](NF_EMAP_CANDIDATE_ORDER.md)。

### 2.3 建議實驗管線 `[confirmed]`

```text
EPFL .aig
  → ABC balance / &deepsyn（可選）→ synth.aig
  → read_genlib asap7.genlib
  → emap -a -v -Y matches.nf_y_multi.txt -M 3 -D 2 -K 16
  → write_verilog
  → CEC vs synth.aig（scripts/sh/cec_fair_nf_emap.sh）
  → validate_emap_nf_y_multi.py --formal
```

公平比較 `&nf -Y` vs `emap`：`scripts/sh/run_fair_nf_emap_compare.sh`（共用 `synth.aig`）。  
彙整輸出範例：`output/fair_nf_emap_asap7genlib/`（`nf/`、`emap/` dump_level 3、`emap_l1/`、`compare_nf_emap.md`、`cec_report.md`）。

### 2.4 GENLIB `[confirmed]`

```bash
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read_lib third_party/gradmap_libs/asap7.lib; \
   write_genlib third_party/gradmap_libs/asap7.genlib"
```

- 與 `&nf` 使用的 `asap7.lib` **同源**；含 FA/HA 雙 `GATE` 行（CON／SN）。
- GENLIB delay 為簡化模型（常為 unit-ish pin delay）；**emap 只負責候選／warm start**，GradMap 訓練與 STA 應以 Liberty 衍生的 `libcell_info` 為準。
- 腳本預設仍可能指向 mockturtle `multioutput.genlib`；公平／CEC 實驗應顯式傳 `--genlib …/asap7.genlib`。

---

## 3. 目前 `nf_y_multi` 格式

> 以下語法取自真實檔案  
> `output/fair_nf_emap_asap7genlib/emap/adder/matches.nf_y_multi.txt`（`# dump_level: 3`）。  
> **勿**再使用舊文件中與 exporter 不符的假格式。

### 3.1 檔頭

```text
# format: nf_y_multi_v1
# mo_mapper: abc_emap
# literal_space: abc_strash
# dump_level: 3
# mo_dedup: semantic-endpoint-order
# mo_dedup_stats: visited=<n> unique=<n> removed=<n> selected_aliases=<n>
# network: .../synth
```

（`mo_dedup*` 為 exporter header comment；舊 parser 可忽略。）

### 3.2 Section 順序（level 3）

1. `# --- primary inputs ---`
2. `# --- SO candidates (cut x cell) ---`（僅 level ≥ 3）
3. `# --- MOG tuple candidates ---`（僅 level ≥ 2）
4. `# --- selected candidates ---`
5. `# --- multi-output bindings (selected) ---`
6. `# --- primary outputs ---`
7. `# --- selected mapping (warm start) ---`

### 3.3 行語法（真實範例）

**PI / PO**

```text
2 input 0.00
514 output 0.00 776
```

**SO 候選**（與 `&nf -Y` 相容；可選尾綴 `BIND:<id>`）

```text
<root_lit> <cell> <area> <n_fanins> <fanins...> <n_cover> [<cover...>] [BIND:<id>]

772 AND2x2_ASAP7_75t_R 0.09 2 2 258 0
788 FAx1_ASAP7_75t_R 0.20 3 772 260 4 0 BIND:1
791 FAx1_ASAP7_75t_R 0.20 3 772 260 4 0 BIND:1
```

**MOG tuple / selected BIND 區塊**

```text
BIND <id> <cell> <area> <n_fanins> <fanins...> <root0> <root1>
  ROOTS <root0> <root1>
  ROLES <role0> <role1>          # 例如 CON SN 或 SN CON
  FANINS <fanin_lits...>
  COVER <n> [<cover...>]
```

真實例：

```text
BIND 128 FAx1_ASAP7_75t_R 0.20 3 61 317 1169 1183 1180
  ROOTS 1183 1180
  ROLES CON SN
  FANINS 61 317 1169
  COVER 0
```

**Warm start**

```text
M<root_lit> <cell> <area> <n_fanins> <fanins...>     # SO 已選
MBIND <id> <cell> <area> <fanins...>                 # MO 已選（面積只出現一次）
```

```text
M772 NOR2xp33_ASAP7_75t_R 0.06 2 3 259
MBIND 1 FAx1_ASAP7_75t_R 0.20 772 260 4
M789 INVx1_ASAP7_75t_R 0.04 788
```

### 3.4 與經典 `&nf -Y` 的關係

| | `&nf -Y` | `emap -Y` |
|---|----------|-----------|
| SO 候選行 | ✅ | ✅（格式相容） |
| `M` | ✅ | ✅ |
| `BIND` / `MBIND` / `ROLES` | ❌ | ✅ |
| GradMap 今日能否讀 | ✅ | ❌（尚無 `nf_y_multi` parser） |

---

## 4. GradMap 現有 SO 架構

`[confirmed]` 路徑均在 `third_party/GRADUATE/`：

| 元件 | 檔案 | 行為 |
|------|------|------|
| `MapMatch` | `include/graduate/map/mapping_graph.h` | **單一** `Literal root` |
| `MapCell` | `include/graduate/map/library.h` | **單一** `MapPin output_pin` |
| `NfYParser` | `src/map/nf_y_parser.cpp` | 僅 `M` / candidate / input / output / CONST |
| Softmax | `weight_engine.cpp`、`torch_timing.cpp` | **per root literal** |
| Warm start | `warm_start.cpp` | 僅 `M` records |
| Reconstruct | `reconstructor.cpp` | 每 root 一顆 SO instance |
| ABC 入口 | `abc_commands.cpp` | `&nf -Y` → `matches.nf_y.txt` |

**CPU required / accumulated（ordinary match）** `[confirmed]`：

```text
accumulated[match] = required[root] × probability[match]
required[fanin]    ← soft-OR 更新：
  r' = clamp(1 - (1 - r_old) × (1 - accumulated), 0, 1)
```

GPU（`torch_timing.cpp`）語意相同：`group_accumulated = group_required * group_probs`。

此模型假設「一個 root ↔ 一組互斥 SO matches」。FA/HA 打破該假設，故需第 7 節的 factorized 擴充。

---

## 5. Multi-output 問題

### 5.1 一個 physical cell、兩個 roots

以 `FAx1_ASAP7_75t_R` 為例（libcell）：

| Output pin | Function（摘要） | Area（整顆） |
|------------|------------------|--------------|
| `CON` | majority-like carry | **0.20412**（只計一次） |
| `SN` | XOR3-like sum | 同上 |

若把兩個 root 當獨立 softmax 群組，各自選 `FAx1`，會：

- area / input cap **雙計**；
- 無法保證同一顆 instance 的 fanin／phase 一致。

### 5.2 不要物化完整 Cartesian product `[planned]`

設 root `a`（SN）有 SO matches `A0..A2`，root `b`（CON）有 `B0..B3`，另有 FA binding。

**禁止**主要方案：

```text
物化全部 Ai × Bj  （此例 12 個 compound match objects）
```

改用第 7 節的兩層 factorized decision。

### 5.3 概念分層（必須分清）

| 層 | 是什麼 | 不是什麼 |
|----|--------|----------|
| AIG / timing graph | ABC literals、fanin→root arcs、STA levels | BindingGroup |
| Ordinary SO `MapMatch` | 單 root、單 output cell | FA 整顆 |
| Physical `MapBinding` | 一顆 FA/HA + 多 endpoints | AIG node |
| `MapBindingGroup` | **decision-layer** 分支 softmax | MapNode／timing node／`fanins=[a,b]` 的 ordinary match |

---

## 6. 已驗證的 root-pair invariant

### 6.1 驗證程式 `[confirmed]`

```bash
./Nonescripts/py/validate_emap_mog_root_overlap.py output/fair_nf_emap_asap7genlib/emap
```

路徑：`scripts/py/validate_emap_mog_root_overlap.py`。

檢查：

1. `# --- MOG tuple candidates ---` 的所有 `BIND` + `ROOTS`
2. `# --- multi-output bindings (selected) ---`
3. `MBIND` 與 selected `BIND` id／cell 一致性，以及 MBIND 間 node 重疊

規則：

- **同一** root-pair（`frozenset({lit>>1})`）可有多個 `BIND` id（pin permutation／FANINS 排列）→ **合法**。
- **不同** root-pair 若共用 base node（例如 `[a,b]` 與 `[b,c]`）→ **FAIL**。
- 比較用 **base node**（literal 去 phase）；mapping 仍保留完整 literal。

fair `emap/`（dump_level 3）結果：**20/20 OK**（含 hyp 16062 selected pairs）。

### 6.2 對 Phase 3 的含義 `[planned]`

第一版可採：

```text
每個 base node（及實際使用的 root literal）最多屬於一個 MapBindingGroup
```

因此：

- 各 group **獨立** branch softmax；
- **不需要** global exact cover / set packing / inter-group mutex。

Parser／建圖時若輸入違反 invariant → **明確報錯**，禁止 silently 建不合法 groups。

> 實測中同一 pair 未同時出現 FA+HA 兩種 cell family；腳本目前把「同 pair 多 cell」視為替代。若未來出現，屬 group 內多個 BIND branches，仍不違反 non-overlap。

---

## 7. 新 GradMap factorized decision model

`[planned]` — 指導實作；**尚未**寫入 GradMap 程式碼。

### 7.1 兩層決策

假設 emap 為 root pair `(a, b)` 找到 FA（`SN→a`，`CON→b`），且：

- `a` 的 ordinary SO：`A0, A1, A2`
- `b` 的 ordinary SO：`B0, B1, B2, B3`
- 同 pair 可有多個合法 `BIND`（42, 43, …）

**第一層 — BindingGroup branch softmax**

```text
branches = { SO } ∪ { BIND_id | id ∈ pair 的所有 BIND }
例：P_SO, P_BIND42, P_BIND43, ...
Σ_branches P = 1
```

**第二層 — 原本 root-local softmax（不變）**

```text
q_a = softmax(A0, A1, A2)
q_b = softmax(B0, B1, B2, B3)
```

**有效機率**

```text
P(Ai)              = P_SO × q_a[i]
P(Bj)              = P_SO × q_b[j]
P(FA.SN → a)       = P_BIND*     # 該選中的 BIND branch
P(FA.CON → b)      = P_BIND*     # 必須與 SN 相同
```

同一顆 physical binding 的所有 output endpoints **共享完全相同**的 binding probability。

### 7.2 與完整 Cartesian product 的關係

Factorized 表示對應：

```text
P([Ai, Bj]) = P_SO × q_a[i] × q_b[j]
P([BIND_k]) = P_BIND_k
```

**不需要**建立 `|SO(a)| × |SO(b)|` 個 compound objects。

### 7.3 假設（必須驗證）`[open]` / Phase 3A–3D

SO branch 假設：

- 選定的 `Ai` 與 `Bj` **可以合法共存**（無 cover incompatibility）；
- 不會形成 combinational cycle；
- pair 的 SO 成本可由兩個 SO implementation 的成本組合表示。

> **尚未**在 repository 證明所有 SO candidate pair 皆相容。列為 Phase 3 驗證項，**不可**宣稱已證明。

### 7.4 Decision graph vs timing graph

```text
Decision graph（不進 STA levelization）
  MapBindingGroup
    ├─ branch logits: SO | BIND_42 | BIND_43 | ...
    ├─ local q_a over SO(a)
    └─ local q_b over SO(b)

Timing graph（仍是 AIG literals）
  FA fanins ──SN arc──► root a ──► downstream
  FA fanins ──CON arc─► root b ──► downstream
  ordinary match fanins ──► ordinary roots
```

**禁止**：

- 把 BindingGroup 當 AIG／STA node；
- 寫成 `fanins=[a,b] → virtual root`（會造成 `a→group→a` 人造環）。

### 7.5 文字示意

```text
        ┌── BindingGroup({a,b}) ──┐
        │  softmax: SO / FA_k     │
        └───────────┬─────────────┘
           ┌────────┴────────┐
           ▼                 ▼
     P_SO · q_a(Ai)    P_FA (shared)
     P_SO · q_b(Bj)    SN→a 且 CON→b
           │                 │
           ▼                 ▼
     timing @ a,b        timing @ a,b
     (各 SO cell)        (各 output pin arcs)
```

---

## 8. CPU 資料模型

`[planned]` 概念模型（非完整實作）。

### 8.1 `MapCell`（擴充）

今日：單一 `output_pin`。  
目標：多個 output pins，每個含：

- name / role（`Y` / `CON` / `SN`）
- Boolean function
- max capacitance
- input→output timing arcs（rise/fall delay／transition LUT、timing sense）

SO：`outputs_num = 1`；FA/HA：`CON` + `SN`。  
Loader 需支援 `format: libcell_info_v2_multi_output`（檔案已存在，GradMap 尚未讀）。

### 8.2 `MapMatch`（維持 SO）

- 一個 root literal、一顆 SO cell、fanins、cover、area、pin caps、local raw weight。  
- **不要**把 FA 的兩個 outputs 偽裝成兩個獨立 ordinary matches 來「各算半顆」。

### 8.3 `MapBinding`（新增）

一顆 **physical** multi-output candidate：

- `bind_id`、physical cell、shared fanins、**shared area**、**shared input-pin caps**
- endpoints[]：`root_literal`、`role`（SN/CON）、`output_pin_index`、cover／phase

### 8.4 `MapBindingGroup`（新增，decision-only）

- identity = **exact root literal pair**／base-node pair（**不是** bind id）
- branches：`SO` + 一個或多個 `BIND`
- 各 root 的 ordinary SO match 列表
- group branch raw weights、warm-start／selected branch

規則：多個 bind id ∈ 同一 group；conflict 用 base node；endpoint 用完整 literal。

### 8.5 `MapCircuit`（擴充欄位）

新增：`bindings`、`binding_groups`、`root_to_group`、`selected_binding_records`。  
Ordinary nodes／matches／PI／PO **不需**為了 MOG 全面重寫。

---

## 9. GPU / probability model

`[planned]`

### 9.1 兩類可學習參數（同一 optimizer flow）

| 類別 | 內容 | Softmax 分組 key |
|------|------|------------------|
| A. Ordinary SO | 沿用 `match_root_lits`、areas、pin caps、raw weights、timing levels | **root literal** |
| B. Binding branches | group id、branch type（SO/BIND）、binding fanins／area／caps、output→root／pin | **binding group id** |

- 兩類 logits 都進同一 loss、同一次 backward、同一 Adam、可共用 temperature annealing。  
- **統一的是 optimization flow，不是 timing graph 資料結構**。  
- Binding branch **不參與** timing levelization。

### 9.2 Effective probability（tensor 視角）

```text
P_eff[Ai]     = P_group[SO]   × q_a[i]
P_eff[Bj]     = P_group[SO]   × q_b[j]
P_eff[bind_k] = P_group[BIND_k]          # 套用到該 binding 所有 endpoints
```

---

## 10. Area / load / timing

`[planned]` 原則（硬性）：

### 10.1 Area

```text
Area_MOG = Σ_bindings  P_binding × Area(cell)     # 整顆一次
Area_SO  = P_SO × (E[area|a] + E[area|b])         # 兩 root 的 SO 期望面積
```

**禁止**：SN／CON 各算一次 area；或把 area 對半分給兩 roots。

### 10.2 Input capacitance

FA/HA input pins 屬同一 physical cell → load 貢獻在 **binding level 累加一次**。  
**禁止**把同一 input cap 分給兩個 output endpoints 再各加一次。

### 10.3 Timing

SN 與 CON：

- 不同 output pin、不同 arcs、不同 output load、不同 arrival／slew／delay。  
- **只共享** binding probability，**不共享** delay。

### 10.4 STA topology

不新增虛擬 node／level。真實 edges：

```text
binding fanins → SN root
binding fanins → CON root
ordinary match fanins → ordinary root
```

---

## 11. Required / accumulated weight（open）

### 11.1 問題陳述 `[open]`

Ordinary match：

```text
accumulated = required[root] × P(match)
```

一顆 FA 同時服務 `a`、`b`。若直接：

```text
(required[a] × P_FA + required[b] × P_FA) × Area(FA)
```

會對 **同一 physical instance** 雙計（或錯誤加權）。

### 11.2 必須先確認的語意

閱讀 `weight_engine.cpp` / `torch_timing.cpp` 後，確認 `required` 在 GradMap 中是：

- reachability probability？
- demand flow / multiplicity？
- differentiable ownership weight？
- 其他？

（現況實作：PO `required=1`，fanin 以 soft-OR 聚合 `accumulated`——偏 **probabilistic ownership**，但用於 MOG 時仍需正式定義。）

### 11.3 可研究的初版 surrogate（非定案）

- `act = max(required[a], required[b])`
- smooth max
- 若 required 確為機率：`act = 1 - (1-r_a)(1-r_b)`（union）

然後：`accumulated_binding = act × P_binding`（再乘 area／input cap **一次**）。

### 11.4 完成條件（此 open 關閉前）

- [ ] 書面定義與 ordinary `required` 一致  
- [ ] hard mode：**恰好一顆** instance  
- [ ] CPU／GPU 公式一致  
- [ ] finite-difference gradient test（branch raw + local SO raw）  
- [ ] 標為 Phase 3 **最大演算法風險**

---

## 12. Warm start

`[planned]`

| emap 選擇 | Group branches | Local SO logits |
|-----------|----------------|-----------------|
| `MBIND k` | `P_BIND_k` 高，`P_SO` 低 | 可保留，但有效機率受 `P_SO` 抑制 |
| SO（`M`） | `P_SO` 高 | 用各 root 的 `M` 初始化 local logits |

**優先語意**：若同一 pair 同時出現相關 `M` 與 `MBIND`，以 **`MBIND` 為 group 的 hard selected branch**；對應 roots 上的 `M` 不得再解讀為「同時 hard-selected 的第二顆 cell」。需在 parser 定義並加測試。

---

## 13. Hard reconstruction

`[planned]` 順序：

1. 每個 `MapBindingGroup`：branch **argmax**。  
2. 若選 **BIND**：emit **一顆** FA/HA；連接**所有** output pins；**忽略**該 group roots 的 local SO argmax。  
3. 若選 **SO**：各 root 用自己的 local argmax；emit 各自 SO cell。  
4. 未入 group 的 roots：維持現有 reconstruction。

**禁止**：

- 兩 roots 先各自 one-hot 再事後拼 FA；  
- 只接 FA 的單一 output；  
- 對同一 BIND emit 兩顆 instances。

---

## 14. Literal / phase 規則

| 用途 | 規則 |
|------|------|
| Group identity / overlap | `node = lit >> 1`（去 phase） |
| Match root / fanin / PO driver | **完整 literal**（含 phase） |
| `ROLES` | 對齊 Liberty output pin 名（`CON`/`SN`）與 endpoint |
| emap vs `&nf` 內部 AND 編號 | PI 通常一致；**不要**假設兩邊所有 AND lit 編號相同（GIA vs AIG）。公平實驗應共用同一 `synth.aig` 檔案本身 |

---

## 15. 實作階段

### Phase 0 — mockturtle 驗證 `[completed]`

`mo_techmap`、CEC smoke、早期 GENLIB 實驗。見 [MOCKTURTLE.md](MOCKTURTLE.md)。

### Phase 1–2 — ABC emap + `emap -Y` `[completed]`

- emap 併入 `graduate-abc`  
- `-Y` / `-M 1..3`、真實 `nf_y_multi_v1`  
- `run_abc_emap_map.sh`、fair compare、CEC、root-overlap validator  
- Liberty→`asap7.genlib`

### Phase 3 — GradMap multi-output `[planned]`（目前焦點）

| 子階段 | 內容 | 完成條件（摘要） |
|--------|------|------------------|
| **3A** 格式確認 | grammar、parser dry-run、BIND/MBIND consistency、non-overlap、phase/role | validator + dry-run 報告 |
| **3B** Library + CPU graph | multi-output `MapCell`、`MapBinding`、`MapBindingGroup`、建圖、debug dump | **不訓練**即可 dump 圖統計 |
| **3C** Hard replay `[done]` | 只 replay `M`/`MBIND` → reconstruct → CEC；一 BIND 一 instance | `scripts/sh/hard_replay_emap_mog.sh`；adder 127 FA CEC pass |
| **3D** CPU soft model | group softmax、SO gating、area/cap once、per-output timing、**required 方案** | soft cost 與 extreme `P` 測試 |
| **3E** GPU | branch／binding tensors、effective P、CPU/GPU parity、gradient check | 數值對齊表 |
| **3F** Warm start + train | 初始化、hard checkpoint、CEC、Liberty STA／QoR | 可跑完整 train |
| **3G** Regression | SO-only ≡ 舊 GradMap；`P_BIND=1` ≡ emap hard；`&nf -Y`／GradSyn 不受影響 | CI smoke |

---

## 16. 驗證策略

### 16.1 已有 `[confirmed]`

| 測試 | 命令／產物 |
|------|------------|
| MOG root non-overlap | `./Nonescripts/py/validate_emap_mog_root_overlap.py output/fair_nf_emap_asap7genlib/emap` |
| CEC nf／emap vs synth | `./Nonescripts/sh/cec_fair_nf_emap.sh --parallel` → `cec_report.md` |
| Liberty STA QoR | `compare_nf_emap_map.sh`／fair 流程 → `compare_nf_emap.md` |

### 16.2 Phase 3 必須擴充 `[planned]`

1. **Parser**：malformed BIND、unknown cell、錯誤 fanin 數、缺 role、duplicate bind id、MBIND 無 selected BIND、overlapping pair。  
2. **Library**：role↔Liberty pin、input 順序、每 output 的 arcs、area／caps 只存一次。  
3. **Hard replay**：CEC、instance count、output 連線、phase。  
4. **Extreme P**：`P_SO=1`；單一 `P_BIND=1`；多 BIND 各自 one-hot。  
5. **CPU/GPU parity**：branch P、effective match P、area、load、arrival、slew、delay、loss。  
6. **Gradient**：branch raw 與 local SO raw 的 finite difference。  
7. **Regression**：SO-only benchmark、既有 GradMap smoke、`&nf -Y`、GradSyn、sequential wrapper（若現有 flow 涉及）。  
8. **QoR**：emap selected baseline、GradMap warm start、optimized；area／delay／ADP；FA/HA 選中數；critical-path 上 FA/HA 數。  
9. **SO pair compatibility**（對應第 7.3 節假設）。

---

## 17. 風險與限制

### 17.1 已降級／解決

| 舊風險 | 現況 |
|--------|------|
| emap 未併入 graduate-abc | ✅ 已併入 |
| `emap -Y` 未實作 | ✅ level 1–3 可用 |
| 僅 50-gate 測試 GENLIB | ✅ 可改用 Liberty 衍生 `asap7.genlib`（腳本預設仍需注意） |

### 17.2 現行主要風險

1. **`[open]` Binding accumulated-weight／required 語意未定案**（§11）。  
2. Factorized SO branch 的 **candidate compatibility** 假設未驗證。  
3. Multi-output libcell **output-role／timing-arc** 與 GENLIB／Verilog 對齊。  
4. Literal **phase** vs base-node **group identity** 混用錯誤。  
5. Gradient starvation：`P_SO` 或 `P_BIND` 過早塌縮。  
6. Warm start 過強 → branch 無法探索。  
7. Soft cost 與 hard reconstructed netlist 不一致。  
8. 未來若出現 **overlapping root pairs**，現有「一 node 一 group」模型需擴充。  
9. GENLIB 與 Liberty **即使同源**，emap 內建 delay 仍可能與 GradMap Liberty LUT 不同——emap 僅作 candidate／warm-start provider。

---

## 18. 檔案與命令速查

### 18.1 原始碼

| 用途 | 路徑 |
|------|------|
| emap | `third_party/GRADUATE/third_party/abc/abc/src/map/emap/` |
| GradMap map 核心 | `third_party/GRADUATE/src/map/`、`include/graduate/map/` |
| GradMap ABC 命令 | `third_party/GRADUATE/src/abc/abc_commands.cpp` |

### 18.2 函式庫

| 檔案 | 用途 |
|------|------|
| `…/gradmap_libs/asap7.lib` | `&nf` / Liberty STA |
| `…/gradmap_libs/asap7.genlib` | emap（由 `read_lib; write_genlib`） |
| `…/gradmap_libs/asap7_libcell_info.txt` | GradMap 現用（SO） |
| `…/gradmap_libs/asap7_libcell_info_v2_multi_output.txt` | FA/HA libcell（GradMap **尚未**載入） |

### 18.3 腳本

| 腳本 | 用途 |
|------|------|
| `scripts/sh/run_abc_emap_map.sh` | 合成 + `emap -Y` |
| `scripts/abc/abc_emap_map.abc` | 上述 ABC 模板 |
| `scripts/sh/run_fair_nf_emap_compare.sh` | 共用 AIG：`&nf -Y` vs `emap -Y` + STA |
| `scripts/sh/cec_fair_nf_emap.sh` | 既有 `.v` vs `synth.aig` CEC |
| `scripts/py/merge_emap_twins.py` | FA/HA twin Verilog 合併 |
| `scripts/py/validate_emap_mog_root_overlap.py` | MOG root-pair matching |
| `scripts/py/generate_libcell_info_v2_multi_output.py` | 產生 multi-output libcell |

### 18.4 常用命令

```bash
# emap dump (level 3)
./Nonescripts/sh/run_abc_emap_map.sh --cases "adder" --dump-level 3 \
  --genlib third_party/GRADUATE/third_party/gradmap_libs/asap7.genlib

# root-pair invariant
./Nonescripts/py/validate_emap_mog_root_overlap.py output/fair_nf_emap_asap7genlib/emap

# CEC existing netlists
./Nonescripts/sh/cec_fair_nf_emap.sh --root output/fair_nf_emap_asap7genlib --parallel
```

### 18.5 FA/HA libcell 摘要 `[confirmed]`

| Cell | Area | Inputs | Outputs |
|------|------|--------|---------|
| `FAx1_ASAP7_75t_R` | 0.20412 | A, B, CI | CON, SN |
| `HAxp5_ASAP7_75t_R` | 0.13122 | A, B | CON, SN |

（`asap7_libcell_info_v2_multi_output.txt`；各 output 有獨立 timing arcs。）

---

## 19. 一句話總結

**ABC-native `emap -Y` 已能穩定提供含 FA/HA 的 `nf_y_multi` 候選與 warm start；GradMap 下一步不是列舉所有 `Ai×Bj`，而是在「不重疊的 root-pair groups」上做 factorized 的 `{SO | BIND_*}` 決策，並在 physical binding 上只計一次 area／input cap、在各 output pin 上分開做 Liberty timing——其中 binding 的 `required`／accumulated 語意仍是最大的 open design question。**
