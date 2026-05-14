# APK Deploy Toolkit

將單一 APK 自動部署到一或多個裝置 repo，並同步更新 `Android.mk`，完成後自動驗證部署結果。

---

## 目錄結構

```
apk_deploy/                  ← git clone 後的根目錄，cd 進來直接執行腳本
├── deploy_apk.sh            # 核心部署腳本（單一 app × 多機種）
├── batch_deploy.sh          # 批次包裝腳本（讀取 deploy_plan.xml）
├── verify_deploy.sh         # 獨立驗證腳本（不執行部署，僅檢查結果）
├── deploy_plan.xml          # 批次部署計畫範例
├── toBeUpload/              # APK 放這裡，部署成功後自動刪除
│   └── .gitkeep
├── config/
│   ├── devices.conf         # 機種名稱 → repo 路徑
│   └── authors.conf         # RD/Dev 的 git commit author 資訊
└── logs/                    # 每次執行自動產生時間戳記 log（不進版控）
    └── .gitkeep
```

---

## 環境需求

| 項目 | 說明 |
|------|------|
| 執行環境 | Upload Server（Ubuntu，IP `192.168.8.17`，帳號 `app_dev`）上直接執行 |
| 必要工具 | `git`、`bash 4.0+`、`md5sum`、`sed`、`python3`（批次部署用） |
| RD 操作 | 將 APK 以 `scp` 上傳至 server 的 `toBeUpload/`，再 ssh 進 server 執行腳本 |

---

## 初始設定

### 0. 下載腳本

登入 upload server 後於適當位置複製 script
```bash
git clone <REPO_URL> apk_deploy
```

### 1. 機種設定 `config/devices.conf`

定義所有支援機種的 repo 路徑。路徑可使用 `~`（腳本在 server 上執行，`~` 會正確展開為 `/home/app_dev`）。**新增機種只需在此加一行，腳本本身無需修改。**

```bash
# 格式: DEVICE_<機種名稱>="<repo 路徑>"（可用 ~ 代表 /home/app_dev）
DEVICE_rk26s="~/rk26s/LA.QSSI.12.0"
DEVICE_rk26u="~/rk26plus/LA.QSSI.14.0.R1"
DEVICE_rs35q="~/rs35"
DEVICE_rs35r="~/rs35r"
DEVICE_rs36s="~/rs36s/LA.QSSI.12.0"
DEVICE_rs36u="~/rs36plus/LA.QSSI.14.0.R1"
DEVICE_rs38t="~/rs38t/titan_qssi13"
DEVICE_rs38v="~/rs38v/titan_qssi15"
DEVICE_rk95p="~/rk95"
DEVICE_rk95s="~/rk95s"
DEVICE_rk95u="~/rk95u"
DEVICE_rk96v="~/rk96v/LA.QSSI.15.0"

# APK 放置目錄（全域預設，相對於各 repo 根目錄）
APK_SUBDIR="vendor/cipherlab"

# 機種專屬 APK 目錄覆寫（有需要才取消註解）
# DEVICE_rk25_APK_SUBDIR="android/vendor/cipherlab/prebuilt/rk25"

# APK 暫存目錄：所有 APK 統一放在此平坦目錄，不分子目錄
# 部署成功的 APK 自動刪除；失敗或未使用的保留，方便重試
APK_STAGING_DIR=""  # 留空 = 自動使用 <SCRIPT_DIR>/toBeUpload/
```

### 2. Author 設定 `config/authors.conf`

定義各 RD/Dev 的 git commit author 資訊。**`--author` 參數使用此設定的 key 名稱（`AUTHOR_` 後方的部分）。**

```bash
# 格式: AUTHOR_<Key>="Firstname.Lastname|email"
# 範例（僅供格式參考，非有效設定）:
#   AUTHOR_Bob="Bob.Lin|Bob.Lin@cipherlab.com.tw"

AUTHOR_Jiachuan="Jiachuan.Lin|Jiachuan.Lin@cipherlab.com.tw"
AUTHOR_Caspar="Caspar.Chen|Caspar.Chen@cipherlab.com.tw"
AUTHOR_Howard="Howard.Lu|Howard.Lu@cipherlab.com.tw"
AUTHOR_Ocer="Ocer.Wu|Ocer.Wu@cipherlab.com.tw"
AUTHOR_Ryu="Ryu.Li|Ryu.Li@cipherlab.com.tw"
AUTHOR_Eric="Eric.Lai|Eric.Lai@cipherlab.com.tw"
AUTHOR_Miller="Miller.Pan|Miller.Pan@cipherlab.com.tw"
AUTHOR_Nicole="Nicole.Weng|Nicole.Weng@cipherlab.com.tw"
AUTHOR_Kevin="Kevin.Kuan|Kevin.Kuan@cipherlab.com.tw"
AUTHOR_Henry="Henry.Tung|Henry.Tung@cipherlab.com.tw"
```

### 3. 給予執行權限（首次使用）

```bash
chmod +x deploy_apk.sh batch_deploy.sh verify_deploy.sh
```

---

## 使用方式

### 直接部署（最常用）

在 upload server 上執行。RD 須先將 APK 上傳至腳本同層的 `toBeUpload/`，所有不同 app 的 APK 統一放在這個平坦目錄下，不需分子目錄。部署成功後該 APK 自動刪除；任一機種失敗則保留供重試，重新執行相同指令即可。

```bash
# 1. 先將 APK 上傳到 server 的 toBeUpload/（RD 從自己電腦執行，所有 app 統一放這裡）
scp KeyMappingManager_v1.2.3.apk app_dev@192.168.8.17:~/apk_deploy/toBeUpload/

# 2. ssh 進 server，執行部署腳本
ssh app_dev@192.168.8.17
./deploy_apk.sh \
  --app     KeyMappingManager \
  --apk     ~/apk_deploy/toBeUpload/KeyMappingManager_v1.2.3.apk \
  --author  Bob \
  --message "Update KeyMappingManager to v1.2.3: fix key remap crash" \
  --device  rk26s rs36s rk95u \
  --dry-run
```

**參數說明：**

| 參數 | 必填 | 說明 |
|------|------|------|
| `--app` | ✓ | APP 名稱，對應 repo 內的目錄名稱（用來定位 `Android.mk`） |
| `--apk` | ✓ | staging 目錄上的 APK 路徑 |
| `--author` | ✓ | `authors.conf` 中的 key，例如 `Bob`、`Caspar` |
| `--message` | ✓ | git commit message（完整字串，以引號包覆） |
| `--device` | ✓ | 一或多個機種名稱（空格分隔），必須是 `devices.conf` 中定義的名稱 |
| `--dry-run` | — | 模擬執行，印出所有步驟但不實際複製檔案或 git push |
| `--no-verify` | — | 跳過部署後的自動驗證步驟 |

> **`--device` 每次執行時手動指定，沒有預設值。** 即使同一個 app，每次 push 的目標機種都可能不同，機種清單維護在 `devices.conf` 供選用。

---

### 批次部署

當需要連續部署多個 app 時，使用 `batch_deploy.sh` 搭配 `deploy_plan.xml` 計畫檔。`batch_deploy.sh` 本質上是一個 **loop wrapper**，以 `python3`（macOS / Linux / Windows 均內建，無需額外安裝）解析 XML 後逐筆呼叫 `deploy_apk.sh`，因此 **XML 寫 1 個 `<task>` 就只處理 1 個 app**，與直接呼叫 `deploy_apk.sh` 行為完全一致。

```bash
./batch_deploy.sh --plan deploy_plan.xml --dry-run
```

**`deploy_plan.xml` 格式：**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!--
  每個 <task> 代表一次部署（單一 app × 一或多個機種）
  <devices> 內每個 <device> 填入 devices.conf 中定義的機種名稱
-->
<deploy-plan>

  <task>
    <app>KeyMappingManager</app>
    <apk>~/apk_deploy/toBeUpload/KeyMappingManager_v1.2.3.apk</apk>
    <author>Bob</author>
    <message>Update KeyMappingManager to v1.2.3: fix key remap crash</message>
    <devices>
      <device>rk26s</device>
      <device>rk26u</device>
      <device>rs36s</device>
    </devices>
  </task>

  <task>
    <app>ScanManager</app>
    <apk>~/apk_deploy/toBeUpload/ScanManager_v3.0.1.apk</apk>
    <author>Bob</author>
    <message>Bump ScanManager v3.0.1: improve decode speed</message>
    <devices>
      <device>rs38t</device>
      <device>rs38v</device>
    </devices>
  </task>

</deploy-plan>
```

> XML 使用 `<!-- -->` 撰寫註解。`<message>` 內容可包含冒號、斜線等特殊字元，無需額外跳脫。若內容含 `<`、`>` 或 `&` 則需改用 CDATA：`<message><![CDATA[fix a > b logic]]></message>`。

---

### 獨立驗證（不部署）

部署完成後若需要人工複查，使用 `verify_deploy.sh`（staging APK 需仍在 `toBeUpload/` 中，用於 MD5 比對基準）：

```bash
./verify_deploy.sh \
  --app     KeyMappingManager \
  --apk     ~/apk_deploy/toBeUpload/KeyMappingManager_v1.2.3.apk \
  --author  Bob \
  --message "Update KeyMappingManager to v1.2.3: fix key remap crash" \
  --device  rk26s rs36s rk95u
```

參數與 `deploy_apk.sh` 相同（無 `--dry-run` / `--no-verify`）。

---

## 每台機種的完整部署流程

```
[1] git checkout master
    git clean -fd
    git pull origin master
         ↓
[2] 複製 APK 至 repo（版號策略，見下節）
    cp <SCRIPT_DIR>/toBeUpload/<apk> → <repo>/vendor/cipherlab/<APP_NAME>/
         ↓
[3] 更新 Android.mk
    sed 替換 LOCAL_SRC_FILES := *.apk → 新 APK 檔名
         ↓
[4] git add + commit + push
    git commit --author="Firstname.Lastname <email>" 來自 authors.conf
    commit message 來自 --message 參數
    git push origin master
         ↓
[5] 自動驗證（可用 --no-verify 略過）
    ✓ 已部署的 APK 存在且 MD5 與 staging 來源一致
    ✓ Android.mk 已包含正確 APK 檔名
    ✓ commit author name 符合 authors.conf
    ✓ commit author email 符合 authors.conf
    ✓ commit message 符合 --message 參數
```

---

## APK 保留策略

腳本自動判斷 APK 檔名是否含有版號，決定上傳行為。**不論任何情況都不會主動刪除 repo 內既有 APK。**

| 檔名範例 | 版號判定 | 行為 |
|----------|----------|------|
| `KeyMappingManager_v1.2.3.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager_1.2.3.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager_20250513.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager.apk` | ✗ 無版號 | cp 直接覆蓋同名檔 |

**版號識別 pattern**（匹配檔名結尾、副檔名之前）：`_vX`、`_X.Y`、`_X.Y.Z`、`_YYYYMMDD`、`_YYYYMMDDHHMMSS`

---

## Android.mk 更新規則

`sed` 替換 `LOCAL_SRC_FILES` 的值，支援各種空白寫法：

```makefile
# 更新前
LOCAL_SRC_FILES := KeyMappingManager_v1.0.0.apk

# 更新後（deploy_apk.sh 自動完成）
LOCAL_SRC_FILES := KeyMappingManager_v1.2.3.apk
```

替換後腳本立即驗證 `Android.mk` 是否已包含新 APK 檔名，若未成功則中止並回報錯誤。

---

## Log 與輸出範例

**每台機種部署時的 log 輸出：**

```
────────────────────────────────────────
  ▶  [rk26s] 開始部署
────────────────────────────────────────
  ... 各步驟 log ...
────────────────────────────────────────
  ✔  [rk26s] 部署成功
────────────────────────────────────────
```

**驗證輸出：**

```
--- 驗證 APK ---
  ✓ APK MD5 驗證通過: a3f9c12d8e4b7f2190ac56de83107b45
--- 驗證 Android.mk ---
  ✓ Android.mk 已更新為 KeyMappingManager_v1.2.3.apk
--- 驗證 commit author ---
  ✓ Author name  : Bob.Lin
  ✓ Author email : Bob.Lin@cipherlab.com.tw
--- 驗證 commit message ---
  ✓ Commit message: Update KeyMappingManager to v1.2.3: fix key remap crash
  → commit hash: [a3f9c12]
[rk26s] 驗證通過 ✓
```

任一項目不符，該機種標記為失敗，最終 exit code 為 1。

---

## Log

每次執行 `deploy_apk.sh` 都會在 `logs/` 下自動產生 log 檔：

```
logs/deploy_20250513_143022.log
```

`batch_deploy.sh` 呼叫多次 `deploy_apk.sh`，每次呼叫各自產生獨立 log。

---

## 設定修改指南

### 1. 修改 Author 資訊

編輯 `config/authors.conf`。格式為 `AUTHOR_<Key>="Firstname.Lastname|email"`（駝峰式，FirstName 與 LastName 以 `.` 區隔），Key 即為執行腳本時 `--author` 參數填入的值。

**新增一位 RD：**

```bash
# 在 authors.conf 末尾加入
AUTHOR_David="David.Wu|David.Wu@cipherlab.com.tw"
```

使用時：

```bash
./deploy_apk.sh --author David ...
```

**修改現有 RD 的 email：**

```bash
# 修改前
AUTHOR_Bob="bob.lin|bob.lin@gmail.com"

# 修改後（例如 email 改版）
AUTHOR_Bob="Bob.Lin|Bob.Lin@cipherlab.com.tw"
```

**移除已離職 RD：**

直接刪除或在該行前加 `#` 註解掉即可。若有正在進行的 `deploy_plan.xml` 引用到該 key，執行時會提前報錯而非靜默略過。

```bash
# AUTHOR_David="David.Wu|David.Wu@cipherlab.com.tw"   # 停用範例
```

---

### 2. 修改 Device Repos

編輯 `config/devices.conf`。每一行定義一個機種名稱與其在 upload server 上的 repo 絕對路徑。

**新增一個機種：**

```bash
# 在 devices.conf 末尾加入
DEVICE_rk97="~/rk97/LA.QSSI.17.0"
```

新增後即可在 `--device` 或 `deploy_plan.xml` 中直接使用：

```bash
./deploy_apk.sh --device rk97 ...
```

**修改某機種的 repo 路徑（例如 repo 搬遷）：**

```bash
# 修改前
DEVICE_rk26s="~/rk26s/LA.QSSI.12.0"

# 修改後（repo 搬遷）
DEVICE_rk26s="~/repos/rk26s/LA.QSSI.12.0"
```

**停用某機種（暫時不部署）：**

同樣註解掉該行即可。`deploy_apk.sh` 找不到定義時會印出 warn 並略過，不影響其他機種繼續執行。

```bash
# DEVICE_rk96v="~/rk96v/LA.QSSI.15.0"   # 停產，暫停部署
```

**修改 APK 放置的子目錄：**

`APK_SUBDIR` 是全域預設值，所有未特別設定的機種都使用此路徑。若特定機種的目錄結構不同，可用 `DEVICE_<NAME>_APK_SUBDIR` 覆寫，不影響其他機種。

```bash
# 全域預設（所有機種共用）
APK_SUBDIR="vendor/cipherlab"

# 機種專屬覆寫（僅該機種生效，其他機種仍使用全域預設）
DEVICE_rk25_APK_SUBDIR="android/vendor/cipherlab/prebuilt/rk25"
```

優先順序：`DEVICE_<NAME>_APK_SUBDIR`（有設定）> `APK_SUBDIR`（全域預設）。未設定機種專屬值時自動 fallback 到全域預設，無需每個機種都填寫。

---

### 3. 調整 Repo 內的資料夾結構

腳本在每個 device repo 內預期以下兩個路徑存在，兩者都可以透過設定調整，**不需修改腳本本身**。

#### APK 存放目錄

由 `devices.conf` 的 `APK_SUBDIR` 控制（相對於 repo 根目錄）。APK 與 `Android.mk` 都放在 `<APK_SUBDIR>/<APP_NAME>/` 下：

```
<repo_root>/
└── vendor/
    └── cipherlab/              ← APK_SUBDIR="vendor/cipherlab"
        └── KeyMappingManager/  ← --app KeyMappingManager（module 目錄）
            ├── KeyMappingManager_v1.2.3.apk
            └── Android.mk
```

若 repo 結構改為其他路徑，只需修改 `APK_SUBDIR` 一個變數：

```bash
# 改為 vendor/app/
APK_SUBDIR="vendor/app"
```

#### Android.mk 位置

由 `--app` 參數控制，腳本固定在以下路徑尋找：

```
<repo_root>/
└── <APK_SUBDIR>/
    └── <--app 參數值>/
        └── Android.mk        ← 腳本讀寫此檔案
```

範例：`APK_SUBDIR="vendor/cipherlab"`、`--app KeyMappingManager` → `vendor/cipherlab/KeyMappingManager/Android.mk`。

**`--app` 名稱必須與 `vendor/cipherlab/` 下的 module 目錄名稱完全一致（大小寫敏感）。** 若目錄名稱與 APK 檔名前綴不同，以目錄名稱為準：

```bash
# repo 內 module 目錄為 vendor/cipherlab/key_mapping_mgr/
./deploy_apk.sh --app key_mapping_mgr ...
```

#### 完整 repo 結構範例

```
~/rk26s/LA.QSSI.12.0/                    ← DEVICE_rk26s 指向此處
└── vendor/
    └── cipherlab/                         ← APK_SUBDIR="vendor/cipherlab"
        ├── KeyMappingManager/             ← --app KeyMappingManager
        │   ├── KeyMappingManager_v1.1.0.apk  # 舊版（有版號，保留）
        │   ├── KeyMappingManager_v1.2.3.apk  # 新版（本次部署）
        │   └── Android.mk                 ← 腳本自動更新 LOCAL_SRC_FILES
        └── ScanManager/                   ← --app ScanManager
            ├── ScanManager_v3.0.1.apk
            └── Android.mk
```

---

## 新增機種 Checklist

1. `config/devices.conf` 新增 `DEVICE_<name>="~/<path>"`（機種名稱建議小寫）
2. 確認 upload server 上該 repo 已存在且可 `git pull`
3. 確認 repo 內存在 `vendor/cipherlab/` 目錄（或與 `APK_SUBDIR` 一致的路徑）
4. 確認 repo 內存在 `vendor/cipherlab/<APP_NAME>/Android.mk` 並含 `LOCAL_SRC_FILES` 行
5. 執行一次 `--dry-run` 確認路徑無誤

## 新增 Author Checklist

1. `config/authors.conf` 新增 `AUTHOR_<Key>="Firstname.Lastname|email"`
2. Key 命名建議與公司帳號一致，方便辨識
3. 執行時以 `--author <Key>` 帶入即可

---

## 常見問題

| 問題 | 可能原因 | 解法 |
|------|----------|------|
| `找不到 Android.mk` | `--app` 名稱與 repo 內目錄名稱不符 | 確認大小寫完全一致 |
| `Android.mk 更新失敗` | `LOCAL_SRC_FILES` 行不存在或格式不符 | 手動確認 `.mk` 內容 |
| `APK MD5 不符` | 網路傳輸中斷導致檔案損毀 | 重新執行部署 |
| `Author name/email 不符` | `authors.conf` 中的 key 對應資訊有誤 | 確認 `authors.conf` 內容，name 與 email 格式是否正確 |
| `Commit message 不符` | 部署途中有人另行 push 了新 commit | 確認 repo `git log -1` 是否為本次部署 |
| 機種被 warn 略過 | `devices.conf` 未定義該機種名稱 | 在 `devices.conf` 補上對應行 |
