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
4. **Demo** — dry-run、實機部署、批次
5. **設定維護** — 新增 Model  / 新增 Author
6. **資源指引** — 文件、log、回報方式

---

## 1. 痛點：手動部署一支 APK 要做的事

每次 release 一支 APK 到 N 個機種，RD 必須：

1. SSH 進 upload server，逐一 `cd` 進到每個 model 存放 apk 的位置
2. `git checkout master` → `git clean -df` → `git pull origin master`，將 server 狀態同步到最新版
3. 把 APK 複製到 `vendor/cipherlab/<APP>/`
4. 用 `vm` 改 `Android.mk` 中 `LOCAL_SRC_FILES` 檔名資訊
5. `git add` → `git commit --author=...` → `git push`
6. 機種 × app 越多，**漏改、改錯 author、commit message 不一致** 的機率越高

> 12 個 model × 一支 APK ≈ **60+ 個指令**，且很難 review

---

## 2. 解法概覽

一份指令、一次執行，完成：

- 多機種 **平行邏輯、序列執行**（任一機種失敗不影響其他）
- Android.mk 自動 `sed` 替換 `LOCAL_SRC_FILES`  檔名資訊
- Git commit 自動帶入 `--author` 與標準化 message
- **部署後自動驗證**（5 項）：APK MD5 / Android.mk LOCAL_SRC_FILES / commit author name / commit author email / commit message
- 全成功 → APK 自動清除；任一失敗 → 保留 staging APK，重跑即可

> 範疇外：**不**負責 build APK、**不**改 repo 的 git config、**不**做 code review

---

## 3. 架構：三個腳本 × 兩份設定檔

```
apk_deploy/
├── deploy_apk.sh        # 核心：單一 app × 多機種
├── batch_deploy.sh      # Wrapper：讀 XML 跑多個 task
├── verify_deploy.sh     # 只驗證，不部署（事後複查用）
├── config/
│   ├── devices.conf     # 機種 → repo 路徑
│   └── authors.conf     # RD → git author 資訊
├── toBeUploaded/        # APK staging 目錄
├── logs/                # 每次執行的時間戳記 log
└── deploy_plan.xml      # 批次計畫（template 已提供）
```

**設計原則**：新增機種 / RD **只改設定檔**，腳本本身不動。

---

## 3.1 每台機種的執行流程

```
[1] cd repo → git checkout master → clean -df → pull origin master
       ↓
[2] cp APK → vendor/cipherlab/<APP>/
       ↓
[3] sed 替換 Android.mk 的 LOCAL_SRC_FILES
       ↓
[4] git add → git commit --author=... → git push
       ↓
[5] 自動驗證 5 項（可 --no-verify 略過）
       APK MD5 / Android.mk LOCAL_SRC_FILES /
       commit author name / commit author email / commit message
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

> 版號 pattern：  
`_vX` /  
`_X.Y` / `_X.Y.Z` /   
`_YYYYMMDD` / `_YYYYMMDDHHMMSS`  
> **任何情況都不會主動刪除 repo 內既有 APK。**

---

## 4. Demo 1 — 直接部署（dry-run）

```bash
# 1) RD 本機把 APK 丟到 server
scp KeyMappingManager_v1.2.3.apk \
    app_dev@192.168.8.17:~/apk_deploy/toBeUploaded/

# 2) ssh 進 server 執行（先 --dry-run 確認）
ssh app_dev@192.168.8.17
cd ~/apk_deploy
./deploy_apk.sh \
  --app     KeyMappingManager \
  --apk     ~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk \
  --author  Caspar \
  --message "SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3" \
  --device  rk26s rs36s rk95u \
  --dry-run
```

> Dry-run 印出**所有會執行的指令**但不動 repo，確認無誤再拿掉 `--dry-run`

---

## 4.1 Demo 1 — 預期輸出（節錄）

```
====== APK Deploy Summary ======
  APP       : KeyMappingManager
  APK       : KeyMappingManager_v1.2.3.apk
  版號識別  : 有版號 → 保留舊版共存
  Author    : Caspar.Chen <Caspar.Chen@cipherlab.com.tw>
  Message   : SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
  Devices   : rk26s rs36s rk95u
  Dry-run   : true
================================
  ▶  [rk26s] 開始部署
  ...
  ✔  [rk26s] 部署成功
  ...
====== Deploy Result ======
  總計: 3  成功: 3  失敗: 0
  Log: logs/deploy_20260518_143022.log
```

---

## 4.2 Demo 2 — 批次部署

當一次 release 多支 APK，用 `deploy_plan.xml`：

```xml
<deploy-plan>
  <task>
    <app>KeyMappingManager</app>
    <apk>~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk</apk>
    <author>Caspar</author>
    <message>SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3</message>
    <devices>
      <device>rk26s</device><device>rk26u</device><device>rs36s</device>
    </devices>
  </task>
  <task> ... ScanManager ... </task>
</deploy-plan>
```

```bash
./batch_deploy.sh --plan deploy_plan.xml --dry-run
```

> repo 中有範本 `deploy_plan.xml.template` 供編修，  
而 `deploy_plan.xml` 已被加入 `.gitignore` 不會被 commit。

---

## 4.3 Demo 3 — 獨立驗證

部署完想再進行人工複查，不需要重新部署：

```bash
./verify_deploy.sh \
  --app     KeyMappingManager \
  --apk     ~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk \
  --author  Caspar \
  --message "SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3" \
  --device  rk26s rs36s rk95u
```

驗證五項：APK MD5 / Android.mk LOCAL_SRC_FILES / commit author name / commit author email / commit message  
任一項目不符即顯示 `✗` 與差異。

---

## 5. 設定維護：新增機種

只改 **`config/devices.conf`**，腳本不動：

```bash
# 新增 RK97
DEVICE_rk97="~/rk97/LA.QSSI.17.0"
```

立即可用：

```bash
./deploy_apk.sh --device rk97 ...
```

例外目錄路徑（保有不同的 apk 路徑需求）：

```bash
DEVICE_rk25_APK_SUBDIR="android/vendor/cipherlab/prebuilt/rk25"
```
</br></br>
> 當部署時找不到對應的機種時會被 **warn 略過**，並不影響其他機種執行。

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
| 速查卡（一頁） | `docs/presentation/03_quickref_cheatsheet.md` |
| Demo 步驟 | `docs/presentation/04_demo_script.md` |
| FAQ | `docs/presentation/05_faq.md` |
| 新人 / 新機種 checklist | `docs/presentation/06_onboarding_checklist.md` |
| Log（每次執行） | `apk_deploy/logs/deploy_YYYYMMDD_HHMMSS.log` |
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
- **安全**：dry-run 先試跑、部署失敗保留 apk、log 自動留存

## Q&A
歡迎討論實際 use case 與各種 edge case
