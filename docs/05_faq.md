# 預想 Q&A

---

## A. 使用與權限

### Q1. 誰可以執行這個腳本？我需要什麼權限？

**短答**：只要能 ssh 進 `app_dev@192.168.8.17`，並且你的 key 已經在 `authors.conf` 中。

**延伸**：
- 腳本不檢查身份，**任何能 ssh 的人都可以執行**。
- `--author` 帶的 key 不需與當前 ssh user 對應，因此**規範上請填自己**，違規 commit 會在 git log 中留下證據。
- 若需嚴格限制，未來可考慮加上 `--author` 與 `$USER` 對照表的檢查。

---

### Q2. 我可以假冒別人 push 嗎？

**短答**：技術上可以（只要對方 key 存在於 `authors.conf`），但 **git log 會永久留紀錄**，這是流程信任，不是技術限制。

**延伸**：和直接用 `git commit --author=...` 是同樣的信任模型。如果團隊有疑慮，可加上 hook 或 server-side 檢查。

---

### Q3. `--device` 我每次都要打一長串，可不可以設預設值？

**短答**：刻意沒有預設值，因為**同一支 app 每次推送的目標機種都可能不同**，避免無意中推到不該推的機種。

**延伸**：
- 想固定組合 → 用 `deploy_plan.xml` 存起來，下次 `--plan` 帶入即可。
- 或在自己 home 寫個 alias / shell function 包裝。

---

### Q4. 部署中途我可以中斷嗎？會留下半成品嗎？

**短答**：Ctrl+C 中斷時，**已完成的機種已 push 出去**，未完成的不會動到。Staging APK 會被保留供重試。

**延伸**：
- 若中斷時剛好在某機種的中段（例如 Android.mk 改完但 push 失敗），**該機種會留下 dirty working tree**，需手動 `git checkout .` 或 `git reset --hard origin/<branch>`（`<branch>` 見 `devices.conf`）。
- 重跑相同指令時，腳本會 `git checkout <branch> && git clean -fd && git pull`，**會清掉 dirty state**。

---

## B. 失敗與回滾

### Q5. 某台機種 push 失敗了，其他機種會怎樣？

**短答**：其他機種**繼續**部署，失敗的機種會列在最終 `Deploy Result` 區塊，exit code 為 1。

**延伸**：
- Staging APK + libs 會被保留（因為「無失敗」條件未達成）。
- push 失敗的機種：local commit 保留不 rollback（見 Q7），log 印出 repo / hash / 手動 push 指令。
- 修好 remote 後**重跑相同指令**即可——SKIPPED 偵測會自動把各機種分類：
  - 上一輪已部署完成（HEAD 已推送）的機種 → step 1.5 五項全符 → **歸 `跳過`**
  - 上一輪 push 失敗（local 有未推送 commit）的機種 → SKIPPED 第 3 條件 `HEAD == origin/<branch>` 不過 → 走正常流程，但 step 5a 會因 working tree 已是 commit 後的乾淨狀態而 nothing-to-commit → **歸 `失敗`**，需要手動補救
  - 上一輪就已 SKIPPED 過的機種 → 仍然 `跳過`
- 不需要手動從 `--device` 拿掉任何機種；SKIPPED 偵測會自動處理。

**push 失敗機種的補救方式**（擇一）：
- **方式 A（推薦）**：依 log 的「後續」提示手動 `cd <repo> && git push origin <branch>` 把那個 local commit 推上去；下次重跑該機種會被 SKIPPED 通過
- **方式 B**：`cd <repo> && git reset --hard origin/<branch>` 砍掉 local commit，下次重跑會走完整 step 2-6 流程

> `<branch>` 來自 `devices.conf` 全域 `BRANCH` 或 `DEVICE_<NAME>_BRANCH` 覆寫；log 印出的「後續」提示已含正確 branch 名稱，直接複製貼上即可。

---

### Q6. 部署錯了能不能 rollback？

**短答**：腳本本身**不提供 rollback**。請手動：

```bash
ssh app_dev@192.168.8.17
cd ~/<device-repo>
git revert <wrong-commit>   # 或 git reset --hard <good-commit>
git push origin <branch>    # <branch> 對應該機種在 devices.conf 的設定（預設 master）
```

**延伸**：
- 因為 APK 檔名含版號者**不會覆蓋舊版**，只需要把 `Android.mk` 改回舊版檔名即可生效。
- 若是無版號的覆蓋情境，舊 APK 已被覆蓋，需要從 build server 重新取得。
- 多機種 rollback 沒有對應工具，建議盡量在 dry-run 階段就攔住問題。

---

### Q7. 如果我 push 到一半 server 斷網了？

**短答**：該機種被歸到 FAILED、其他機種繼續部署。**Local commit 保留不 rollback**，腳本會印出 repo 路徑、commit hash、commit message 與手動 push 指令（log 也會留）；staging APK 保留。

**延伸**：v1.0.4 起，`git push` 失敗會具體印出：

```
ERROR [rs38t] git push 失敗（exit code 非零）
ERROR [rs38t] 注意：local commit 已建立但未推送至 remote，請手動處理：
ERROR [rs38t]     Repo    : /home/app_dev/rs38t/titan_qssi13
ERROR [rs38t]     Branch  : master
ERROR [rs38t]     Hash    : a3f9c12
ERROR [rs38t]     Message : SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3
ERROR [rs38t]     後續    : remote 恢復後執行 cd '/home/app_dev/rs38t/titan_qssi13' && git push origin master
```

兩種補救方式：
1. **直接 push**：remote 恢復後依提示貼上後續指令即可推送原本的 commit。
2. **重跑相同部署指令**：腳本會先 `git pull origin <branch>` fast-forward，但本地未 push commit 可能會擋住——此時需 `cd <repo> && git reset --hard origin/<branch>` 後再重跑（這會丟掉那個 commit，由腳本重新建立）。`<branch>` 即 `devices.conf` 中該機種的設定。

---

### Q8. 我把 author key 拼錯，commit 已 push 出去了，怎麼辦？

**短答**：驗證階段會 `✗ Author name 不符` 並 exit 1，但 commit 已經在 remote 了。請手動：

```bash
git commit --amend --author="Correct.Name <correct@cipherlab.com.tw>"
git push --force-with-lease origin <branch>    # <branch> 對應該機種在 devices.conf 的設定
```

**延伸**：force push 到部署 branch 需要與其他 RD 協調（避免覆蓋別人的 commit）。

---

## C. 設定與擴充

### Q9. 我的機種還沒在 `devices.conf` 內，怎麼加？

**短答**：

```bash
# 1. 編輯 config/devices.conf
echo 'DEVICE_rk97="~/rk97/LA.QSSI.17.0"' >> config/devices.conf

# 2. 確認 repo 已 clone 到 server
ls ~/rk97/LA.QSSI.17.0/

# 3. dry-run 確認
./deploy_apk.sh --device rk97 ... --dry-run
```

**延伸**：完整流程見 `06_onboarding_checklist.md` 的「新增機種 Checklist」。

---

### Q10. 不同機種的 APK 放置路徑不一樣怎麼辦？

**短答**：用 `DEVICE_<NAME>_APK_SUBDIR` 覆寫該機種的路徑。

```bash
# devices.conf
APK_SUBDIR="vendor/cipherlab"                     # 全域預設
DEVICE_rk25_APK_SUBDIR="android/vendor/cipherlab/prebuilt/rk25"  # rk25 專屬
```

優先順序：機種專屬 > 全域。未設定者自動 fallback 全域，**不必每個機種都寫**。

---

### Q10.1. 不同機種的 git branch 不一樣怎麼辦？

**短答**：用 `DEVICE_<NAME>_BRANCH` 覆寫該機種的 branch。

```bash
# devices.conf
BRANCH="master"                          # 全域預設
DEVICE_rk95p_BRANCH="CIPHERLAB_MASTER"   # rk95p 專屬
```

優先順序：機種專屬 > 全域。未設定者自動 fallback 全域。

**延伸**：影響範圍是腳本內所有 git 操作（`ls-remote` / `checkout` / `pull` / `push`），以及 SKIPPED 偵測第 3 條件 `HEAD == origin/<branch>` 與 push 失敗時印出的「後續」提示——都會自動帶入該機種的設定值，RD 看到什麼貼什麼即可，不必記得對應的 branch。

---

### Q11. `--app` 跟 APK 檔名前綴可以不一樣嗎？

**短答**：可以。`--app` 對應的是 **repo 內 module 目錄名稱**，不是 APK 檔名。

**延伸**：

```
vendor/cipherlab/key_mapping_mgr/   ← module 目錄
└── KeyMappingManager_v1.2.3.apk     ← APK 檔名
```

部署指令：

```bash
./deploy_apk.sh --app key_mapping_mgr --apk KeyMappingManager_v1.2.3.apk ...
```

---

### Q12. 我可以一次部署多支 APK 嗎？

**短答**：用 `batch_deploy.sh` + `deploy_plan.xml`，每個 `<task>` 對應一支 app。

**延伸**：批次只是 wrapper，每個 task 等同呼叫一次 `deploy_apk.sh`，**互相獨立**：某 task 失敗不影響後續 task。

---

## D. 整合與自動化

### Q13. 能不能跟 Jenkins / GitLab CI 整合？

**短答**：可以。腳本是純 bash + 標準參數，CI 直接呼叫即可。

**延伸**：
- CI 需有 ssh 進 server 的權限，或腳本搬到 CI runner 上跑（需 mount repo 與 staging dir）。
- `--no-verify` 可在 CI 已有外部驗證時略過。
- log 檔可作為 build artifact 上傳。
- **目前還沒做 CI 整合**，若有需求請提出。

---

### Q14. 能不能跟 build server 整合，build 完直接 deploy？

**短答**：技術上可行，但目前設計**刻意把 build 與 deploy 拆開**。

**延伸**：
- Build 失敗不會誤觸 deploy。
- RD 可在 deploy 前人工確認 APK 內容（如版號、簽章）。
- 若要整合，建議 build 完將 APK 放到 `toBeUploaded/` 並通知 RD，由 RD 主動跑 deploy。

---

### Q15. 為什麼用 XML 不用 YAML / JSON？

**短答**：python3 內建 `xml.etree.ElementTree`，**零外部依賴**。

**延伸**：
- YAML 需要 `pyyaml`，server 不一定有。
- JSON 不支援多行字串註解，commit message 有冒號 / 斜線可能需跳脫。
- XML 用 `<![CDATA[...]]>` 可包任何特殊字元，commit message 寫起來最直覺。

---

## E. 觀察與審計

### Q16. 怎麼查歷史上誰部署了什麼？

**短答**：兩個來源：

1. `~/apk_deploy/logs/<AuthorKey>-<AppName>-YYYYMMDD_HHMMSS[-dryrun].log`（每次執行）
2. 各機種 repo 的 `git log`（commit author / message / hash）

**延伸**：log 檔不進版控（在 `.gitignore`），目前**僅存在 server 上**。長期保留 / 集中分析需要另外設計（例如 rsync 到中央 storage）。

---

### Q17. 我要怎麼知道某機種上目前是哪一版 APK？

**短答**：

```bash
ssh app_dev@192.168.8.17
cd ~/<device-repo>/vendor/cipherlab/<App>/
ls -la *.apk
cat Android.mk | grep LOCAL_SRC_FILES
```

或對應 git：

```bash
git log -1 --pretty=format:"%h %an %s" -- Android.mk
```

---

### Q18. 驗證項目可以加嗎？例如 APK 簽章、版號比對？

**短答**：可以，目前在 `verify_device()` 函式內加分支即可。

**延伸**：
- 簽章驗證：`apksigner verify <apk>`，需 server 上有 apksigner。
- 版號比對：`aapt dump badging <apk> | grep versionName`，可確保 APK 內版號與檔名一致。
- 歡迎提需求，**驗證項目擴充風險低**（只加檢查不改流程）。

---

## F. 邊界情境

### Q19. APK 檔名有空白或特殊字元會怎樣？

**短答**：路徑與檔名都已用 `"..."` 包覆，**理論上安全**，但**不建議使用空白檔名**。

**延伸**：版號識別 regex 對 `_v1.2.3` 與 `_20250513` 等格式有效，**其他自訂後綴可能被判定為「無版號」而覆蓋**。

---

### Q20. 如果 `deploy_plan.xml` 的 `<message>` 含有 `<` `>` `&` 怎麼辦？

**短答**：用 CDATA 包起來。

```xml
<message><![CDATA[Fix a > b logic & nullptr bug]]></message>
```

> 採用團隊標準格式 `<JIRA-ID> : [Cipherlab] Update <App> v<Version>` 時通常不會出現 `<`/`>`/`&`，多數情況下不需要 CDATA。此 Q 留作邊界處理參考。

---

### Q21. `git pull` 衝突的話腳本怎麼處理？

**短答**：腳本會在 `git pull` 失敗時把該機種歸到 FAILED 並 `return 1`（**不嘗試自動解衝突、不中斷其他機種**），log 印出 `git pull 失敗（exit code 非零），跳過此機種`。

**延伸**：因為 `git checkout <branch> && git clean -fd` 已先做了，正常情況不應有 conflict（除非有人在 server 上手動改了該 repo）。發生時請手動處理該 repo（`git status` 確認 → 解衝突或 `git reset --hard origin/<branch>`）再重跑相同指令。Staging APK + libs 會自動保留供重試。`<branch>` 對應該機種在 `devices.conf` 的設定。

---

### Q22. 同時有兩個人跑 deploy 會怎樣？

**短答**：腳本**沒有 lock**。兩人同時跑同一機種有機率：

- 一方 push 被拒（remote tip changed，non-fast-forward），該機種會被歸到 FAILED 並 return 1，**local commit 保留**並印出手動 push 提示（見 Q7）。
- 另一方成功後，第一方重跑時會 `git pull` 對齊。重跑前需先處理那個未推送的 local commit（`git reset --hard origin/<branch>` 丟棄，或先手動 `git push --force-with-lease` 推上去）。

**延伸**：建議 release window 有人協調，目前**沒有看到實際衝突**過。長期可加 file lock。

---

### Q23. Server 上的 repo 被別人手動 push 了 commit，會被洗掉嗎？

**短答**：**不會**。腳本只在自己這次部署的範圍內 commit，`git pull origin <branch>` 會先拉下別人的 commit。

**延伸**：但若別人剛好 push 了相同 `Android.mk` 的改動，腳本的 Python 改寫可能會產生 merge conflict — 此時 `git pull` 失敗，該機種歸到 FAILED 並 `return 1`（不中斷其他機種，staging 自動保留供重試，見 Q21）。

---

## G. JNI Libs 部署（v1.0.2 新增）

### Q24. `--libs` 路徑要指到哪一層？

**短答**：指到 **ABI 資料夾本身**（如 `arm64-v8a`），且**必須位於 `toBeUploaded/` 之下**。

```
toBeUploaded/<App>/<dev>/arm64-v8a/    ← --libs 指這裡
└── (內部任何結構由 RD 自理)
```

basename 就會被腳本拿去當 `LOCAL_TARGET_CPU_ABI` 的值，所以 ABI 資料夾名稱就**等於**該 ABI 設定。

**為什麼強制要在 `toBeUploaded/` 之下？** 因為部署成功後腳本會 `rm -rf "${LIBS_PATH}"`，限制路徑可避免誤刪外部資料。

---

### Q25. 內部可以放哪些檔案？

**短答**：**任何檔案**。`.so` / `.txt` / `.json` / 沒副檔名 / 多層子目錄都接受。

腳本只做兩件事：
- 跳過 hidden 檔（`.` 開頭）與 symlink
- 遞迴枚舉其他所有檔案

---

### Q26. 重新部署時，舊的 lib 會被刪嗎？

**短答**：**不會**。腳本絕不刪除 remote 既有檔案／資料夾。

逐檔判定：
- local 有，remote 無 → 新增
- local 有，remote MD5 同 → 略過
- local 有，remote MD5 異 → 覆蓋
- local 無，remote 有 → **保留**

---

### Q27. `LOCAL_PREBUILT_JNI_LIBS` 的清單怎麼來的？

**短答**：**部署完 cp 結束後**，掃描 remote `libs/<ABI>/` 下**全部檔案**，組成清單寫進 `.mk`。

因為 Q26「不刪 remote」，所以清單會自動包含「舊 lib + 新 lib + 沒動的 lib」。RD 不用維護這個列表。

---

### Q28. `.mk` 原本沒有 `LOCAL_TARGET_CPU_ABI` 或 `LOCAL_PREBUILT_JNI_LIBS` 行怎麼辦？

**短答**：腳本**自動 insert** 到 `include $(BUILD_PREBUILT)` 之前。

若連 `include $(BUILD_PREBUILT)` 都找不到 → `die`（.mk 結構不合預期）。

---

### Q29. 兩個機種的 lib 不一樣（一個要 arm64-v8a 一個要 armeabi-v7a）？

**短答**：分開跑兩次 `deploy_apk.sh`，各指各自的 `--libs`。

目前一次部署只支援單一 ABI（即 `--libs` 直接指到的那個資料夾）。

---

### Q30. 我可以把 `arm64-v8a/` 與 `armeabi-v7a/` 放在同一個 parent 下嗎？

**短答**：可以。腳本不在意 `--libs` 同層 sibling 資料夾有什麼，只看 `--libs` 直接指到的那個。

```
toBeUploaded/<App>/
├── arm64-v8a/      ← --libs 指這裡部署 arm64
└── armeabi-v7a/    ← 下次部署用 --libs 指這裡
```

---

## H. Remote 連線異常處理（v1.0.4 新增）

### Q31. v1.0.4 加了什麼？為什麼要加？

**短答**：每個動 remote 的 git 步驟（`ls-remote` 預檢、`pull`、`push`）都加上**顯式 exit code 檢查**，避免 `set -e` 在函式被 `if` 呼叫時整段失效的 bash 陷阱。

**延伸**：v1.0.3 以前，`deploy_device` 內部完全依賴 `set -e` 自動 abort。但主迴圈是 `if deploy_device "${dev}"; then ...`（為了收集失敗機種、不中斷整批），這個 `if` 會讓 bash 把函式內 `set -e` 整段視為**已禁用**。後果：

- `git pull` 因 remote 斷線失敗時，`run` 內 subshell exit 非零，但函式不 abort，繼續往下跑
- log 反而印出 `OK [${dev}] repo 已同步到最新 <branch>`（假成功）
- 後續以**過時的 branch** 做 cp / 改 Android.mk / commit
- `git push` 同樣失敗，但又繼續往下，`OK [${dev}] push 完成`（再次假成功）
- verify_device 檢查的是 HEAD（包含未推送的 local commit），全部 PASS
- 主流程判斷「全機種成功」→ `rm` 掉 staging APK + libs

最糟結果：**RD 看到「全部成功」訊息，但 remote 上其實沒有任何 commit，且原檔已被刪除**。多 RD 共用同一 server 時，未推送 commit 還會在各機種 local branch 累積。

v1.0.4 在三處補上 `|| { err; return 1; }` 顯式檢查，繞過這個陷阱。

---

### Q32. `git ls-remote` 預檢做什麼？跟 `git pull` 不會重複嗎？

**短答**：`ls-remote` 是 **read-only 純查詢**，~幾十 ms，目的是**動 local working tree 之前先確認 remote 通**。

**延伸**：

- `git pull` = fetch + merge，跑起來涉及 download object + merge working tree，是有破壞性的操作
- 直接靠 `git pull` 失敗來判斷 remote 是否壞掉，會在它之前的 `git clean -fd` 已經跑過（雖然本腳本流程無害，但語意上「動 local 之前先確認 remote」更乾淨）
- `ls-remote --exit-code origin <branch>` 只查 remote 的 refs（`<branch>` 來自 `devices.conf`）：
  - 連不上 / DNS 錯 / VPN 沒開 / auth 過期 / URL 變了 → 非零
  - `--exit-code` 旗標讓「remote 沒有 `<branch>` 這個 ref」也回非零
  - 不下載任何 object、不動 local 狀態
- 預檢成功不代表 `git pull` 一定成功（remote 可能在預檢與 pull 之間斷掉，雖然罕見），所以 `git pull` 後**仍然要**檢查 exit code

兩個檢查不是重複，是分工：
- `ls-remote`：早期 fail-fast，免做後續 file system 動作
- `git pull` 顯式檢查：防 race / 雙重保險

**Remote 死機（不是斷線）會怎樣？** git 走 SSH，本身沒有應用層 timeout——如果 TCP 已建立但對方 sshd hang，預設會**無限等下去**。本腳本在開頭：

```bash
export GIT_SSH_COMMAND="ssh -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3"
```

| 設定 | 效果 |
|---|---|
| `ConnectTimeout=10` | TCP 連線階段 10 秒放棄 |
| `ServerAliveInterval=5` | 連線建立後每 5 秒送 keepalive |
| `ServerAliveCountMax=3` | 連續 3 次（15 秒）無回應視為斷線 |

最壞情境上限約 **25 秒**（10 connect + 15 keepalive）；超時後 ssh 以非零 exit code 返回 → 落入 `|| { err; return 1; }` 分支 → 該機種歸 FAILED，其他機種繼續。**此 export 對所有走 ssh 的 git 操作生效**（ls-remote / pull / push / fetch 都一樣受 timeout 保護）。

---

### Q33. 為什麼 `git push` 失敗不 rollback local commit？

**短答**：保留 local commit + 明確提示 RD 手動 push，比起 `git reset --hard HEAD~1` 默默丟掉 commit 更穩妥。

**延伸**：

- Rollback 的話 RD 看不到「我已經做完了一個 commit」這件事，重跑時還要重新做一次
- 不 rollback 的話，commit 是現成的，remote 恢復後**一行指令就能 push** 上去
- 風險點：未推送 commit 會卡住下次 `git pull` 的 fast-forward。腳本在 log 已明確標示這點 + 給出補救指令
- Log 同時印螢幕（紅字 `ERROR`）與寫入 `logs/<Author>-<App>-...log`，事後追查可靠

完整提示訊息範本見 Q7。

---

### Q34. v1.0.4 之前部署的機種有沒有殘留？要怎麼檢查？

**短答**：如果遠端確實曾經斷過、且當時用 v1.0.3 部署過，**可能有未推送的 local commit 累積在某些機種 repo**。

**延伸**：逐 device repo 檢查：

```bash
ssh app_dev@192.168.8.17
for d in ~/rk26s/LA.QSSI.12.0 ~/rs36s/LA.QSSI.12.0 ~/rs38t/titan_qssi13 ...; do
  echo "=== $d ==="
  # 用 @{u}（當前 branch 的 upstream）比對，無需 hard-code branch 名稱
  git -C "$d" log @{u}..HEAD --oneline
done
```

有輸出的 repo 就是有未推送 commit。確認 commit 內容無誤後 `git -C <repo> push`（或 `git -C <repo> push origin HEAD`），或要丟棄就 `git -C <repo> reset --hard @{u}`。

---

## I. SKIPPED 偵測（重跑安全）

### Q35. SKIPPED 是什麼？什麼時候會出現？

**短答**：當該機種已經部署過完全相同的內容、且 HEAD 已推送到 remote 時，腳本自動偵測並標記為 SKIPPED，不執行 step 2-6（cp / Android.mk / commit / push / verify）。

**延伸**：偵測時機在 `git pull` 後（step 1.5），比對 5 項：

1. `<APK_DEST_DIR>/<APK_FILENAME>` 存在 + staging APK MD5 == remote APK MD5
2. `--libs` 提供時，staging 內**每個** `LIB_FILES` 對應 remote 的檔案 MD5 必須一致
3. `HEAD == origin/<branch>`——HEAD 必須等於 remote tip（避免 push-fail 後 local 有未推送 commit 時誤觸 SKIPPED；見 Q36）。`<branch>` 來自 `devices.conf`。
4. HEAD commit author name + email == `--author` 經 authors.conf 查表後的 name + email
5. HEAD commit message == `--message` 參數

**全部 5 項相符** → `return 2` → 主流程把該機種歸 `SKIPPED`，最終摘要顯示三類別（成功/跳過/失敗）。

---

### Q36. 為什麼要加 SKIPPED？跟 v1.0.4 修的 set -e bug 有關嗎？

**短答**：有關。v1.0.4 把 `set -e` 失效的 bug 修好後，「重跑已成功機種」的場景**會被誠實標為 FAILED**（因 `git commit` 報 nothing to commit），但這對 RD 來說有點誤導——該機種其實是「沒事可做」而非「失敗」。SKIPPED 就是用來把這種「無需重做」的情況正確分類。

**延伸**：以前（v1.0.3）的「假成功」流程是：

```
重跑 rk26s（已部署完成）→ commit nothing → set -e 失效繼續跑
                       → push no-op → verify 對的是上次的 HEAD → 全部 PASS
                       → 標為「成功」
```

v1.0.4 修好後：

```
重跑 rk26s（已部署完成）→ commit nothing → return 1 → 標為「失敗」
```

雖然「誠實」但 RD 看起來很困惑。SKIPPED 偵測在 step 1.5 就把這種情況攔住，**讓「重跑」不會被誤標 FAILED**。

**`HEAD == origin/<branch>` 這條的特殊用途**：v1.0.4 之後 push 失敗會保留 local commit（不 rollback）。如果 SKIPPED 只比對 local 屬性（APK MD5 + commit author/email/message），「commit 完成但 push 失敗」的機種重跑時會**看起來全部符合**而被誤標 SKIPPED——但實際上 remote 根本沒這個 commit！加上 HEAD 必須等於 remote tip 這條，就把這種「local 一致、remote 不同步」的狀態擋掉，正確走回 FAILED 流程，由 RD 手動處理。

---

### Q37. SKIPPED 機種會跑 verify 嗎？會被算進「成功」總數嗎？

**短答**：**不會跑 verify**。會獨立歸到「跳過」這一類，**不計入「成功」也不計入「失敗」**。

**延伸**：

- SKIPPED 條件本身已涵蓋 verify 的核心檢查（APK MD5、commit author/email/message、libs MD5），跑 verify 等於重複比對
- 最終 `Deploy Result` 是三類別獨立統計：`總計: 3  成功: 1  跳過: 1  失敗: 1`
- Exit code 仍以「失敗數是否為 0」決定（SKIPPED 不影響 exit code）

---

### Q38. SKIPPED 會阻擋 staging 清除嗎？

**短答**：**不會**。Staging 清除規則是「FAILED 為空 → 清除」，SKIPPED 不阻擋。

**延伸**：

| 機種狀態組合 | Staging 行為 |
|---|---|
| 全 SUCCESS | 清除 |
| SUCCESS + SKIPPED | 清除 |
| 全 SKIPPED（全都已部署過） | 清除 |
| 任一 FAILED | 保留 |

「全 SKIPPED」也清除的理由：那代表 staging 上的 APK / libs 已經到位所有目標機種，留著沒意義。

---

### Q39. 我想強制重新部署，但 APK + message 都跟之前一樣，怎麼辦？

**短答**：把 `--message` 改一個字（如加上 ` (retry)`）就會繞過 SKIPPED 偵測。

**延伸**：SKIPPED 偵測的 4 個條件**任一不符**就會走正常流程。常見「強制重做」手法：

- 改 `--message`（最輕量，commit message 一旦不同就會觸發正常 commit + push 流程）
- 改 `--author`（不建議，commit 紀錄要實事求是）
- 換不同檔名的 APK（如版號 bump）
- 直接 ssh 進該 device repo 手動 `git reset --hard HEAD~1` 把上次的 commit 砍掉再重跑

最常見場景：上次部署的 commit 推上去後發現要重做（例如 build artifact 其實是錯的），這時 APK 內容很可能會不同（重新 build 的 binary），MD5 自動不同 → SKIPPED 偵測自動不觸發。

---

### Q40. SKIPPED 偵測會不會誤判？例如別人手動 push 了一個 commit 之後再跑這個腳本？

**短答**：**會**——如果別人的 commit 巧合地有相同的 author + message + APK MD5（極不可能但理論上存在）就會 SKIPPED；正常情境下其他人 push 的 commit 通常 message 或 author 都不同，會觸發正常流程。

**延伸**：SKIPPED 比對的是 **HEAD 的 commit**，所以只能偵測「最後一個 commit 是不是這次部署的結果」。若部署完成後別人又 push 了新 commit，HEAD 變成別人的，SKIPPED 偵測會失準（看到不同的 author/message → 不 SKIP → 走正常流程）。這是預期行為，不算誤判。

---

## J. 路線圖（如果被問到「未來會加什麼」）

- **CI 整合**：build server build 完自動丟 staging（需求待確認）
- **驗證擴充**：apksigner 簽章、aapt 版號比對（低風險，可隨時加）
- **集中 log**：rsync 到中央 storage 或寫到 GitLab CI artifact
- **權限收斂**：`--author` 對照 `$USER`，避免 typo / 假冒
- **Slack/Mail 通知**：成功 / 失敗時自動通知 release channel
- **Web UI**：若部署頻率高，可考慮輕量 web frontend（**目前 not planned**）

---
