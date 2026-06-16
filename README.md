# APK Deploy Toolkit

將 APK 自動部署到一或多個裝置 repo，並同步更新 `Android.mk`，完成後自動驗證部署結果。

---

## 目錄結構

```
apk_deploy/                  ← git clone 後的根目錄，cd 進來直接執行腳本
├── deploy_apk.sh            # 核心部署腳本（單一 app × 多機種）
├── batch_deploy.sh          # 批次包裝腳本（讀取 deploy_plan.xml）
├── verify_deploy.sh         # 獨立驗證腳本（不執行部署，僅檢查結果）
├── deploy_plan.xml.template # 批次計畫範本（複製為 deploy_plan.xml 後編輯）
├── toBeUploaded/            # APK + libs staging 區（無失敗即自動清除；SKIPPED 不阻擋）
│   └── .gitkeep
├── config/
│   ├── devices.conf         # 機種名稱 → repo 路徑
│   └── authors.conf         # RD/Dev 的 git commit author 資訊
└── logs/                    # 每次執行自動產生時間戳記 log
    └── .gitkeep
```

---

## 環境需求

| 項目 | 說明 |
|------|------|
| 執行環境 | Upload Server（Ubuntu，IP `192.168.8.17`，帳號 `app_dev`）上直接執行 |
| 必要工具 | `git`、`bash 4.0+`、`md5sum`、`python3`（更新 Android.mk + 批次解析 XML 用） |
| RD 操作 | 將 APK 以 `scp` 上傳至 server 的 `toBeUploaded/`，再 ssh 進 server 執行腳本 |

---

## 初始設定

### 0. 下載腳本

登入 upload server 後於適當位置複製 script
```bash
git clone git@gitlab.cipherlab.com.tw:app-dev/android/automation/scriptapkdeploy.git apk_deploy
```

### 1. 機種設定 `config/devices.conf`

定義所有支援機種的 repo 路徑。  
路徑可使用 `~`（腳本在 server 上執行，`~` 會正確展開為 `/home/app_dev`）。  
**新增機種只需在此加一行，腳本本身無需修改。**

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

# Git branch（全域預設）
BRANCH="master"

# 機種專屬 branch 覆寫（有需要才取消註解）
DEVICE_rk95p_BRANCH="CIPHERLAB_MASTER"

# APK 暫存目錄：所有 APK 統一放在此平坦目錄，不分子目錄
# 部署成功的 APK 自動刪除；失敗或未使用的保留，方便重試
APK_STAGING_DIR=""  # 留空 = 自動使用 <SCRIPT_DIR>/toBeUploaded/
```

### 2. Author 設定 `config/authors.conf`

定義各 RD/Dev 的 git commit author 資訊。  
**`--author` 參數使用此設定的 key 名稱（AUTHOR_`<KEY>`）。**

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

在 upload server 上執行。RD 須先將 APK 及 libs 資料夾上傳至腳本同層的 `toBeUploaded/`，所有不同 app 的 APK 統一放在這個目錄下 (不需分子目錄)。  
但 libs 需放在資料夾中 `toBeUploaded/<category>/<ABI>/` ，路徑指到 ABI 資料夾即可。  
所有機種皆**無失敗**（SUCCESS + SKIPPED 任意組合）staging APK 與 libs 都會自動清除。任一機種失敗則保留供重試，重新執行相同指令即可——已部署相同內容的機種會被偵測為 SKIPPED 不重做。

```bash
# 1. 先將 APK + libs 上傳到 server 的 toBeUploaded/（RD 從自己電腦執行）
scp -r ReaderService_CipherLab_V1_3_104.apk \
       ReaderService_Libs \
       app_dev@192.168.8.17:~/apk_deploy/toBeUploaded/

# 2. ssh 進 server，執行部署腳本
ssh app_dev@192.168.8.17
./deploy_apk.sh \
  --app     ReaderService_CipherLab \
  --apk     ~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk \
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a \
  --author  Bob \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs38t \
  --dry-run
```

> **純 APK 部署**：拿掉 `--libs` 該行即可，scp 也只需上傳 APK，其餘參數結構不變。

**參數說明：**

| 參數 | 必填 | 說明 |
|------|------|------|
| `--app` | ✓ | APP 名稱，對應 repo 內的目錄名稱（用來定位 `Android.mk`） |
| `--apk` | ✓ | staging 目錄上的 APK 路徑 |
| `--libs` | — | （可選）ABI 資料夾路徑，basename 即 `LOCAL_TARGET_CPU_ABI`。內部任意檔案（含子目錄、無副檔名、任何格式都接受）。詳見下方 [--libs 路徑語意](#--libs-路徑語意附帶資源檔時) 子節 |
| `--author` | ✓ | `authors.conf` 中的 key，例如 `Bob`、`Caspar` |
| `--message` | ✓ | git commit message（完整字串，以引號包覆）。標準格式：`<JIRA-ID> : [Cipherlab] Update <App> v<Version>`，例如 `SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3` |
| `--device` | ✓ | 一或多個機種名稱（空格分隔），必須是 `devices.conf` 中定義的名稱 |
| `--dry-run` | — | 模擬執行，印出所有步驟但不實際複製檔案或 git push |
| `--no-verify` | — | 跳過部署後的自動驗證步驟 |

> **`--device` 每次執行時手動指定，沒有預設值。** 即使同一個 app，每次 push 的目標機種都可能不同，機種清單維護在 `devices.conf` 供選用。

#### --libs 路徑語意（附帶資源檔時）

當 module 需要附帶外部資源檔（例如 `.so` JNI libs、`.json` 設定、`.txt` 說明檔，或無副檔名的資源）時，使用 `--libs <ABI 資料夾路徑>` 一次帶上。

- **路徑直接指向 ABI 資料夾本身**，basename 即 `LOCAL_TARGET_CPU_ABI` 的值
- **必須位於 `toBeUploaded/` 之下**（為了部署成功後的 `rm -rf` 清理安全）
- 內部結構（子目錄、檔案類型）**完全由 RD 自理**，腳本不解讀也不限制
- 隱藏檔（`.` 開頭）與 symlink 一律**跳過**

範例 staging 結構：

```
toBeUploaded/
└── ReaderService_Libs/
    └── noHK/
        └── arm64-v8a/                ← --libs 指這裡
            ├── libbarcodereader.so
            ├── libIAC.so
            ├── config.json
            ├── README                 (無副檔名也接受)
            └── sub/
                └── libdeep.so          (任意巢狀)
```

部署後 remote 結構：

```
<repo>/vendor/cipherlab/ReaderService_CipherLab/
├── Android.mk                                ← 自動更新 3 欄位
├── ReaderService_CipherLab_V1_3_104.apk      ← APK
└── libs/arm64-v8a/                            ← 跟 --libs 一致
    ├── libbarcodereader.so
    ├── libIAC.so
    ├── config.json
    ├── README
    └── sub/libdeep.so
```

#### --libs 檔案動作規則

| local 狀態 | remote 狀態 | 動作 |
|---|---|---|
| 檔案存在 | 不存在 | **新增** (含必要父層 `mkdir -p`)，標籤 `[ Added ]` |
| 檔案存在 | 存在 + MD5 異 | **覆蓋**，標籤 `[Updated]` |
| 檔案存在 | 存在 + MD5 同 | **略過**（不動），標籤 `[Skipped]` |
| 檔案不存在 | 存在 | **保留 remote**（絕不刪除）|

#### --libs 邊界 die 條件

| 情境 | 行為 |
|---|---|
| `--libs` 路徑不存在 | die |
| `--libs` 不是資料夾 | die |
| `--libs` 為空目錄 | die |
| `--libs` basename 為 `.` / `..` / 空 | die |
| `--libs` **不在 `toBeUploaded/` 之下** | die（rm -rf 清理安全限制）|
| `.mk` 缺 `include $(BUILD_PREBUILT)` 錨點 | die |

#### 部署成功後的 staging 清理

**所有機種無失敗（SUCCESS + SKIPPED 任意組合）**腳本會：

1. `rm -f` staging APK 檔案
2. `rm -rf` `--libs` 指向的 ABI 整包資料夾（僅當 `--libs` 提供時）

**任一機種失敗** → APK + libs 都保留，重新執行相同指令即可重試。重試時已部署相同內容的機種會被偵測為 SKIPPED 自動跳過 step 2-6。

> 由於 `rm -rf` 是破壞性動作，腳本強制 `--libs` 必須在 `toBeUploaded/` 之下，避免誤刪外部資料。

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
    <apk>~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk</apk>
    <author>Bob</author>
    <message>SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3</message>
    <devices>
      <device>rk26s</device>
      <device>rk26u</device>
      <device>rs36s</device>
    </devices>
  </task>

  <!-- 含 JNI libs 的 task：多一個 <libs> 欄位（可選） -->
  <task>
    <app>ReaderService_CipherLab</app>
    <apk>~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk</apk>
    <libs>~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a</libs>
    <author>Bob</author>
    <message>SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104</message>
    <devices>
      <device>rs38t</device>
    </devices>
  </task>

</deploy-plan>
```

> XML 使用 `<!-- -->` 撰寫註解。`<message>` 內容可包含冒號、斜線等特殊字元，無需額外跳脫。團隊標準格式 `<JIRA-ID> : [Cipherlab] Update <App> v<Version>` 通常不會出現 `<`/`>`/`&`；若邊界情況需要包含這些字元，改用 CDATA：`<message><![CDATA[fix a > b logic]]></message>`。

---

### 獨立驗證（不部署）

部署完成後若需要人工複查，使用 `verify_deploy.sh`（staging APK / libs 需仍在 `toBeUploaded/` 中，用於 MD5 比對基準；路徑與當初 deploy 相同）：

```bash
./verify_deploy.sh \
  --app     ReaderService_CipherLab \
  --apk     ~/apk_deploy/toBeUploaded/ReaderService_CipherLab_V1_3_104.apk \
  --libs    ~/apk_deploy/toBeUploaded/ReaderService_Libs/noHK/arm64-v8a \
  --author  Bob \
  --message "SW_CLUTY-397 : [Cipherlab] Update ReaderService_CipherLab v1.3.104" \
  --device  rs38t
```

> **純 APK 驗證**：拿掉 `--libs` 該行即可。  
驗證項目：純 APK **5 項**、含 libs **8 項**。參數與 `deploy_apk.sh` 相同（無 `--dry-run` / `--no-verify`）。

---

## 每台機種的完整部署流程

```
[0] 預檢 remote 連線
    git -C <repo> ls-remote --exit-code origin <branch>
    （走 GIT_SSH_COMMAND 設定：ConnectTimeout=10s, ServerAliveInterval=5s × 3 次
       → remote 死機最多等約 25s 就斷線）
    失敗 → err + return 1，此機種歸 FAILED，其他機種繼續
         ↓
[1] git checkout <branch>
    git clean -fd
    git pull origin <branch>
    pull 失敗 → err + return 1，此機種歸 FAILED，其他機種繼續
         ↓
[1.5] SKIPPED 偵測（pull 之後比對 remote 現況）
    若以下「全部相符」→ return 2，此機種歸 SKIPPED，跳過 step 2-6：
      - <APK_DEST_DIR>/<APK_FILENAME> 存在且 staging APK MD5 一致
      - --libs 提供時，staging 內每個檔案在 remote 都存在且 MD5 一致
      - HEAD == origin/<branch>（HEAD 已推送；避免 push-fail 重跑誤觸 SKIPPED）
      - HEAD commit author name + email == --author 經 authors.conf 查表後的 name + email
      - HEAD commit message             == --message 參數
         ↓
[2] 複製 APK 至 repo
    cp <SCRIPT_DIR>/toBeUploaded/<apk> → <repo>/vendor/cipherlab/<APP_NAME>/
         ↓
[3] 複製 libs 至 repo（僅當提供 --libs）
    逐檔判定 Added / Updated / Skipped (MD5)
    → <repo>/.../<APP_NAME>/libs/<ABI_NAME>/...
         ↓
[4] 更新 Android.mk（在所有 cp 結束之後）
    LOCAL_SRC_FILES       ← APK 檔名
    LOCAL_TARGET_CPU_ABI  ← ABI 名稱  (僅當 --libs)
    LOCAL_PREBUILT_JNI_LIBS ← 自動枚舉 (僅當 --libs)
         ↓
[5a] git add + commit（先做 commit，不含 push）
    git commit --author="Firstname.Lastname <email>"
    commit message 來自 --message 參數
    add / commit 失敗 → err + return 1，此機種歸 FAILED（無 local commit 殘留）
         ↓
[5b] git push origin <branch>
     <branch> 來自 devices.conf：全域 BRANCH 或 DEVICE_<NAME>_BRANCH 覆寫
    push 失敗 → err + return 1，但保留 local commit
              並印出 RD 手動處理資訊（repo / branch / hash / message / 後續指令）
         ↓
[6] 自動驗證（可用 --no-verify 略過）—— 無 --libs 5 項；有 --libs 8 項
    ✓ 已部署的 APK 存在且 MD5 與 staging 一致
    ✓ Android.mk LOCAL_SRC_FILES 已更新
    ✓ Android.mk LOCAL_TARGET_CPU_ABI 已更新      (有 --libs)
    ✓ Android.mk LOCAL_PREBUILT_JNI_LIBS 列表完整 (有 --libs)
    ✓ JNI Libs files MD5 全對                     (有 --libs)
    ✓ commit author name / email 符合 authors.conf
    ✓ commit message 符合 --message 參數
```

> **為什麼 step 0、step 1、step 5a/5b 都要顯式檢查 exit code？**  
> Bash 的 `set -e` 有個反直覺的例外：當函式被 `if` / `&&` / `||` / `!` 包住呼叫時，函式內部的 `set -e` 整段失效。本腳本主迴圈是 `deploy_device "${dev}" || rc=$?`（用來區分 SUCCESS / SKIPPED / FAILED 三類），這個 `||` 一樣會讓函式內 `set -e` 失效，所以所有 git 動作都必須**手動**用 `|| { err; return 1; }` 抓 exit code，不能仰賴 `set -e` 自動 abort。否則 remote 壞掉時 `git pull` 失敗會被「靜默忽略」，腳本繼續在過時 branch 上做事、commit、誤刪 staging APK。

> **SSH timeout：避免 remote 死機讓腳本無限掛住**  
> git 對 remote 的所有操作（ls-remote / pull / push / fetch）走 SSH；預設沒有應用層 timeout，若 gitlab 半死（TCP 已建立但 sshd 無回應），git 會永遠等下去。本腳本在開頭 `export GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"`：
> - `ConnectTimeout=10`：TCP 連線階段 10 秒放棄
> - `ServerAliveInterval=5` + `ServerAliveCountMax=3`：連線建立後每 5 秒探測，連續 3 次（15 秒）無回應視為斷線
> - 最壞情境上限約 **25 秒**，超過會以非零 exit code 返回，落入 step 0 的 `|| { err; return 1; }` 分支，該機種歸 FAILED。

### Push 失敗時的提示訊息範例

當 step 5b 的 `git push` 失敗（remote 連線異常、auth 過期、non-fast-forward 等任何原因），local commit **不會 rollback**，並印出以下訊息（同步寫入 log）：

```
ERROR [rs38t] git push 失敗（exit code 非零）
ERROR [rs38t] 注意：local commit 已建立但未推送至 remote，請手動處理：
ERROR [rs38t]     Repo    : /home/app_dev/rs38t/titan_qssi13
ERROR [rs38t]     Branch  : master
ERROR [rs38t]     Hash    : a3f9c12
ERROR [rs38t]     Message : SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
ERROR [rs38t]     後續    : remote 恢復後執行 cd '/home/app_dev/rs38t/titan_qssi13' && git push origin master
```

### SKIPPED 偵測訊息範例

step 1.5 偵測到該機種已部署相同內容時，跳過 step 2-6 並印出（同步寫入 log）：

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

> **SKIPPED 不算失敗。** 最終結果以三類別顯示（成功 / 跳過 / 失敗），exit code 仍以「失敗數是否為 0」決定。Staging APK + libs 的清除規則維持「無失敗即清除」（SKIPPED 不阻擋清除）。

---

## APK 保留策略

腳本自動判斷 APK 檔名是否含有版號，決定上傳行為。**不論任何情況都不會主動刪除 repo 內既有 APK。**

| 檔名範例 | 版號判定 | 行為 |
|----------|----------|------|
| `KeyMappingManager_v1.2.3.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager_1.2.3.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager_20250513.apk` | ✓ 有版號 | 上傳新版，舊版保留共存 |
| `KeyMappingManager.apk` | ✗ 無版號 | cp 直接覆蓋同名檔 |

**版號識別 pattern**（檔名結尾、副檔名之前；數字段以 `.` 或 `_` 分隔，至少兩段）：`_vX.Y`、`_vX.Y.Z`、`_X.Y`、`_X.Y.Z`、`_YYYYMMDD`、`_YYYYMMDDHHMMSS`

---

## Android.mk 更新規則

`Android.mk` 在每次部署檔案複製完成後都會更新以下欄位（用 Python 處理，避免平台 `sed` 差異）：

| 欄位 | 何時更新 | 寫入規則 |
|---|---|---|
| `LOCAL_SRC_FILES` | 每次部署 | 直接寫入 APK 完整檔名（literal）|
| `LOCAL_TARGET_CPU_ABI` | 僅當 `--libs` 提供 | 寫入 ABI 名稱（= `basename(--libs)`）；缺欄位則自動 insert |
| `LOCAL_PREBUILT_JNI_LIBS` | 僅當 `--libs` 提供 | 用 `libs/$(LOCAL_TARGET_CPU_ABI)/<檔案路徑>` 變數形式列出 remote `libs/<ABI>/` 內全部檔案；依字母升序；缺欄位則自動 insert |

```makefile
# 更新後
LOCAL_SRC_FILES         := ReaderService_CipherLab_V1_3_104.apk
LOCAL_TARGET_CPU_ABI    := arm64-v8a
LOCAL_PREBUILT_JNI_LIBS := \
    libs/$(LOCAL_TARGET_CPU_ABI)/README \
    libs/$(LOCAL_TARGET_CPU_ABI)/config.json \
    libs/$(LOCAL_TARGET_CPU_ABI)/libIAC.so \
    libs/$(LOCAL_TARGET_CPU_ABI)/libbarcodereader.so
```

更新完畢腳本立即用 grep 驗證 `Android.mk` 已含新內容含。  
- 若有 `--libs` 部署時，  
後續 verify 階段還會比對 `ABI` / `lib list` / `lib files 個別 MD5`。  
`.mk` 若缺 `include $(BUILD_PREBUILT)` 錨點 → `die`。  
`.mk` 原本沒有 `LOCAL_TARGET_CPU_ABI` `LOCAL_PREBUILT_JNI_LIBS`, 腳本會 **自動 insert 到 `include $(BUILD_PREBUILT)` 之前**  
`LOCAL_PREBUILT_JNI_LIBS` 來源是 **remote `libs/<ABI>/` 內全部檔案**（cp 完成後 enumerate，保留既有檔／依字母升序／大小寫敏感／不限副檔名）

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

**cp libs 處理結果（含 --libs 時）：**

```
[05-20 14:30:22] [rs38t] cp libs 處理結果（共 5 檔）：
[05-20 14:30:22]   [ Added ]   libs/arm64-v8a/README
[05-20 14:30:22]   [ Added ]   libs/arm64-v8a/config.json
[05-20 14:30:22]   [Skipped]   libs/arm64-v8a/libIAC.so
[05-20 14:30:22]   [Updated]   libs/arm64-v8a/libbarcodereader.so
[05-20 14:30:22]   [ Added ]   libs/arm64-v8a/sub/libdeep.so
[05-20 14:30:22] OK    [rs38t] libs 處理完成 (Added 3 / Updated 1 / Skipped 1)
```

**Android.mk 更新後接續印出欄位內容：**

```
[05-20 14:30:22] OK    [rs38t] Android.mk 更新完成
  └─ LOCAL_SRC_FILES := ReaderService_CipherLab_V1_3_104.apk
  └─ LOCAL_TARGET_CPU_ABI := arm64-v8a               (僅當 --libs)
  └─ LOCAL_PREBUILT_JNI_LIBS:                         (僅當 --libs)
       libs/$(LOCAL_TARGET_CPU_ABI)/README
       libs/$(LOCAL_TARGET_CPU_ABI)/config.json
       ...
```

**驗證輸出（純 APK，5 項）：**

```
--- 驗證 APK ---
  ✓ APK MD5 驗證通過: a3f9c12d8e4b7f2190ac56de83107b45
--- 驗證 Android.mk LOCAL_SRC_FILES ---
  ✓ LOCAL_SRC_FILES 已更新為 KeyMappingManager_v1.2.3.apk
--- 驗證 commit author ---
  ✓ Author name  : Bob.Lin
  ✓ Author email : Bob.Lin@cipherlab.com.tw
--- 驗證 commit message ---
  ✓ Commit message: SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
  → commit hash: [a3f9c12]

--- 驗證結果摘要 [rk26s] ---
  ✓ PASS    APK MD5
  ✓ PASS    Android.mk LOCAL_SRC_FILES
  ✓ PASS    Commit Author Name
  ✓ PASS    Commit Author Email
  ✓ PASS    Commit Message
[05-20 14:30:25] OK    [rk26s] 驗證全部通過 ✓
```

**含 libs 部署的驗證摘要（8 項）：**

```
--- 驗證結果摘要 [rs38t] ---
  ✓ PASS    APK MD5
  ✓ PASS    Android.mk LOCAL_SRC_FILES
  ✓ PASS    Android.mk LOCAL_TARGET_CPU_ABI = arm64-v8a
  ✓ PASS    Android.mk LOCAL_PREBUILT_JNI_LIBS (5 entries)
  ✓ PASS    JNI Libs files (5 files MD5)
  ✓ PASS    Commit Author Name
  ✓ PASS    Commit Author Email
  ✓ PASS    Commit Message
```

任一項目不符，該項在摘要中標 `✗ FAIL`，該機種標記為失敗，最終 exit code 為 1。Lib 驗證失敗時會列出所有不符檔案完整相對路徑。

**最終 Deploy Result（三類別摘要）：**

```
[05-20 14:30:25] ====== Deploy Result ======
[05-20 14:30:25]   總計: 3  成功: 1  跳過: 1  失敗: 1
[05-20 14:30:25]   成功機種: rs38t
[05-20 14:30:25]   跳過機種: rk26s  (內容與 remote 一致)
[05-20 14:30:25]   失敗機種: rs36s
[05-20 14:30:25]   Log: logs/Caspar-ReaderService_CipherLab-20260520_143022.log
[05-20 14:30:25] ===========================
```

> 每行 `[MM-DD HH:MM:SS]` 是 `log()` 函式統一加上的時間戳——所有輸出（含 Summary / Deploy Result 區塊）都會帶上，螢幕與 log 檔同步。

| 類別 | 何時出現 | 對 staging 清除的影響 |
|---|---|---|
| **成功** | 該機種完整跑完 step 0-6 且全部 PASS | 不阻擋清除 |
| **跳過** | step 1.5 偵測到 APK MD5 + libs MD5 + commit author/email/message 全相符 | 不阻擋清除 |
| **失敗** | 任何步驟出錯（remote 連線異常、push 失敗、verify 不符等） | 阻擋清除，staging 保留供重試 |

Exit code：失敗數 > 0 時為 1，否則為 0（跳過不影響 exit code）。

---

## Log

每次執行 `deploy_apk.sh` 都會在 `logs/` 下自動產生 log 檔：

```
logs/<Author>-<App>-YYYYMMDD_HHMMSS.log
# 例：logs/Caspar-KeyMappingManager-20260520_143022.log
# Dry-run 會多一個 -dryrun 後綴：logs/Caspar-KeyMappingManager-20260520_143022-dryrun.log
```

`batch_deploy.sh` 呼叫多次 `deploy_apk.sh`，每次呼叫各自產生獨立 log。

---

## 設定修改指南

### 1. 修改 Author 資訊

編輯 `config/authors.conf`。  
格式為 `AUTHOR_<Key>="Firstname.Lastname|email"`（駝峰式，FirstName 與 LastName 以 `.` 區隔），Key 即為執行腳本時 `--author` 參數填入的值。

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

**修改部署用的 git branch：**

`BRANCH` 是全域預設值，腳本所有 git 操作（`ls-remote` / `checkout` / `pull` / `push`）都使用此 branch。若特定機種的 branch 不同，可用 `DEVICE_<NAME>_BRANCH` 覆寫，不影響其他機種。

```bash
# 全域預設（所有機種共用）
BRANCH="master"

# 機種專屬覆寫（僅該機種生效）
DEVICE_rk95p_BRANCH="CIPHERLAB_MASTER"
```

優先順序：`DEVICE_<NAME>_BRANCH`（有設定）> `BRANCH`（全域預設）。

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
| `無法連到 remote（git ls-remote 失敗）` | 網路、VPN、auth、URL、remote repo 任一異常 | 解決連線問題後重跑相同指令；該機種不會留下任何 local 變更 |
| `git pull 失敗` | Remote ref 拉取階段斷線或衝突 | 連線恢復後重跑；衝突需手動處理該 repo（`git status` 確認後再執行） |
| `git push 失敗（local commit 已建立）` | Remote 斷線、auth 過期、non-fast-forward 等 | log 會印出 repo / hash / message 與手動 push 指令，依提示在 remote 恢復後手動推送 |
