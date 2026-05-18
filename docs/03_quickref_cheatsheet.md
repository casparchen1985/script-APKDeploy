# APK Deploy 速查卡（一頁式）

> 印一張放桌上，常用指令、參數、錯誤排查一次看完。

---

## 0. 環境

| 項目 | 值 |
|---|---|
| Upload server | `app_dev@192.168.8.17` |
| 腳本位置 | `~/apk_deploy/` |
| Staging 目錄 | `~/apk_deploy/toBeUpload/` |
| Repo 位置 | `git@gitlab.cipherlab.com.tw:app-dev/android/automation/scriptapkdeploy.git` |

---

## 1. 三步驟標準流程

```bash
# (本機) 1. 上傳 APK
scp <App>_vX.Y.Z.apk app_dev@192.168.8.17:~/apk_deploy/toBeUpload/

# (server) 2. 先 dry-run
ssh app_dev@192.168.8.17
cd ~/apk_deploy
./deploy_apk.sh --app <App> --apk ~/apk_deploy/toBeUpload/<App>_vX.Y.Z.apk \
                --author <Key> --message "<commit msg>" \
                --device <d1> <d2> <d3> --dry-run

# (server) 3. 沒問題拿掉 --dry-run，正式跑
./deploy_apk.sh --app <App> --apk ~/apk_deploy/toBeUpload/<App>_vX.Y.Z.apk \
                --author <Key> --message "<commit msg>" \
                --device <d1> <d2> <d3>
```

---

## 2. deploy_apk.sh 參數

| 參數 | 必填 | 範例 | 說明 |
|---|---|---|---|
| `--app` | ✓ | `KeyMappingManager` | repo 內 module 目錄名稱（大小寫敏感） |
| `--apk` | ✓ | `~/apk_deploy/toBeUpload/KMM_v1.2.3.apk` | staging APK 完整路徑 |
| `--author` | ✓ | `Caspar` | `authors.conf` 的 key |
| `--message` | ✓ | `"Update KMM v1.2.3: fix ..."` | git commit message |
| `--device` | ✓ | `rk26s rs36s rk95u` | 一或多個機種，空格分隔 |
| `--dry-run` | — | — | 印步驟不執行，**強烈建議第一次先跑** |
| `--no-verify` | — | — | 跳過自動驗證（不建議） |

---

## 3. 機種清單（`config/devices.conf`）

| Key | Repo | Key | Repo |
|---|---|---|---|
| `rk26s` | `~/rk26s/LA.QSSI.12.0` | `rs38t` | `~/rs38t/titan_qssi13` |
| `rk26u` | `~/rk26plus/LA.QSSI.14.0.R1` | `rs38v` | `~/rs38v/titan_qssi15` |
| `rs35q` | `~/rs35` | `rk95p` | `~/rk95` |
| `rs35r` | `~/rs35r` | `rk95s` | `~/rk95s` |
| `rs36s` | `~/rs36s/LA.QSSI.12.0` | `rk95u` | `~/rk95u` |
| `rs36u` | `~/rs36plus/LA.QSSI.14.0.R1` | `rk96v` | `~/rk96v/LA.QSSI.15.0` |

> 新增機種：在 `config/devices.conf` 加一行 `DEVICE_<name>="~/path"`，立即可用。

---

## 4. RD Key 清單（`config/authors.conf`）

| Key | Author |
|---|---|
| `Jiachuan` | Jiachuan.Lin |
| `Caspar` | Caspar.Chen |
| `Howard` | Howard.Lu |
| `Ocer` | Ocer.Wu |
| `Ryu` | Ryu.Li |
| `Eric` | Eric.Lai |
| `Miller` | Miller.Pan |
| `Nicole` | Nicole.Weng |
| `Kevin` | Kevin.Kuan |
| `Henry` | Henry.Tung |

> 沒看到自己？在 `authors.conf` 加一行 `AUTHOR_<Key>="Firstname.Lastname|email"`。

---

## 5. APK 檔名版號規則

| 檔名 | 判定 | 行為 |
|---|---|---|
| `KMM_v1.2.3.apk` | 有版號 | 新舊版共存 |
| `KMM_1.2.3.apk` | 有版號 | 新舊版共存 |
| `KMM_20250513.apk` | 有版號 | 新舊版共存 |
| `KMM_20250513143022.apk` | 有版號 | 新舊版共存 |
| `KMM.apk` | 無版號 | 同名覆蓋 |

---

## 6. 批次部署

```bash
# 1. 複製 template 為實際 plan
cp deploy_plan.xml.template deploy_plan.xml

# 2. 編輯 deploy_plan.xml，每個 <task> = 一支 app
vim deploy_plan.xml

# 3. 跑批次（先 dry-run）
./batch_deploy.sh --plan deploy_plan.xml --dry-run
./batch_deploy.sh --plan deploy_plan.xml
```

---

## 7. 獨立驗證（不部署）

```bash
./verify_deploy.sh \
  --app <App> --apk ~/apk_deploy/toBeUpload/<App>_vX.Y.Z.apk \
  --author <Key> --message "<原本 commit msg>" \
  --device <d1> <d2> <d3>
```

驗證四項：APK MD5 / Android.mk / commit author / commit message。
**Staging APK 必須仍在 `toBeUpload/`** 作為 MD5 比對基準。

---

## 8. 常見錯誤排查

| 錯誤訊息 | 原因 | 解法 |
|---|---|---|
| `找不到 APK 檔案` | path 拼錯 / staging 已被清 | 確認 `ls toBeUpload/` |
| `找不到 Android.mk` | `--app` 與 repo 目錄名不符（大小寫） | 對齊 `vendor/cipherlab/<dir>` 名稱 |
| `Android.mk 更新失敗` | `.mk` 缺 `LOCAL_SRC_FILES` 行 | 手動補上後重跑 |
| `APK MD5 不符` | scp 傳輸中斷 | 重新 scp + 重跑 |
| `authors.conf 中找不到 author key` | key 拼錯 / RD 還沒設定 | 修 `--author` 或補 conf |
| `devices.conf 未定義機種` | device 拼錯 / 還沒登錄 | 修 `--device` 或補 conf |
| `Commit message 不符` | 部署中途別人 push 進來了 | 看 `git log -1`，與相關 RD 協調 |

---

## 9. Log 位置

```
~/apk_deploy/logs/deploy_YYYYMMDD_HHMMSS.log
```

回報問題時請附對應 log，含時間戳記方便對照。

---

## 10. 緊急聯絡

| 角色 | 聯絡 |
|---|---|
| 主負責 | Caspar.Chen |
| GitLab Repo | `app-dev/android/automation/scriptapkdeploy` |
