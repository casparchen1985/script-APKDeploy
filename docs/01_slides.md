---
theme: default
title: APK Deploy Toolkit
info: |
  Android RD 內部技術分享 — 一鍵把 APK 同步到全機種 repo
class: text-center
transition: slide-left
mdc: true
layout: cover
---

# APK Deploy Toolkit

**Android RD 內部技術分享**

一鍵把 APK 同步到全機種 repo  
並完成 Android.mk 更新、commit、push、驗證

報告人：Caspar.Chen  
日期：2026-05-oo

---

## Agenda

1. **痛點** — 過去手動部署遇到什麼問題？
2. **解法概覽** — 工具能做什麼、不做什麼
3. **架構與流程** — 三個腳本 × 設定檔分離
4. **Demo** — dry-run、批次、驗證、含 libs 行為與 .mk 維護
5. **設定維護** — 新增 Model、新增 Author
6. **資源指引** — 文件、log

---

## 1. 痛點：手動部署一支 APK 要做的事

每次 release 一支 APK 到 N 個機種，RD 必須：

1. SSH 進 upload server，逐一 `cd` 進到每個 model 存放 apk 的位置
2. `git checkout <branch>` → `git clean -df` → `git pull origin <branch>`，將 server 狀態同步到最新版
3. 把 APK 複製到 `vendor/cipherlab/<APP>/`
4. **(含 JNI libs 時)** 把需要的 libs 檔案複製到 `vendor/cipherlab/<APP>/libs/<ABI>/`  
5. 修改 `Android.mk`：  
`LOCAL_SRC_FILES` 檔名資訊  
 `LOCAL_TARGET_CPU_ABI` 與 `LOCAL_PREBUILT_JNI_LIBS` Lib 檔案設定
6. `git add` → `git commit --author=...` → `git push`
7. 機種 × app 越多，**漏改或打錯 author、commit message 不一致、libs 清單漏寫** 的機率就越高

> 12 個 model × 一支 APK ≈ **60+ 個指令**，再加上 libs 的操作，指令量瞬間爆增且事後難 review

---

## 2. 解法概覽

一份指令、一次執行，完成：

- 多機種 **平行邏輯、序列執行**（任一機種失敗不影響其他）
- 自動更新 Android.mk  
`LOCAL_SRC_FILES` 檔名  
`LOCAL_TARGET_CPU_ABI`* / `LOCAL_PREBUILT_JNI_LIBS`*
- Git commit 自動帶入 `--author` 與標準化 message
- **部署後自動驗證**：
  - APK MD5 / Android.mk content* / commit author name / email / message  
  *LOCAL_SRC_FILES  
  *LOCAL_TARGET_CPU_ABI / LOCAL_PREBUILT_JNI_LIBS 清單 / 每支 libs 檔案 MD5
- 無失敗（SUCCESS + SKIPPED）→ staging APK 與 libs 都自動清除；任一失敗 → 全部保留供重跑

> 範疇外：**不**負責 build APK、**不**改 repo 的 git config、**不**做 code review

---

## 3. 架構：三個腳本 × 兩份設定檔

```
apk_deploy/
├── deploy_apk.sh              # 核心：單一 app × 多機種
├── batch_deploy.sh            # Wrapper：讀 XML 跑多個 task
├── verify_deploy.sh           # 只驗證，不部署（事後複查用）
├── config/
│   ├── devices.conf           # 機種 → repo 路徑
│   └── authors.conf           # RD → git author 資訊
├── toBeUploaded/              # APK + libs staging (無失敗即清除；SKIPPED 不阻擋)
├── logs/                      # 每次執行的時間戳記 log
└── deploy_plan.xml.template   # 批次計畫範本（複製為 deploy_plan.xml 後編輯）
```

**設計原則**：新增機種 / RD **只改設定檔**，腳本本身不動。

---

## 3.1 每台機種的執行流程

```
[0] git ls-remote origin <branch>     (預檢 remote 連線，純查詢)
       ↓
[1] git checkout <branch> → clean -fd → pull origin <branch>
       ↓
[1.5] SKIPPED 偵測（APK MD5 + libs MD5 + commit author/email/msg 全相符）
       ↓ 不符才繼續
[2] cp APK → vendor/cipherlab/<APP>/
       ↓
[3] cp libs → vendor/cipherlab/<APP>/libs/<ABI>/   (僅當 --libs)
    逐一根據 MD5 決定 [ Added ] / [Updated] / [Skipped]  
       ↓
[4] 更新 Android.mk（cp 全部結束後才動）
       LOCAL_SRC_FILES               ← APK 檔名
       LOCAL_TARGET_CPU_ABI          ← ABI 名稱       (libs)
       LOCAL_PREBUILT_JNI_LIBS       ← enumerate remote (libs)
       ↓
[5a] git add → git commit --author=...
[5b] git push origin <branch>              (push 與 commit 分開檢查)
       ↓
[6] 自動驗證（可 --no-verify 略過）— 純 APK 5 項，含 libs 8 項
```

機種三分類：**SUCCESS / SKIPPED / FAILED**，任一機種失敗不影響其他機種繼續部署。

> `<branch>` 由 `devices.conf` 控制：全域 `BRANCH` 或 `DEVICE_<NAME>_BRANCH` 覆寫。

---

## 3.2 Remote 連線異常處理（v1.0.4）

每個動 remote 的步驟（**[0] ls-remote / [1] pull / [5b] push**）都會**顯式檢查 exit code**：

| 失敗點 | local file 影響 | local commit 影響 | 行為 |
|---|---|---|---|
| **[0] ls-remote** 失敗 | 無（尚未動） | 無 | 立即跳過此機種，零殘留 |
| **[1] pull** 失敗 | 無（cp 尚未開始） | 無 | 跳過此機種 |
| **[5b] push** 失敗 | 已 cp（保留） | **已建立、不 rollback** | 印 RD 手動 push 提示並跳過此機種 |

</br>

> **為什麼要顯式檢查？** 主迴圈用 `deploy_device "${dev}" || rc=$?` 區分 SUCCESS/SKIPPED/FAILED 三類、不中斷整批，這個 `||` 會讓函式內 `set -e` 整段失效——必須手動 `|| { err; return 1; }`。

> **SSH timeout（避免 remote 死機讓腳本無限掛住）**：腳本開頭 `export GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"`。  
> 對所有走 ssh 的 git 操作生效（ls-remote / pull / push / fetch）。最壞情境上限約 **25 秒**（10s connect + 5s × 3 次 keepalive），超時後以非零 exit code 返回，該機種歸 FAILED。

---

## 3.2.1 Push 失敗時的 RD 提示

push 失敗時，**local commit 保留**（不 rollback），並印出可直接執行的補救指令（同步寫入 log）：

```
ERROR [rs38t] git push 失敗（exit code 非零）
ERROR [rs38t] 注意：local commit 已建立但未推送至 remote，請手動處理：
ERROR [rs38t]     Repo    : /home/app_dev/rs38t/titan_qssi13
ERROR [rs38t]     Branch  : master
ERROR [rs38t]     Hash    : a3f9c12
ERROR [rs38t]     Message : SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
ERROR [rs38t]     後續    : remote 恢復後執行 cd '/home/app_dev/rs38t/titan_qssi13' && git push origin master
```

> 設計理念：不 rollback 是為了保留 RD 已做完的工作；明確列印 hash + 訊息 + repo 路徑，讓 RD 在 remote 恢復後**一行貼回 terminal 就能完成 push**。

---

## 3.3 SKIPPED 偵測（重跑安全）

`git pull` 完成後（step 1.5），腳本比對 remote 現況決定是否要實際做事：

| 比對項目 | 來源 |
|---|---|
| APK 檔名 + MD5 | `<APK_DEST_DIR>/<APK_FILENAME>` |
| Libs MD5（有 --libs 時） | staging 內每個 `LIB_FILES` 對 remote `LIBS_REMOTE_DIR/<rel>` |
| **HEAD == origin/`<branch>`** | 確保 HEAD 已推送，避免 push-fail 重跑誤觸 SKIPPED |
| Commit author name + email | `git log -1` 比 **`--author` 經 authors.conf 查表後** 的 name + email |
| Commit message | `git log -1` 比 `--message` 參數 |

**5 項全相符 → return 2 → 該機種歸 SKIPPED**，跳過 step 2-6。

</br>

```
────────────────────────────────────────
  ⊘  [rk26s] SKIPPED — remote 已含相同部署
────────────────────────────────────────
  └─ APK MD5     : a3f9c12d8e4b7f2190ac56de83107b45
  └─ Commit hash : a3f9c12 (HEAD == origin/master)
  └─ Author      : Bob.Lin <Bob.Lin@cipherlab.com.tw>
  └─ Commit msg  : SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
  └─ Libs        : 5 檔 MD5 全相符
```

> **設計動機**：失敗重跑時，已部署成功的機種會被自動識別，**不會再次嘗試 commit 然後因「nothing to commit」失敗**，也不會誤標 FAILED。  
> **HEAD == origin/`<branch>` 這條的特殊用途**：v1.0.4 引入「push 失敗保留 local commit」後，純比對 local 屬性會誤把「commit 完但 push 失敗」的機種當成 SKIPPED——加上 HEAD 必須等於 remote tip 這條就能擋掉。

---

## 3.4 APK 保留策略

腳本由**檔名**自動判斷版號，決定是否覆蓋：

| 檔名範例 | 判定 | 行為 |
|---|---|---|
| `KMM_v1.2.3.apk` | 有版號 | 新舊版**共存**（保留歷史） |
| `KMM_1.2.3.apk` | 有版號 | 新舊版共存 |
| `KMM_20250513.apk` | 有版號 | 新舊版共存 |
| `KMM.apk` | 無版號 | **同名覆蓋** |

> 版號 pattern（至少兩段數字）：  
`_vX.Y` / `_vX.Y.Z` / `_X.Y` / `_X.Y.Z` /  
`_YYYYMMDD` / `_YYYYMMDDHHMMSS`  
> **任何情況都不會主動刪除 repo 內既有 APK。**

---

## 4. Demo 1 — 直接部署（dry-run）

```bash
# 1) RD 本機把 APK + libs 丟到 server（libs 必須在 toBeUploaded/ 之下）
scp -r ReaderService_CipherLab_V1_3_104.apk \
       ReaderService_Libs \
       app_dev@192.168.8.17:~/apk_deploy/toBeUploaded/

# 2) ssh 進 server 執行（先 --dry-run 確認）
ssh app_dev@192.168.8.17
cd ~/apk_deploy
./deploy_apk.sh \
  --app     ReaderService_CipherLab \
  --apk     ~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk \
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a \
  --author  Caspar \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs36s rs38t rk95u \
  --dry-run
```

> 純 APK 部署：拿掉 `--libs` 該行即可，scp 也只需上傳 APK，其餘參數結構不變。
Dry-run 印出**所有會執行的指令**但不動 repo，確認無誤再拿掉 `--dry-run`

---

## 4.1 Demo 1 — 預期輸出（節錄）

```
[05-20 14:30:22] ====== APK Deploy Summary ======
[05-20 14:30:22]   APP        : ReaderService_CipherLab
[05-20 14:30:22]   APK        : ReaderService_CipherLab_V1_3_104.apk
[05-20 14:30:22]   版號識別   : 有版號 → 保留舊版共存
[05-20 14:30:22]   Libs ABI   : arm64-v8a  (5 個檔案)
[05-20 14:30:22]   Author     : Caspar.Chen <Caspar.Chen@cipherlab.com.tw>
[05-20 14:30:22]   Message    : SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104
[05-20 14:30:22]   Devices    : rs36s rs38t rk95u
[05-20 14:30:22]   Dry-run    : true
[05-20 14:30:22] ================================
[05-20 14:30:22] ▶  [rs36s] 開始部署
[05-20 14:30:22] INFO  [rs36s] git checkout master && git clean -fd && git pull
  ... (rs36s 各步驟省略)
[05-20 14:30:24] ✔  [rs36s] 部署成功
[05-20 14:30:24] ▶  [rs38t] 開始部署
  ... (rs38t 同樣流程)
[05-20 14:30:26] ✔  [rs38t] 部署成功
[05-20 14:30:26] ▶  [rk95u] 開始部署
  ... (rk95u 同樣流程；branch 沿用 master)
[05-20 14:30:28] ✔  [rk95u] 部署成功
[05-20 14:30:28] ====== Deploy Result ======
[05-20 14:30:28]   總計: 3  成功: 3  跳過: 0  失敗: 0
[05-20 14:30:28]   成功機種: rs36s rs38t rk95u
[05-20 14:30:28]   Log: logs/Caspar-ReaderService_CipherLab-20260520_143022.log
[05-20 14:30:25] ===========================
```

> 每行最前面 `[MM-DD HH:MM:SS]` 是 `log()` 函式統一加上的時間戳；螢幕與 log 檔皆有，log 檔額外濾掉 ANSI 色碼。

> 純 APK 部署輸出格式相同，差別僅在無 `Libs ABI` 那行、驗證項目 5 項而非 8 項。  
> 重跑時若該機種已部署相同內容，會出現 `跳過: 1`，並印出 SKIPPED 區塊（見 3.3）。

---

## 4.2 --libs 路徑語意

- `--libs` 路徑 **basename 即 `LOCAL_TARGET_CPU_ABI`**（範例：`arm64-v8a`）
- **必須位於 `toBeUploaded/` 之下**（部署成功後 `rm -rf` 清理安全限制）
- 內部檔案／階層／格式 **完全由 RD 自理**，腳本不解讀
- 隱藏檔（`.` 開頭）與 symlink **一律跳過**

---

## 4.3 --libs 檔案動作三準則

1. **絕不刪除 remote 任何檔案／資料夾**
2. **絕不操作資料夾本身**（不傳遞空資料夾）
3. **逐檔依 MD5 判定**：

| staging | remote | 動作 |
|---|---|---|
| 有 | 無 | `[ Added ]` 新增 |
| 有 | 有 + MD5 異 | `[Updated]` 覆蓋 |
| 有 | 有 + MD5 同 | `[Skipped]` 略過 |
| 無 | 有 | 保留 remote |

---

## 4.4 Android.mk 自動維護

`Android.mk` 在 cp 全部結束後一次更新 3 個欄位  

```makefile
LOCAL_SRC_FILES         := ReaderService_CipherLab_V1_3_104.apk
LOCAL_TARGET_CPU_ABI    := arm64-v8a
LOCAL_PREBUILT_JNI_LIBS := \
    libs/$(LOCAL_TARGET_CPU_ABI)/README \
    libs/$(LOCAL_TARGET_CPU_ABI)/config.json \
    libs/$(LOCAL_TARGET_CPU_ABI)/libIAC.so \
    libs/$(LOCAL_TARGET_CPU_ABI)/libbarcodereader.so \
    libs/$(LOCAL_TARGET_CPU_ABI)/sub/libdeep.so
```

`LOCAL_TARGET_CPU_ABI`, `LOCAL_PREBUILT_JNI_LIBS`  
需要時自動補到 `include $(BUILD_PREBUILT)` 之前

`LOCAL_PREBUILT_JNI_LIBS` 清單來源：**remote `libs/<ABI>/` 內全部檔案**  
（cp 完成後 enumerate，保留既有檔／依字母升序／大小寫敏感／不限副檔名）

---

## 4.5 自動驗證項目（5 / 8）

純 APK 5 項，**含 libs 擴充至 8 項**：

```
✓ PASS    APK MD5
✓ PASS    Android.mk LOCAL_SRC_FILES
✓ PASS    Android.mk LOCAL_TARGET_CPU_ABI = arm64-v8a            (--libs)
✓ PASS    Android.mk LOCAL_PREBUILT_JNI_LIBS (N entries from remote) (--libs)
✓ PASS    JNI Libs files (N files MD5 vs staging)                (--libs)
✓ PASS    Commit Author Name
✓ PASS    Commit Author Email
✓ PASS    Commit Message
```

Lib 驗證失敗時會列出不符檔案。可用 `--no-verify` 略過驗證。

---

## 4.6 Demo 2 — 批次部署

當一次 release 多支 APK，用 `deploy_plan.xml`：

```xml
<deploy-plan>
  <!-- 純 APK task -->
  <task>
    <app>KeyMappingManager</app>
    <apk>~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk</apk>
    <author>Caspar</author>
    <message>SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3</message>
    <devices>
      <device>rk26s</device>
      <device>rs36s</device>
    </devices>
  </task>

  <!-- 含 JNI libs 的 task：多一個 <libs> 欄位（可選） -->
  <task>
    <app>ReaderService_CipherLab</app>
    <apk>~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk</apk>
    <libs>~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a</libs>
    <author>Caspar</author>
    <message>SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104</message>
    <devices>
      <device>rs36s</device>
      <device>rs38t</device>
      <device>rk95u</device>
    </devices>
  </task>
</deploy-plan>
```

```bash
./batch_deploy.sh --plan deploy_plan.xml --dry-run
```

> repo 中有範本 `deploy_plan.xml.template` 供編修，  
而 `deploy_plan.xml` 已被加入 `.gitignore` 不會被 commit。

---

## 4.7 Demo 3 — 獨立驗證

部署完想再進行人工複查，不需要重新部署：

```bash
./verify_deploy.sh \
  --app     ReaderService_CipherLab \
  --apk     ~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk \
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a \
  --author  Caspar \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs36s rs38t rk95u
```

> 純 APK 驗證：拿掉 `--libs` 該行即可。  
驗證項目與 4.5 同。  
任一項目不符即顯示 `✗` 與差異。

---

## 5. 設定維護：新增 / 修改 / 停用機種

只改 **`config/devices.conf`**，腳本不動：

```bash
# 新增 RK97
DEVICE_rk97="~/rk97/LA.QSSI.17.0"

# Repo 路徑搬遷
DEVICE_rk26s="~/repos/rk26s/LA.QSSI.12.0"

# 停用機種 — 直接註解掉
# DEVICE_rk96v="~/rk96v/LA.QSSI.15.0"

# 例外目錄（特定機種放在不同子目錄）
DEVICE_rk25_APK_SUBDIR="android/vendor/cipherlab/prebuilt/rk25"
```
</br></br>
> 部署時遇到 **未定義** 的機種名稱會被 `warn` 略過，**不影響其他機種**繼續執行。

---

## 5.1 設定維護：新增 / 修改 Author

只改 **`config/authors.conf`**：

```bash
AUTHOR_David="David.Wu|David.Wu@cipherlab.com.tw"
```

部署時：

```bash
./deploy_apk.sh --author David ...
```
</br></br>
- 不再需要該帳號時，直接刪除或註解掉該行；  
XML / CLI 引用到不存在的 key 會**提前報錯**並終止

---

## 6. 資源指引

| 需要 | 位置 |
|---|---|
| 完整文件 | `README.md` |
| 投影片本檔 | `docs/01_slides.md` |
| 速查卡（一頁） | `docs/03_quickref_cheatsheet.md` |
| FAQ | `docs/05_faq.md` |
| 新人 / 新機種 checklist | `docs/06_onboarding_checklist.md` |
| Log（每次執行） | `apk_deploy/logs/<Author>-<App>-YYYYMMDD_HHMMSS[-dryrun].log` |
| Repo | `git@gitlab.cipherlab.com.tw:app-dev/android/automation/scriptapkdeploy.git` |

---
layout: center
class: text-center
---

## Recap
</br></br>
- **痛點**：手動部署多機種多 app → 容易漏改 + 事後難 review
- **解法**：一行指令完成所有機種部署 + 自動驗證
- **可擴充**：新增 Model / Author 資訊只需要改設定檔，腳本沿用
- **安全**：dry-run 先試跑、部署失敗保留 staging（APK + libs）、log 自動留存

## Q&A
歡迎討論實際 use case 與各種 edge case
