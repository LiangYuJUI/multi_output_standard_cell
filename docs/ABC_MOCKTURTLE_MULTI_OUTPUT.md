# ABC Multi-Output Mapping 整合規劃

本文件說明在 **目前專案狀態** 下，如何以 **ABC-native `emap`**（`third_party/abc/src/map/emap/`）產生含 **multi-output binding** 的 match file，作為 GradMap 輸入；並保留 mockturtle `mo_techmap` 作為 Phase 0 驗證管線。

> **相關文件**：[GRADUATE.md](GRADUATE.md)、[GRADMAP.md](GRADMAP.md)、[MOCKTURTLE.md](MOCKTURTLE.md)、[SCRIPTS.md](SCRIPTS.md)、[ASAP7_MULTI_OUTPUT_CELLS.md](ASAP7_MULTI_OUTPUT_CELLS.md)、[GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md](GENERATE_LIBCELL_INFO_V2_MULTI_OUTPUT.md)

---

## 目錄

1. [現狀摘要](#現狀摘要)
2. [策略轉向：為何改走 ABC emap](#策略轉向為何改走-abc-emap)
3. [目標與非目標](#目標與非目標)
4. [整體架構](#整體架構)
5. [現階段可執行流程（Phase 0）](#現階段可執行流程phase-0)
6. [`&nf -Y` match file 語意回顧](#nf--y-match-file-語意回顧)
7. [Multi-Output 的核心問題](#multi-output-的核心問題)
8. [提議：`nf_y_multi` 擴充格式](#提議nf_y_multi-擴充格式)
9. [ABC emap match dump 實作規劃](#abc-emap-match-dump-實作規劃)
10. [ABC literal 對齊規則](#abc-literal-對齊規則)
11. [GradMap 擴充規劃](#gradmap-擴充規劃)
12. [實作階段路線圖](#實作階段路線圖)
13. [驗證策略](#驗證策略)
14. [風險與限制](#風險與限制)
15. [附錄：檔案與命令速查](#附錄檔案與命令速查)

---

## 現狀摘要

### 已有、可直接使用

| 元件 | 路徑 | 能力 |
|------|------|------|
| `graduate-abc` | `third_party/GRADUATE/build_abc_frontend/graduate-abc` | ABC 合成、`&nf`、`&nf -Y`、GradMap |
| balance flow | `scripts/run_abc_syn_map.sh --flow balance` | 產生 `&nf -Y` match + Verilog（**SO only**） |
| **ABC-native emap** | `third_party/GRADUATE/.../src/map/emap/`（已併入） | MOG multi-output mapping + **`emap -Y`** match dump |
| mockturtle `mo_techmap` | `build/mo_techmap` | 讀 `synth.aig` + GENLIB → mapped Verilog（驗證用） |
| multi-output libcell | `output/asap7_libcell_info_v2_multi_output.txt` | 含 FA/HA（**GradMap 尚未能讀**） |
| EPFL benchmarks | `third_party/benchmarks/EPFL/` | 透過 `data/epfl/*.yaml` 選取 |

### ABC 來源差異（重要）

| ABC tree | 路徑 | `emap` | `&nf -Y` | 目前腳本用？ |
|----------|------|--------|----------|--------------|
| **repo `third_party/abc`** | berkeley-abc + emap port | ✅ `emap [-amvh] [-Y] [-M]` | ❌ | 等價驗證 |
| **GRADUATE bundled ABC** (`emap-Y` branch) | `third_party/GRADUATE/third_party/abc/abc` | ✅ `emap -Y` | ✅ | ✅ `graduate-abc` |

### 尚未實作

| 項目 | 說明 |
|------|------|
| GradMap multi-output binding | 選擇單位仍是 per-root literal |
| `libcell_info_v2_multi_output` loader | `MapLibrary` 僅支援 single-output |
| GradMap `nf_y_multi` parser | 需讀 `BIND` / `MBIND` |

### 關鍵事實

```text
asap7.lib / GENLIB
  ├─ single-output cells  → &nf -Y + GradMap ✓
  └─ FA/HA (MOG twin gates) → ABC emap ✓（內部已有 TwinObj binding）
                              → &nf -Y 因 libcell 限制 ✗
                              → emap -Y match dump ✓（Phase 2a/2b）
                              → GradMap binding 訓練 ✗（Phase 3）
```

---

## 策略轉向：為何改走 ABC emap

先前規劃以 mockturtle `mo_match_exporter` 合併 `&nf -Y` + mockturtle emap 結果。改走 **ABC emap 直接產 match file** 的理由：

| 面向 | mockturtle 外掛 exporter | ABC emap 內建 dump |
|------|--------------------------|-------------------|
| MO binding 資料 | 需從 `block_network` 事後推斷 pairing | **已有** `TwinObj`/`TwinPhase`、`Emap_Tuple_t` |
| literal 對齊 | mockturtle node ↔ GIA lit（`aig_balance` 會破壞） | 同一 ABC session 內 `read_aiger; strash; emap` |
| 候選列舉 hook | 需 patch `emap.hpp`（5000+ 行 header） | 在 `emapCore.c` cut × cell / MOG tuple 迴圈加 dump |
| 參考實作 | 無 | 可對照 `giaNf.c` 的 `Nf_ManDumpMatchesCovers()` |
| 部署 | 額外 binary `mo_techmap` | 單一 `graduate-abc` |

mockturtle `mo_techmap` **保留為 Phase 0**：驗證 multi-output mapping QoR 與 CEC，不作為 match file 主路徑。

---

## 目標與非目標

### 目標

1. **短期（Phase 0）**：mockturtle `mo_techmap` 驗證 FA/HA mapping 與 area 收益（已完成 adder  smoke test）。
2. **中期（Phase 1–2）**：在 `graduate-abc` 內實作 `emap -Y <file>`，輸出 `nf_y_multi` match file（含 MO binding）。
3. **長期（Phase 3）**：GradMap binding-level 訓練，讓同一 FA/HA 出現在兩個 root 的候選透過 `bind_id` 聯合優化。

### 非目標（目前階段）

- 在 `graduate-abc` 內連結 mockturtle C++ library
- 1:1 複製 `&nf -Y` 的完整候選空間（emap 與 `&nf` cut 列舉不完全相同）
- 一次完成所有 AOI/OAI multi-output（ASAP7 庫僅 FA/HA 為 true multi-output）

---

## 整體架構

### 目標管線（ABC emap 主路徑）

```text
  design.aig
       │
       ▼
┌──────────────────────────┐
│ graduate-abc             │
│  balance synth           │
│  write_aiger synth.aig   │  ← 單一 AIG 真相來源
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ graduate-abc（同 binary） │
│  read_aiger synth.aig    │
│  strash                  │
│  read_genlib <mo.genlib> │
│  emap -Y matches.txt     │  ← 待實作：SO + MO 候選 + MBIND
│  write_verilog mapped.v  │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────┐
│ graduate-abc gradmap     │  ← Phase 3：nf_y_multi parser
│  binding-aware training  │
└────────────┬─────────────┘
             ▼
       mapped Verilog
```

### 候選來源（單一 mapper，不再混合 `&nf -Y`）

```text
emap -Y matches.nf_y_multi.txt
  ├─ SO 候選：Emap_NodeMatch 的 cut × Emap_Cell（類 &nf -Y per-root 行）
  ├─ MO 候選：Emap_ManPackMogs / Emap_Tuple_t 試过的 MOG（兩 root 各一行 + bind_id）
  ├─ M  記錄：SO 已選 mapping（TwinObj < 0 的 node）
  └─ MBIND：MO 已選 binding（TwinObj 配對）
```

可選 **L1+ 混合模式**：`emap -Y` 同時讀取既有 `&nf -Y` 檔合併 SO 候選（當 emap SO 列舉不如 `&nf` 完整時）。

### Phase 0 驗證管線（mockturtle，保留）

```text
graduate-abc（合成）→ synth.aig
mo_techmap（mockturtle emap）→ *_mo_mapped.v
graduate-abc cec
```

見 [`SCRIPTS.md`](SCRIPTS.md) 的 `run_abc_mockturtle_map.sh`。

---

## 現階段可執行流程（Phase 0）

> 腳本細節見 [`SCRIPTS.md`](SCRIPTS.md)。以下為 **mockturtle 驗證管線**；ABC emap match dump 完成後改為 `run_abc_emap_map.sh`（Phase 2）。

### 一鍵管線

```bash
cd ~/research/multi_output_standard_cell
./scripts/run_abc_mockturtle_map.sh --build-mo-techmap --cases adder --cec
```

### 手動 balance 合成（與 emap 管線共用 synth.aig）

```bash
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read ../benchmarks/EPFL/arithmetic/adder.aig; st; \
   read_lib third_party/gradmap_libs/asap7.lib; \
   &get; &if -y -K 6; &put; balance; rewrite; refactor; balance; \
   rewrite; rewrite -z; balance; refactor -z; rewrite -z; balance; \
   &get; &deepsyn -T 120; strash; \
   write_aiger /path/to/synth.aig; ps"
```

### mockturtle mapping（驗證用）

```bash
./build/mo_techmap \
  --aig output/.../synth.aig \
  --genlib third_party/mockturtle/experiments/cell_libraries/multioutput.genlib \
  --out output/.../adder_mo_mapped.v \
  --stats output/.../stats.txt
```

---

## `&nf -Y` match file 語意回顧

現有 GradMap 消費的格式（見 `third_party/GRADUATE/docs/gradmap_refactor.md`）：

| 類型 | 格式 | 範例 |
|------|------|------|
| PI | `<lit> input <area>` | `2 input 0.00` |
| 候選 | `<root_lit> <cell> <area> <n_fanins> <fanins...> <n_cover> <cover...>` | `16 AND2x2... 2 8 10 0` |
| PO | `<po_lit> output <area> <driver_lit>` | `198 output 0.00 140` |
| 已選 | `M<root_lit> <cell> <area> <fanins...>` | `M16 AND2x2... 0.09 8 10` |

參考實例：`output/abc_syn_map_20260709_201016/ctrl/ctrl.txt`。

`emap -Y` 輸出的 **SO 區段**應與上述相容；**MO 區段**使用下方 `nf_y_multi` 擴充。

---

## Multi-Output 的核心問題

### 一個 cell、兩個 root

以 `FAx1_ASAP7_75t_R` 為例：

| 輸出 pin | 在 AIG 中 |
|----------|-----------|
| `CON` | root literal `lit_c` |
| `SN` | root literal `lit_s` |

現有 GradMap 把 `lit_c`、`lit_s` 當 **兩個獨立 softmax 群組** → 可能各選一次 FAx1、面積算兩次。

### ABC emap 已解決 mapping 層的 binding

`Emap_MogApply()` 在套用 MOG 時設定：

```c
pBest0->TwinObj = pEntry1->ObjId;
pBest0->TwinPhase = pEntry1->Phase;
pBest1->TwinObj = pEntry0->ObjId;
pBest1->TwinPhase = pEntry0->Phase;
pBest0->Flow = pBest1->Flow = pMog->Area;  // 面積只計一次
```

match dump 的任務是把这个 **已有的 binding 語意** 寫進檔案，供 GradMap 訓練時重用。

### 候選如何出現在兩個 root 下

```text
lit_c  FAx1_ASAP7_75t_R  0.20412  3  lit_A lit_B lit_CI  0  BIND:42
lit_s  FAx1_ASAP7_75t_R  0.20412  3  lit_A lit_B lit_CI  0  BIND:42

lit_c  AND3x1...  ...   # SO 分解替代，僅 lit_c
lit_s  XOR2x2...  ...   # SO 分解替代，僅 lit_s

MBIND 42 FAx1_ASAP7_75t_R 0.20412 lit_A lit_B lit_CI
```

---

## 提議：`nf_y_multi` 擴充格式

### 檔頭

```text
# format: nf_y_multi_v1
# source_aig: /path/to/synth.aig
# genlib: multioutput.genlib
# libcell: asap7_libcell_info_v2_multi_output.txt
# mo_mapper: abc_emap
# literal_space: abc_strash
```

### 方案 A（推薦）：候選行 + BIND 區塊

```text
# --- candidates (nf_y v1 compatible) ---
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

### 方案 B：候選行尾 `bind_id`

```text
<root_lit> <cell> <area> <n_leaves> <leaves...> <n_cover> <cover...> <bind_id>
```

- `bind_id = 0`：SO 候選
- `bind_id > 0`：MO binding 成員；同一 id 跨多個 `root_lit`

### `M` / `MBIND` warm start

| 記錄 | 用途 |
|------|------|
| `M<root_lit> ...` | SO 已選（`TwinObj < 0`） |
| `MBIND <id> ...` | MO 已選 binding（`TwinObj >= 0` 配對） |

---

## ABC emap match dump 實作規劃

### Step 0：合併 emap 進 GRADUATE ABC

```text
third_party/abc/src/map/emap/
  emap.c
  emapCore.c
  emap.h
  module.make
        │
        ▼ copy / merge
third_party/GRADUATE/third_party/abc/abc/src/map/emap/
        │
        ▼ register
mainInit.c: Emap_Init()
module.make: SRC += src/map/emap/...
```

驗證：`graduate-abc -c "read_genlib ...; emap -h"` 可顯示 help。

### Step 1：命令列擴充

修改 `third_party/.../emap/emap.c` 的 `Emap_Command()`：

```text
usage: emap [-amvh] [-Y <match.txt>] [-M <level>]

  -Y file   dump nf_y_multi match file（新增）
  -M level  候選列舉級別：1=warm start only, 2=+MOG trials, 3=+full SO cuts（新增）
  -a -m -v -h  （既有）
```

在 `Emap_ManMapAigStructural()` 末尾、回傳 `pNtkNew` 前，若 `YFile != NULL` 呼叫 `Emap_ManDumpMatches()`。

### Step 2：新增 `Emap_ManDumpMatches()`（`emapCore.c`）

參考 `giaNf.c` 的 `Nf_ManDumpMatchesCovers()` 結構：

```c
void Emap_ManDumpMatches(
    Abc_Ntk_t * pNtk,
    Emap_Obj_t * pMaps,
    Emap_Lib_t * pLib,
    Emap_Tuples_t * pTuples,   // 可選：MOG trial 記錄
    char * pYFile,
    int nDumpLevel,
    int fVerbose );
```

#### 2.1 寫檔頭與 PI/PO

```c
// PI
Abc_NtkForEachPi( pNtk, pObj, i )
    fprintf( pFile, "%d input 0.00\n", Emap_ObjToLit(pObj, 0) );

// PO
Abc_NtkForEachPo( pNtk, pObj, i )
    fprintf( pFile, "%d output 0.00 %d\n",
        Emap_ObjToLit(pObj, 0), Emap_ObjToLit(Abc_ObjFanin0(pObj), Abc_ObjFaninC0(pObj)) );
```

#### 2.2 SO 候選（`-M >= 3`）

對每個 AND node `ObjId`、phase `p ∈ {0,1}`，遍歷 `pMaps[ObjId].Cuts[]`：

```c
// 對每個 cut × Emap_LibFindFirst 匹配的 Emap_Cell
fprintf( pFile, "%d %s %.5f %d", root_lit, cell_name, area, n_fanins );
for ( k = 0; k < n_fanins; k++ )
    fprintf( pFile, " %d", Emap_LeafToLit(pNtk, pMaps, cut, pin_k) );
fprintf( pFile, " 0\n" );   // n_cover = 0（L1 可省略 cover 列舉）
```

邏輯對照 `Emap_NodeMatch()` + `Nf_ManDumpMatchesCovers()` 的候選行格式。

#### 2.3 MO 候選（`-M >= 2`）

遍歷 MOG packing / exact trial 期間的 `Emap_Tuple_t`：

```c
// 對 tuple (Obj0, Phase0, Obj1, Phase1, Mog, fSwap)
int bind_id = ...;
char * cell_name = Emap_MogCellName(pLib, pMog);  // 見下方命名規則
int root0 = Emap_ObjPhaseToLit(Obj0, Phase0);
int root1 = Emap_ObjPhaseToLit(Obj1, Phase1);
// 兩條候選行（方案 B）或 BIND 區塊（方案 A）
```

資料來源：

| 來源 | 用途 |
|------|------|
| `Emap_ManPackMogs()` | area-oriented MOG 候選 |
| `Emap_ManRecoverMogsExact*()` | exact recovery 試过的 tuple |
| `pMaps[].Best[].TwinObj >= 0` | 已選 MBIND |

#### 2.4 Warm start：`M` 與 `MBIND`

```c
Abc_AigForEachAnd( pNtk, pObj, i ) {
    for ( p = 0; p < 2; p++ ) {
        Emap_Best_t * b = &pMaps[i].Best[p];
        if ( !Emap_BestIsUsed(pRefs, i, p) ) continue;
        if ( b->TwinObj >= 0 && i > b->TwinObj ) continue;  // 每對只寫一次 MBIND
        if ( b->TwinObj >= 0 )
            Emap_DumpMBind(...);
        else
            Emap_DumpM(...);
    }
}
```

### Step 3：literal 輔助函式

```c
static inline int Emap_ObjPhaseToLit( int ObjId, int Phase )
{
    return Abc_Var2Lit( ObjId, Phase );  // 2*ObjId + Phase
}

static int Emap_LeafToLit( Abc_Ntk_t * pNtk, Emap_Obj_t * pMaps,
                           Emap_Cut_t * pCut, int pin, int pin_phase );
```

### Step 4：MOG cell 命名

ABC emap 內部用 GENLIB **twin gate**（`Mio_GateReadTwin`）：`pGate0`/`pGate1` 為同一物理 cell 的兩個輸出。

Exporter 規則：

```text
physical_name = Mio_GateReadName(pGate0) 去掉輸出後綴
或讀 twin 的 base cell 名（與 asap7.lib / libcell_info 對齊）

ROLES = Mio_GateReadOutName(pGate0), Mio_GateReadOutName(pGate1)
  → 例如 CON, SN
```

需維護 **GENLIB twin 名 → Liberty 物理 cell 名** 對照表（可放在 `scripts/` 或 emap dump 時查 `asap7.lib`）。

### Step 5：分級實作（`-M` level）

| Level | SO 候選 | MO 候選 | MBIND/M | 用途 |
|-------|---------|---------|---------|------|
| **1** | 僅已選 | 僅已選 | ✅ | 最快驗證 GradMap binding 路徑 |
| **2** | 僅已選 | MOG trial 列舉 | ✅ | 有 MO 替代可優化 |
| **3** | cut × cell 完整 | MOG trial 列舉 | ✅ | 接近 `&nf -Y` 覆蓋率 |

**建議順序**：Level 1 → GradMap parser → Level 2 → Level 3。

### Step 6：整合腳本（規劃）

`scripts/run_abc_emap_map.sh`：

```bash
# Phase 2 目標用法
./scripts/run_abc_emap_map.sh --cases adder --dump-level 1

# 內部等效 ABC 命令（render 後）
read_aiger synth.aig
strash
read_genlib third_party/mockturtle/experiments/cell_libraries/multioutput.genlib
emap -a -m -Y output/.../matches.nf_y_multi.txt -M 1
write_verilog output/.../adder_emap_mapped.v
```

### 修改檔案清單

| 檔案 | 變更 |
|------|------|
| `third_party/GRADUATE/third_party/abc/abc/src/map/emap/*` | 從 repo `third_party/abc` 合併 |
| `.../emap/emap.h` | 宣告 `Emap_ManDumpMatches`、dump params |
| `.../emap/emap.c` | `-Y`、`-M` 參數解析 |
| `.../emap/emapCore.c` | `Emap_ManDumpMatches` 主體；在 tuple 迴圈加 hook |
| `.../base/main/mainInit.c` | `Emap_Init`（合併時確認） |
| `scripts/abc_emap_map.abc` | ABC 模板（新建） |
| `scripts/run_abc_emap_map.sh` | 批次 runner（新建） |
| `docs/SCRIPTS.md` | 登錄新腳本 |

---

## ABC literal 對齊規則

### 問題

| 流程 | Network | literal 空間 |
|------|---------|--------------|
| `&nf -Y`（現有） | GIA（`&get` 後） | `Abc_Var2Lit(gia_obj, phase)` |
| `emap`（規劃） | strashed `Abc_Ntk` | `Abc_Var2Lit(abc_obj_id, phase)` |

同一 `synth.aig` 讀入後，**GIA obj id 與 strash ObjId 不一定相同**。

### 規則 1：單一 AIG 真相來源

```text
graduate-abc balance synth → write_aiger synth.aig
                              ↓
         emap / gradmap 都從此檔開始
```

### 規則 2：短期——統一用 strash 空間

GradMap 讀取 emap match 時，**不使用 `&get`**，改為：

```text
read_aiger synth.aig
strash          # 與 emap dump 相同拓撲
gradmap -match matches.nf_y_multi.txt -match-format nf_y_multi ...
```

match 檔頭標註 `literal_space: abc_strash`。

### 規則 3：中期——GIA literal bridge

在 `read_aiger; &get; strash` 同一 session 建立 `Vec_Int` 對照表：

```c
// Gia_ObjId → Abc_ObjId（或反查）
// 寫檔時輸出 gia_lit；sidecar: literal_map.tsv
```

供 GradMap 維持 `&get` + GIA 流程時使用。實作可參考 ABC `Abc_NtkFromAig()` 內部 obj 對應。

### 規則 4：編碼

```text
lit = 2 * obj_id + phase
node  = lit >> 1
phase = lit & 1
```

與 `graduate::map::map_literal_from_abc_lit()` 一致。

---

## GradMap 擴充規劃

（與先前規劃相同，僅資料來源改為 `abc_emap`。）

### 1. `MapLibrary`：載入 `libcell_info_v2_multi_output`

### 2. `MapBinding` 資料結構

```text
MapBinding {
  bind_id, cell_name, fanins,
  roots: [lit_c, lit_s], roles: [CON, SN]
}
```

### 3. 機率模型：per-binding softmax

```text
softmax_group(binding=42) = { FAx1@fanins, XOR+AND_decomp, ... }
選中 FAx1 → lit_c 與 lit_s 同時生效；area 只計一次
```

### 4. `gradmap` 命令

```text
gradmap -match matches.nf_y_multi.txt -match-format nf_y_multi \
        -libcell output/asap7_libcell_info_v2_multi_output.txt \
        -skip-nf-y
```

---

## 實作階段路線圖

```text
Phase 0  [已完成]    mockturtle mo_techmap 驗證管線 + SCRIPTS.md
Phase 1  [1–2 週]    合併 ABC emap → graduate-abc；emap 可 map（無 -Y）
Phase 2a [1–2 週]    emap -Y -M 1：MBIND/M + BIND 區塊（warm start only）
Phase 2b [2–3 週]    emap -Y -M 2/3：MOG/SO 候選列舉；run_abc_emap_map.sh
Phase 3  [4–8 週]    GradMap：nf_y_multi parser + binding 訓練 + libcell MO
Phase 4  [可選]      GIA literal bridge；與 &nf -Y SO 候選合併
```

### Phase 1 檢查清單

- [x] `src/map/emap/` 併入 GRADUATE ABC（branch `emap-Y`）
- [x] `graduate-abc` 重建成功
- [x] `read_aiger; strash; read_genlib; emap -a -v` 在 adder 可跑
- [x] mapped Verilog `cec` 通過

### Phase 2a 檢查清單

- [x] `emap -Y <file>` 參數
- [x] `Emap_ManDumpMatches()` Level 1
- [x] 輸出含 `BIND`/`MBIND`（FA/HA 配對；adder 128 MBIND）
- [ ] GradMap parser dry-run（可先寫 `scripts/validate_nf_y_multi.py`）

### Phase 2b 檢查清單

- [x] MOG tuple 候選 dump（`-M 2`）
- [x] SO cut 候選 dump（`-M 3`）
- [x] `scripts/run_abc_emap_map.sh`
- [x] `docs/SCRIPTS.md` 更新

### Phase 3 檢查清單

- [ ] `MapLibrary` 讀取 multi-output libcell
- [ ] `nf_y_multi` parser + binding softmax
- [ ] `gradmap -skip-nf-y` 端到端

---

## 驗證策略

| 檢查 | 方法 |
|------|------|
| emap mapping 正確 | `write_verilog` + `cec` vs `synth.aig` |
| MO binding 在檔案中 | 同一 `bind_id` 出現在兩個 root |
| MBIND 與 mapped netlist 一致 | 比對 `TwinObj` 配對 |
| GradMap 可解析 | parser dry-run |
| QoR | compare `&nf` SO vs `emap -m` MO on adder |

回歸：`run_abc_syn_map.sh --flow balance` 產物不變。

---

## 風險與限制

| 風險 | 影響 | 緩解 |
|------|------|------|
| GIA vs strash literal 不一致 | GradMap 讀錯 match | Phase 2 統一 strash；Phase 4 bridge |
| GENLIB twin 名 ≠ Liberty 名 | parser 找不到 cell | 命名對照表；dump 時用物理 cell 名 |
| emap SO 候選少於 `&nf -Y` | GradMap SO QoR 下降 | `-M 3` 或 L1+ 合併 `&nf -Y` SO 段 |
| 僅 2 個 MO cell（FA/HA） | 收益限於算術 | 符合研究範圍 |
| 合併 ABC fork 衝突 | build 失敗 | 以小 patch 方式移植 `emap/` 目錄 |

---

## 附錄：檔案與命令速查

### 現有命令

```bash
# SO match + Verilog（balance + &nf -Y）
./scripts/run_abc_syn_map.sh --flow balance --scale tiny

# mockturtle 驗證（Phase 0）
./scripts/run_abc_mockturtle_map.sh --cases adder --cec
```

### 規劃中命令

```bash
# Phase 1：確認 emap 可 map
cd third_party/GRADUATE
./build_abc_frontend/graduate-abc -c \
  "read_aiger ../benchmarks/EPFL/arithmetic/adder.aig; strash; \
   read_genlib ../mockturtle/experiments/cell_libraries/multioutput.genlib; \
   emap -amv; write_verilog /tmp/adder_emap.v; ps"

# Phase 2：emap match dump
./build_abc_frontend/graduate-abc -c \
  "read_aiger output/synth/adder.aig; strash; \
   read_genlib .../multioutput.genlib; \
   emap -am -Y output/matches.nf_y_multi.txt -M 1; \
   write_verilog output/adder_emap_mapped.v"

# Phase 3：GradMap
./build_abc_frontend/graduate-abc -c \
  "read_aiger output/synth/adder.aig; strash; \
   gradmap -skip-nf-y -match output/matches.nf_y_multi.txt \
           -libcell ../output/asap7_libcell_info_v2_multi_output.txt"
```

### 相關原始碼

| 檔案 | 用途 |
|------|------|
| `third_party/abc/src/map/emap/emapCore.c` | MOG binding（`TwinObj`）、**待加 dump** |
| `third_party/abc/src/map/emap/emap.c` | `emap` 命令入口 |
| `third_party/GRADUATE/.../gia/giaNf.c` | `Nf_ManDumpMatchesCovers()` 參考 |
| `third_party/GRADUATE/src/map/nf_y_parser.cpp` | 現有 SO match 解析 |
| `src/mo_techmap.cpp` | Phase 0 mockturtle 驗證 |
| `scripts/generate_libcell_info_v2_multi_output.py` | MO libcell |

---

## 一句話總結

**主路徑改為**：把 repo `third_party/abc` 的 **ABC-native emap** 併入 `graduate-abc`，新增 **`emap -Y`** 輸出 `nf_y_multi` match file（利用既有 `TwinObj` MO binding），再擴充 GradMap 做 binding-level 訓練。mockturtle `mo_techmap` 保留為 Phase 0 QoR/CEC 驗證，不再作為 match file 的主要來源。
