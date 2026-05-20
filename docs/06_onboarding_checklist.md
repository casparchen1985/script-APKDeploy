# Onboarding Checklists

> 三份檢查清單：**新人首次使用** / **新增機種** / **新增 RD**。
> 印出來用筆勾，或複製到 ticket 內當執行紀錄。

---

## Checklist A — 新 RD 首次使用（一次性）

完成後就能獨立使用工具。

### A.1 帳號與權限
- [ ] 有 `app_dev@192.168.8.17` 的 ssh 權限（公鑰已加入 server 的 `authorized_keys`）
- [ ] 有 GitLab `app-dev/android/automation/scriptapkdeploy` repo 的 read 權限
- [ ] 有各機種 device repo 的 push 權限（master branch）

### A.2 在 server 上拉腳本（若 `~/apk_deploy/` 不存在）
- [ ] `ssh app_dev@192.168.8.17`
- [ ] `git clone git@gitlab.cipherlab.com.tw:app-dev/android/automation/scriptapkdeploy.git ~/apk_deploy`
- [ ] `cd ~/apk_deploy && chmod +x deploy_apk.sh batch_deploy.sh verify_deploy.sh`

### A.3 確認自己已在 `authors.conf`
- [ ] `grep ^AUTHOR_<YourKey> ~/apk_deploy/config/authors.conf`
- [ ] 若沒有 → 走 **Checklist C（新增 RD）**

### A.4 第一次 dry-run（不會動到任何 repo）
- [ ] 準備一支測試 APK 放到 `~/apk_deploy/toBeUploaded/`
- [ ] 跑：
  ```bash
  ./deploy_apk.sh --app <測試 app> \
    --apk ~/apk_deploy/toBeUploaded/<file>.apk \
    --author <YourKey> \
    --message "<JIRA-ID> : [Cipherlab] Update <App> v<Version>" \
    --device rk26s \
    --dry-run
  ```
- [ ] 看到 `Summary` 區塊資訊正確、`[DRY-RUN]` 標記出現、無紅色 ERROR
- [ ] 看到 `Deploy Result` 顯示 `成功: 1`

### A.5 閱讀必要文件
- [ ] 讀過 `README.md`（理解 APK 保留策略、Android.mk 更新規則）
- [ ] 拿一份 `docs/presentation/03_quickref_cheatsheet.md`（可印出來）
- [ ] 知道 `docs/presentation/05_faq.md` 在哪（遇到狀況先翻）

### A.6 加入聯絡群組
- [ ] 加入 deploy 通知群組 / channel
- [ ] 知道遇到問題找誰（主負責 / 副負責）

---

## Checklist B — 新增機種上線

整合一台新機種到自動部署流程。

### B.1 前置確認
- [ ] 機種代號已確認（建議小寫，如 `rk97`）
- [ ] Repo 路徑已確認（如 `~/rk97/LA.QSSI.17.0`）
- [ ] Server 上該 repo 已 clone 且可 `git pull origin master`

### B.2 確認 repo 結構符合腳本預期
- [ ] 存在 `<repo>/vendor/cipherlab/` 目錄（或對應的 `APK_SUBDIR`）
- [ ] 每個要部署的 app 目錄存在，例如 `<repo>/vendor/cipherlab/KeyMappingManager/`
- [ ] 每個 app 目錄內存在 `Android.mk`
- [ ] `Android.mk` 內含 `LOCAL_SRC_FILES := *.apk` 行（格式可有空白）

> 若 repo 結構特殊（如不在 `vendor/cipherlab/` 下），記下完整路徑供下一步用。

### B.3 更新 `config/devices.conf`
- [ ] 加入一行：`DEVICE_<name>="~/<repo-path>"`
- [ ] 若路徑非預設 `vendor/cipherlab/`，加 `DEVICE_<name>_APK_SUBDIR="<custom-path>"`

### B.4 提交設定變更
- [ ] `cd ~/apk_deploy && git add config/devices.conf`
- [ ] `git commit -m "Add device <name> to deploy config"`
- [ ] `git push origin master`
- [ ] 通知其他 RD `git pull` 更新 server 上的 `~/apk_deploy/`

### B.5 驗證新機種可部署
- [ ] 用一支已有版號的測試 APK 跑：
  ```bash
  ./deploy_apk.sh --app <app> --apk <staging-apk> \
    --author <YourKey> --message "<JIRA-ID> : [Cipherlab] Update <App> v<Version>" \
    --device <name> --dry-run
  ```
- [ ] dry-run 通過（無 ERROR、Summary 顯示新機種）
- [ ] 拿掉 `--dry-run` 實際跑一次，確認驗證 5 項全 ✓

### B.6 文件同步
- [ ] 更新 `docs/presentation/03_quickref_cheatsheet.md` 的機種清單表
- [ ] 通知團隊新機種已可用

---

## Checklist C — 新增 / 修改 / 移除 RD

### C.1 新增 RD

- [ ] 決定 Key 名稱（建議駝峰式英文，如 `David`）
- [ ] 編輯 `config/authors.conf`：
  ```bash
  AUTHOR_David="David.Wu|David.Wu@cipherlab.com.tw"
  ```
- [ ] 確認格式：`Firstname.Lastname|email`，**中間用 `|` 分隔**
- [ ] commit + push 到 scriptapkdeploy repo
- [ ] 通知 server 端 `git pull`：`cd ~/apk_deploy && git pull origin master`
- [ ] 通知該 RD 走 **Checklist A**

### C.2 修改 RD 資訊（如 email 改版）

- [ ] 編輯 `config/authors.conf`：直接改該行的 name 或 email
- [ ] commit + push
- [ ] 通知所有 RD `git pull`
- [ ] **舊 commit 不會被修改**，僅後續 deploy 使用新值

### C.3 移除離職 RD

- [ ] 編輯 `config/authors.conf`：**刪除整行**或前面加 `#`
  ```bash
  # AUTHOR_David="David.Wu|David.Wu@cipherlab.com.tw"   # 已離職 YYYY-MM-DD
  ```
- [ ] 檢查現有 `deploy_plan.xml` 是否還有引用：
  ```bash
  grep -r "<author>David</author>" .
  ```
- [ ] 有引用 → 改 author 或刪除該 task
- [ ] commit + push
- [ ] 通知所有 RD `git pull`

> 引用到不存在的 key，腳本會**提前 die**：`authors.conf 中找不到 author key: David`，不會靜默略過。

---

## Checklist D — 每次 release 前 self-check

每次要 push APK 時，快速跑一次：

- [ ] APK 已 scp 到 server 的 `~/apk_deploy/toBeUploaded/`
- [ ] APK 檔名含版號（除非刻意要覆蓋同名）
- [ ] commit message 已想好（描述變更、bug 編號、版號）
- [ ] 目標機種清單已確認（不要漏、也不要多）
- [ ] **第一次先 `--dry-run`**
- [ ] dry-run 通過 → 拿掉 `--dry-run` 正式跑
- [ ] 看到 `Deploy Result` 顯示 `失敗: 0`
- [ ] Staging APK 已自動清除（`ls toBeUploaded/` 確認）
- [ ] 留下 log 檔路徑（如需後續 review）

---

## Checklist E — 含 JNI Libs 的 release（v1.0.2 新增）

當 release 需要附帶 `.so` libs 或其他外部資源檔時，**加跑這份**。

### E.1 staging 準備（本機）

- [ ] APK 已準備
- [ ] Libs 已整成 **單一 ABI 資料夾** 結構：
  ```
  <App>/<dev>/arm64-v8a/   ← 內部任何檔案、子目錄、副檔名都可以
  ```
- [ ] **確認沒誤放** `.DS_Store`、`Thumbs.db` 等 hidden 檔（會被跳過但避免混淆）
- [ ] **避免 symlink**（會被跳過）

### E.2 上傳到 server

- [ ] APK + libs 目錄一起 scp 到 server：
  ```bash
  scp <App>_vX.Y.Z.apk app_dev@192.168.8.17:~/apk_deploy/toBeUploaded/
  scp -r <App>/ app_dev@192.168.8.17:~/apk_deploy/toBeUploaded/
  ```

### E.3 確認 .mk 條件

- [ ] 目標 repo 的 `<App>/Android.mk` 含 `include $(BUILD_PREBUILT)`（自動 insert 需要這個錨點）

### E.4 部署

- [ ] **先 `--dry-run`**，預覽：
  - [ ] `Summary` 顯示 `Libs ABI: <abi-name> (N 個檔案)` 正確
  - [ ] 逐檔 `[ Added ]` / `[Updated]` / `[Skipped]` 標籤合理
  - [ ] `.mk` 預期欄位（LOCAL_TARGET_CPU_ABI、LOCAL_PREBUILT_JNI_LIBS）內容正確
- [ ] 拿掉 `--dry-run` 正式跑
- [ ] 驗證階段顯示 **8 項全 ✓ PASS**（含 lib 相關 3 項）
- [ ] Staging APK 與 libs 已自動清除

### E.5 失敗時排查

| 訊息 | 處理 |
|---|---|
| `--libs 路徑為空目錄` | 確認 ABI 資料夾內有檔案 |
| `--libs 路徑不合理（basename 為 . / ..）` | 不要用 `.` 或 `..` 當路徑 |
| `Android.mk 缺 include $(BUILD_PREBUILT) 錨點` | 手動在 `.mk` 補上該行後重跑 |
| `JNI Libs files MD5 失敗` | log 會列出全部不符檔案，比對 staging 與 remote 內容差異 |

---

## 附錄：標準 commit message 格式建議

雖然腳本不強制，**團隊內建議統一格式**：

```
<JiRA ID> : [Cipherlab] Update <App Name> v<Version>
```

範例：

- `SW_CLUTY-381 : [Cipherlab] Update EnterpriseService v1.0.61`
- `SW_CLUTY-397 : [Cipherlab] Update EZEdit v1.3.5`
- `SW_CLUTY-392 : [Cipherlab] Update Terminal Emulator v1.2.7`

避免：

- subject 太長（細節寫在 git body）
