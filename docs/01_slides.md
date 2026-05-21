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
2. `git checkout master` → `git clean -df` → `git pull origin master`，將 server 狀態同步到最新版
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
- 全成功 → staging APK 與 libs 都自動清除；任一失敗 → 全部保留供重跑

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
├── toBeUploaded/              # APK + libs staging (全機種成功後自動清除)
├── logs/                      # 每次執行的時間戳記 log
└── deploy_plan.xml.template   # 批次計畫範本（複製為 deploy_plan.xml 後編輯）
```

**設計原則**：新增機種 / RD **只改設定檔**，腳本本身不動。

---

## 3.1 每台機種的執行流程

```
[1] git checkout master → clean -fd → pull origin master
       ↓
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
[5] git add → git commit --author=... → git push
       ↓
[6] 自動驗證（可 --no-verify 略過）— 純 APK 5 項，含 libs 8 項
```

任何步驟失敗 → 該機種標記為失敗，**不影響其他機種繼續部署**

---

## 3.2 APK 保留策略

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
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/rs38t/arm64-v8a \
  --author  Caspar \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs38t \
  --dry-run
```

> 純 APK 部署：拿掉 `--libs` 該行即可，scp 也只需上傳 APK，其餘參數結構不變。
Dry-run 印出**所有會執行的指令**但不動 repo，確認無誤再拿掉 `--dry-run`

---

## 4.1 Demo 1 — 預期輸出（節錄）

```
====== APK Deploy Summary ======
  APP        : ReaderService_CipherLab
  APK        : ReaderService_CipherLab_V1_3_104.apk
  版號識別   : 有版號 → 保留舊版共存
  Libs ABI   : arm64-v8a  (5 個檔案)
  Author     : Caspar.Chen <Caspar.Chen@cipherlab.com.tw>
  Message    : SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104
  Devices    : rs38t
  Dry-run    : true
================================
[05-20 14:30:22] ▶  [rs38t] 開始部署
[05-20 14:30:22] INFO  [rs38t] git checkout master && git clean -fd && git pull
  ...
[05-20 14:30:25] ✔  [rs38t] 部署成功
  ...
====== Deploy Result ======
  總計: 1  成功: 1  失敗: 0
  Log: logs/deploy-Caspar-ReaderService_CipherLab-20260520_143022.log
```

> 純 APK 部署輸出格式相同，差別僅在無 `Libs ABI` 那行、驗證項目 5 項而非 8 項。

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
✓ PASS    Android.mk LOCAL_TARGET_CPU_ABI = arm64-v8a    (--libs)
✓ PASS    Android.mk LOCAL_PREBUILT_JNI_LIBS             (--libs)
✓ PASS    JNI Libs files                                 (--libs)
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
    <libs>~/apk_deploy/toBeUploaded/ReaderService_Libs/rs38t/arm64-v8a</libs>
    <author>Caspar</author>
    <message>SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104</message>
    <devices>
      <device>rs38t</device>
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
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/rs38t/arm64-v8a \
  --author  Caspar \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs38t
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
| Log（每次執行） | `apk_deploy/logs/deploy-<Author>-<App>-YYYYMMDD_HHMMSS.log` |
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
