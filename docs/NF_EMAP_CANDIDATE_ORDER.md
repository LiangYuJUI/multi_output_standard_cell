# `&nf -Y` 與 `emap -Y` 候選枚舉／Dump 順序

本文件說明 ABC **`&nf -Y`** 與 **`emap -Y`**（含 `-M 1|2|3`）如何**枚舉**與**寫出** match 候選，以及該順序對 GradMap 的意義。

> **結論先講**：兩邊 dump 的候選順序**都不是依 area／delay 排序的「最佳解列表」**，而是 **cut 枚舉順序 × library match 展開順序**。  
> GradMap 對同一 `root_lit` 的多行候選做 per-root softmax；**檔內先後順序會變成群組內 index 順序**，但訓練時 logit 可學習，warm-start 另有 `M`／`MBIND` 標記。

> **相關文件**：[GRADMAP.md](GRADMAP.md)、[ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md)、[GRADUATE.md](GRADUATE.md)、[SCRIPTS.md](SCRIPTS.md)

**程式錨點**（GRADUATE bundled ABC）：

| 路徑 | 內容 |
|------|------|
| `third_party/.../abc/src/aig/gia/giaNf.c` | `&nf` cut／match；`Nf_ManDumpMatchesCovers`（`-Y`） |
| `third_party/.../abc/src/map/emap/emapCore.c` | `emap` cut／MOG；`Emap_ManDumpMatches`（`-Y`） |

---

## 目錄

1. [共同語意](#1-共同語意)
2. [`&nf -Y` 枚舉與寫出順序](#2-nf--y-枚舉與寫出順序)
3. [`emap -Y` 枚舉與寫出順序](#3-emap--y-枚舉與寫出順序)
4. [對照表](#4-對照表)
5. [為何 emap M3 遠大於 nf](#5-為何-emap-m3-遠大於-nf)
6. [對 GradMap 的影響](#6-對-gradmap-的影響)
7. [實測數字（fair ASAP7）](#7-實測數字fair-asap7)

---

## 1. 共同語意

兩邊都把技術映射問題寫成：

```text
root_literal  →  { cell, area, fanin_literals, … }
```

- **root literal**：`2 * node_id + phase`（ABC strash／GIA 同一套 lit 慣例）。
- **候選**：某個 cut（leaf 集合 + truth）配上 library 中能實現該 truth 的 cell（含 pin 映射／相位）。
- **選中解（warm start）**：另以 `M…`（與 emap 的 `MBIND`）寫在檔尾；**不是**把候選 list 的第一筆當選中。

重要區分：

| | 映射演算法內部「選 best」 | Dump 檔內「候選列」 |
|--|--|--|
| 目的 | area／delay 反覆改進 | 給 GradMap 當 softmax 選項池 |
| 排序 | 依成本比較更新 `Best` | **依枚舉巢狀迴圈**寫出 |
| 是否依 area 排 dump | — | **否**（兩邊皆然） |

---

## 2. `&nf -Y` 枚舉與寫出順序

實作：`Nf_ManDumpMatchesCovers`（`giaNf.c`）。Fair／GradMap 路徑使用的是這個 **帶 cover 節點** 的 `-Y` 格式（不是較舊的 `Nf_ManDumpMatches`）。

### 2.1 檔案大結構（無 section header）

依寫出先後：

1. **PI**：`lit input 0.00`
2. **所有 AND 的候選列**（主體；見下）
3. **PO**：`lit output 0.00 fanin_lit`
4. **選中 mapping**：`M{lit} cell area fanins…`

（舊版 dump 還可能含 `L{lit} level`；cover 版以候選＋`M` 為主。）

### 2.2 候選列巢狀順序

對每個 AND 節點 `iObj`（`Gia_ManForEachAnd`，**拓撲／物件 id 遞增**）：

```text
for phase n in {0, 1}:                    # 先正相、再反相
  for each cut in Nf_ObjCutSet(iObj):     # cut set 內順序（見 2.3）
    for each (GateId, Cfg) in vTt2Match[truth]:  # library match list（見 2.4）
      if polarity matches n:
        dedup by (cell_name + sorted fanin lits)  # 見 2.5
        emit: root cell area nFanins fanins… nCover cover_lits…
```

因此：**節點 id ↑ → 相位 0→1 → cut 在 set 內順序 → 該 truth 的 match list 順序**。  
**沒有**對同一 root 的候選再依 `area` 排序。

### 2.3 Cut set 如何形成／排序

- 預設：`nLutSize = 6`、`nCutNum = 16`（`Nf_ManSetDefaultPars`）。
- 合併 fanin cut 後，以 **`Nf_CutCompareArea`** 做插入排序（`Nf_SetSortByArea`）：  
  **Useless ↑ → Flow(area) ↑ → Delay ↑ → nLeaves ↑**。  
  超過 `nCutNum` 的較差 cut 被擠掉。
- Dump 時依 cut set **目前陣列順序**遍歷（已是 area-oriented 的 cut 優先序），但**每個 cut 展開出的多個 cell 仍不依 area 排**。

### 2.4 Library match list（`vTt2Match`）

- `Mio_CollectRootsNewDefault2` 收集 cell（大致依 GENLIB／函式庫順序）。
- 對每個 cell 做 pin permutation／phase 展開（`Nf_StoCreateGateMaches`），依序 `Vec_IntPush` 進該 truth 的 list。
- 預設 **`fPinPerm = 0`**：同一 `GateId`＋相同 pin phase 的重複配置會被丟掉（減少「同 gate 不同 pin 排列」）。
- Dump 時對 list 做 `Vec_IntForEachEntryDouble`：**先寫入的 match 先出現**。

### 2.5 Dedup（僅 cover 版 `-Y`）

對同一 `(root, phase)`，用字串 key：

```text
cell_name + "_" + fanin_lit（數值排序後串接）
```

已見過則跳過。因此 **nf 不會為「同一 cell、同一組 fanin（忽略 pin 順序）」寫兩行**；emap M3 則會（見下）。

### 2.6 選中 `M` 行順序

`Gia_ManForEachAnd` × phase；僅當 `Nf_ObjMapRefNum > 0` 時寫 `M`，內容來自 **`Nf_ObjMatchBest`**（演算法選中的 gate／cut），與候選列順序無關。

---

## 3. `emap -Y` 枚舉與寫出順序

實作：`Emap_ManDumpMatches`（`emapCore.c`）。

### 3.1 檔案大結構（`nf_y_multi_v1`）

依 **`-M` dump level** 決定是否出現某些區段；**區段出現順序固定**：

| 順序 | Section | Level |
|------|---------|-------|
| 1 | header（`format` / `dump_level` / …） | ≥1 |
| 2 | `# --- primary inputs ---` | ≥1 |
| 3 | `# --- SO candidates (cut x cell) ---` | **≥3** |
| 4 | `# --- MOG tuple candidates ---` | **≥2** |
| 5 | `# --- selected candidates ---` | ≥1 |
| 6 | `# --- multi-output bindings (selected) ---` | ≥1（有 twin 時） |
| 7 | `# --- primary outputs ---` | ≥1 |
| 8 | `# --- selected mapping (warm start) ---`（`M`／`MBIND`） | ≥1 |

注意：標成「Level 3」的 SO 區段在檔案裡寫在 **MOG 區段之前**（實作註解與寫檔順序如此）。

### 3.2 SO candidates（`-M 3`）巢狀順序

```text
Abc_AigForEachAnd(obj):                 # AND id 遞增
  for cut_index c = 0 .. nCuts-1:       # 該節點 Cuts[] 陣列序（見 3.3）
    if nLeaves < 2: skip
    for fCompl in {0, 1}:               # 先正、再反（對 cut truth）
      cells = Emap_LibFindFirst(nPins, truth) .. 連續同 (nPins,truth) 區塊
      for each Emap_Cell in that block: # 見 3.4
        exact_key = (root_lit, cell_name, ordered fanin_lits, cover)
        if key seen for this AND node: skip   # Phase 1 dump-time exact dedup
        emit: root_lit cell area nPins fanin_lits cover
```

**同樣沒有**依 cell area 對 dump 再排序。  
第一個出現的 exact key 保留；後續完全相同者跳過（deterministic）。

#### Phase 1：SO exact dump-time dedup

| 項目 | 行為 |
|------|------|
| 範圍 | **僅** `# --- SO candidates (cut x cell) ---`（`-M 3`） |
| exact key | `root_lit` + `cell_name` + **ordered** `fanin_lits`（含 phase）+ `cover` |
| 保留 | 不同 ordered pin mapping（例如 A=8,B=10 與 A=10,B=8）視為**不同**候選 |
| 不做 | nf-like sorted-fanin dedup（見 Phase 2）、top-K cut、改 mapping／MOG |
| CLI | `emap -D 1`（**預設**） |
| 驗證 | `scripts/py/validate_emap_so_exact_dedup.py --exact` |

#### Phase 2：SO nf-like pin-permutation dedup

| 項目 | 行為 |
|------|------|
| 範圍 | 同上，僅 SO candidates；**不**套用到 MOG／BIND／MBIND |
| nf-like key | `root_lit` + `cell_name` + **sorted** `fanin_lits`（保留 phase bit，勿 `>>1`）+ `cover` |
| 代表選擇 | ① 與 warm-start `M` **exact ordered fanins** 相同者優先；② 否則該 group **第一次**枚舉到的 permutation |
| 語意 | 忽略 SO **input pin 順序**差異；功能等價，但可能失去 pin-specific timing 選項 |
| GradMap | `find_match` 比對 **ordered** fanins，故 selected-first 保證 `M` 能命中 SO candidate |
| CLI | `emap -D 2`（`-D 0` = none／legacy；`-D 1` = exact） |
| verbose | `nf_groups` / `pinperm_removed` / `selected_overrides` |
| 驗證 | `validate_emap_so_exact_dedup.py --nf-like --check-selected` |

#### Phase 3：SO export-only top-K cuts

| 項目 | 行為 |
|------|------|
| 範圍 | 僅 SO candidates 展開前的 **per base-node cut 集合**；`EMAP_CUT_MAX=128` **不變** |
| CLI | `emap -K <num>`；**預設 0**＝不做 top-K（與 Phase 2 全 cuts 一致） |
| Protected | 僅 **selected SO** `Best[f]`（`pRefs>0`、非 INV、非 twin）所用的 `Best.Cut`。**不**把 MOG endpoint cuts 一律保護 |
| 規則 | `P`=protected 數。`P < K` → 再依 ranking 補 `K-P`；`P >= K` → 只輸出全部 protected（總數可 `>K`） |
| Ranking（export-only） | usable 優先 → 該 cut 上合法 SO cell 的 **best Flow** → **best Arr** → `nLeaves` ↑ → cut index ↑。成本用最終 leaf `Best`＋refs 重算（同 `Emap_NodeMatch` 公式），**不**改 mapper Best／MOG |
| 與 nf | 仿 `Nf_CutCompareArea`（usable → area/flow → delay → leaves → index）；emap **無** per-cut 快取 Flow／Delay，故以「該 cut 合法 SO matches 的 best Flow／Arr」近似，**非** nf 插入時的 cut 狀態 |
| Pipeline | top-K retained cuts → 展開 SO matches → exact dedup → nf-like dedup → selected-first |
| verbose | `nodes`／`internal_cuts`／`protected`／`overflow_nodes`（`P≥K`）／`retained`／`removed`／`retained_min/avg/max`／`selected_cut_ok/miss` |
| MOG／BIND／MBIND／Verilog | **不受影響**（僅 SO section 變小） |
| 建議腳本 | runners 預設 `--so-dedup nf-like --so-cut-topk 16`；emap 本體預設仍為 `-D 1 -K 0` |

此 dedup／top-K **只影響 exporter**，不改變 emap 內部 cut pool 或選中 mapping。

#### Phase 4：正式政策整合（腳本／validator／regression）

| 項目 | 行為 |
|------|------|
| 正式政策 | internal 128；export top-K **16**；nf-like；selected-first；MO BIND **semantic endpoint-order exact**（非 nf-like） |
| Script | `--so-dedup`／`--so-cut-topk`（預設 `nf-like`／`16`；可關） |
| Validator | `validate_emap_nf_y_multi.py --formal` |
| 量化 | `run_emap_so_policy_compare.sh`（政策 A–F） |
| Regression | `regression_emap_so_export.sh` |
| Match header | `# so_dedup`／`# so_cut_limit`／`# so_export_stats` |
| 目標 | 降低 match 檔大小、parser 時間、GPU memory、softmax duplicate bias |
| 代價 | SO pin-specific timing／cut diversity 下降；**不做** Liberty-aware perm top-K（未來） |
| 回退 | `--so-cut-topk 32` 或 `--so-dedup exact`／`none`；**不**改 MOG 掩蓋 SO 問題 |

#### MO BIND semantic endpoint-order dedup `[confirmed]`

| 項目 | 行為 |
|------|------|
| 範圍 | **僅** `-Y` exporter 的 MOG tuple／BIND 文字；`Emap_Tuples_t`／Best／Verilog **不變** |
| 合併 | `ROOTS`/`ROLES` **同步換序**但 role→root 相同 → 同一 physical candidate |
| 保留 | ordered `FANINS` 不同（如 `[2,5]` vs `[5,2]`）；真正 CON/SN 指派對調；literal phase；不同 cell |
| key | `cell` + ordered fanins + endpoints 依 **output role name** 排序的 `(role, root_lit)` + cover |
| selected-first | selected BIND（id `1..nBind`）先註冊；trial 撞 key → 不輸出（`selected_aliases`） |
| Header | `# mo_dedup: semantic-endpoint-order`；`# mo_dedup_stats: visited=… unique=… removed=…` |
| 預設 | **啟用**（lossless）；非 nf-like（**不** sort fanins） |
| 驗證 | `scripts/py/validate_emap_mog_semantic_dedup.py` |

**ctrl 範例**（HA on roots 193／174）：

| 修改前 | 修改後 |
|--------|--------|
| 4 BIND（2 fanin perms × 2 endpoint 列序） | **2 BIND**（僅 fanin perms） |
| BIND1 `ROOTS 193 174 ROLES CON SN FANINS 2 5` | 保留 |
| BIND3 `ROOTS 174 193 ROLES SN CON FANINS 2 5` | **刪除**（同 CON→193,SN→174） |
| BIND2／BIND4 對 `FANINS 5 2` | 同理縮成 1 筆 |

### 3.3 Cut 陣列順序

- `EMAP_CUT_MAX = 128`、`EMAP_LEAF_MAX = 6`。
- `Emap_NodeMergeCuts`：先 unit cut，再對 fanin0／fanin1 的 cut **雙重迴圈** merge；`Emap_CutInsert` **append**（或在滿時替換「葉數最多」的 cut）。
- Cut **leaf 本身**在 merge 時維持 **升序 id**（`Emap_CutMergeLeaves`）。
- Dump／match 時依 `Cuts[0..nCuts)` **插入先後**，**不像 nf 那樣對 cut 做 area 排序**。

### 3.4 Library cell 順序（含 pin permutation）

`Emap_LibPrepare`：

1. 遍歷 GENLIB 每個 gate；對 pin 做 **完整 permutation＋phase**（`Emap_LibPermute_rec`），每個配置成為一筆 `Emap_Cell_t`（不同 `PinToLeaf`／`PinPhase`／Truth）。
2. Twin gate（FA／HA）另建 `Emap_Mog_t`，不進入 SO cell 表。
3. **`qsort(pCells, Emap_CellCompare)`**：鍵為 **`(nPins ↑, Truth ↑)`**。  
   同一 `(nPins, Truth)` 區塊內，相對順序為 permute 產生順序（穩定與否依平台 `qsort`；**不以 area 為鍵**）。
4. Dump 用 `Emap_LibFindFirst` 二分找到區塊起點，再線性掃完同 truth 的所有 pin 配置 → **同一 cell 系列、不同 pin 排列會各寫一行**。

### 3.5 MOG tuple candidates（`-M ≥ 2`）

1. 收集所有「節點×相位×cut」（葉數 2–3）為 `Emap_PackEntry`。
2. **`qsort(Emap_PackEntryCompare)`**：`(nLeaves ↑, Truth ↑, Leaves[] 字典序)`。
3. 自 **大 index 往小** 掃，配對能組成 FA／HA 的另一 endpoint，`Emap_TuplesAdd` **append**。
4. Dump：`for t = 0 .. nSize-1` 依 **tuple 加入順序** 寫 endpoint 兩行 + `BIND`／`ROOTS`／`ROLES`／`FANINS`／`COVER`。

BIND id：選中 binding 先佔 `1..nBind`；候選 tuple 從 `nBind+1` 起編（`nextTrialBind`）。

Dump 時對 MOG tuple 做 **semantic endpoint-order exact dedup**（見上方 Phase 4 小節）；內部 `Emap_Tuples_t` 枚舉不變。

### 3.6 Selected／warm-start 順序

- **selected candidates**／**M／MBIND**：`Abc_AigForEachAnd` × phase；僅 `pRefs>0`。
- Twin：`Emap_DumpShouldEmitTwin`（兩側都用則 lit key 較小者寫；一側 unused 則用側必寫）。
- 選中內容來自 mapping 的 `Best[f]`，**不是** SO 區段的第一個候選。

---

## 4. 對照表

| 項目 | `&nf -Y` | `emap -Y`（M3） |
|------|----------|-----------------|
| 外層節點序 | GIA AND id ↑ | AIG AND id ↑ |
| 相位 | 每節點 `n=0` 再 `1` | SO：每 cut 上 `fCompl=0` 再 `1` |
| Cut 保留上限 | 預設 16／節點 | 最多 128／節點 |
| Cut 在 set 內序 | **area／flow／delay 插入排序** | **merge 插入先後**（滿則踢最大葉數） |
| Cell 展開 | truth→match list；預設抑制多數 pin-perm 重複 | **完整 pin-perm** 進 library；dump 時 **exact** dedup（同 root+cell+ordered fanins+cover） |
| 同 root 候選再排序 | **無**（area） | **無**（area） |
| Dedup | `cell + sorted fanins` | `-D 0/1/2`；`-K 0` 全 cuts；`-K N` export top-K（protected 算入 K）。MOG：**semantic endpoint-order**（非 sorted-fanin） |
| Multi-output | 無 | MOG section + selected `BIND`／`MBIND` |
| Cover 節點 | 有（`nCover` + lits） | SO 行尾固定 `0`（無 cover 列表） |
| Warm start | 檔尾 `M` | 檔尾 `M`／`MBIND` |

---

## 5. 為何 emap M3 遠大於 nf

體積主因是 **SO candidates**，不是 FA／HA：

| 因素 | 說明 |
|------|------|
| 更多 cut | emap 每節點可留到 128 個 cut；nf 預設 16 且依 area 擠掉較差 cut |
| 完整 pin permutation | emap 對同 gate 不同 pin 映射各寫一行；nf 預設 `fPinPerm=0` + dump-time dedup |
| Drive／variant 密度 | ASAP7 上同功能多 drive（AND2x2／x4／…）× pin-perm → 單 root 可數百行 |
| MOG | hyp 上等可到數十萬 `BIND`，但仍通常只佔檔案 **~1–5%**；**~95%+ 是 SO** |

因此「多出來的 HA／FA」**不是** M3≫nf 的主因；主因是 **SO cut×cell 枚舉密度**。細節與區段占比見對話／實驗紀錄；亦可對任一 `matches.nf_y_multi.txt` 依 `# --- … ---` 統計位元組。

> **Phase 1 註記**：emap SO matching 要求 `nPins == nLeaves`，因此在 ASAP7 實測上 exact duplicate 常為 **0**；dump-time exact dedup 仍會執行（`visited == emitted`），並保留所有 ordered pin permutation。

---

## 6. 對 GradMap 的影響

1. **Softmax 群組**：同一 `root_lit` 的列依 **檔案出現順序** 進入 `MapCircuit` 候選向量；**index 0 ≠ 最小 area**。
2. **勿假設「第一個候選＝emap／nf 的 best」**：best 只在 `M`／`MBIND`（與 selected candidates）標出。
3. **Hard replay** 只需要 selected mapping；解析整份 M3（含海量 SO）會極慢——驗證 warm-start 宜用 **`-M 1`**。
4. **訓練用 M3** 時，候選集合比 nf 大很多（同一 root 選項更多）；模型容量／記憶體需按此評估，且與 nf 的「選項序」**不可直接對齊比較**（枚舉策略不同）。
5. **MOG**：emap 額外提供 pair-level `BIND`；GradMap Phase 3 應在 root-pair group 上決策，而不是假設 SO list 已依成本排好。

---

## 7. 實測數字（fair ASAP7）

同一份 `synth.aig`（`output/fair_nf_emap_asap7genlib` vs `…_m3_20260711_162924`）：

**檔案大小（約）**

| | nf `*.txt` | emap L1 | emap M3 |
|--|------------|---------|---------|
| 合計 | ~636M | ~19M | ~11.5G |
| hyp | ~329M | ~11M | ~4.7G |

**adder 候選密度（SO／主體列）**

| | roots | 總列數 | 平均列／root |
|--|-------|--------|--------------|
| nf | 1784 | ~1.6e4 | ~8.7 |
| emap M3 SO | 1784 | ~2.4e5 | ~136 |

**emap M3 區段占比（例）**

| case | SO candidates | MOG tuples |
|------|---------------|------------|
| sin | ~99.7% | ~0.2% |
| hyp | ~97.7% | ~2.1% |
| adder | ~94.6% | ~5.1% |

**列順序直覺（adder）**

- nf 開頭常見：依節點前進，同一 root 先出現少數 gate（且已 dedup）。
- emap M3 SO 開頭常見：同一 root 連續多個 `AND2x*`，並出現 **fanin 對調** 的兩行（pin permutation）。

---

## 維護

若修改 `Nf_ManDumpMatchesCovers`／`Emap_ManDumpMatches`、cut limit、或 pin-perm 預設，請同步更新本文件與 [ABC_MOCKTURTLE_MULTI_OUTPUT.md](ABC_MOCKTURTLE_MULTI_OUTPUT.md) 中格式說明。
