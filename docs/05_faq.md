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
- 若中斷時剛好在某機種的中段（例如 sed 改完但 push 失敗），**該機種會留下 dirty working tree**，需手動 `git checkout .` 或 `git reset --hard origin/master`。
- 重跑相同指令時，腳本會 `git checkout master && git clean -fd && git pull`，**會清掉 dirty state**。

---

## B. 失敗與回滾

### Q5. 某台機種 push 失敗了，其他機種會怎樣？

**短答**：其他機種**繼續**部署，失敗的機種會列在最終 `Deploy Result` 區塊，exit code 為 1。

**延伸**：
- Staging APK 會被保留（因為「全成功」條件未達成）。
- 修好問題後**重跑相同指令**即可——已成功的機種會被 `git pull` 對齊，再次跑 sed 不會產生差異，git commit 會因為 nothing to commit 而失敗、但這代表已是最新狀態。
- 真正想跳過已成功機種，請從 `--device` 拿掉它們。

---

### Q6. 部署錯了能不能 rollback？

**短答**：腳本本身**不提供 rollback**。請手動：

```bash
ssh app_dev@192.168.8.17
cd ~/<device-repo>
git revert <wrong-commit>   # 或 git reset --hard <good-commit>
git push origin master
```

**延伸**：
- 因為 APK 檔名含版號者**不會覆蓋舊版**，只需要把 `Android.mk` 改回舊版檔名即可生效。
- 若是無版號的覆蓋情境，舊 APK 已被覆蓋，需要從 build server 重新取得。
- 多機種 rollback 沒有對應工具，建議盡量在 dry-run 階段就攔住問題。

---

### Q7. 如果我 push 到一半 server 斷網了？

**短答**：當下機種會留下 dirty repo，重跑相同指令會自動 reset。Staging APK 保留。

**延伸**：
- 腳本在 git push 前已 `commit`，所以可能出現「本地有 commit 但沒 push」的狀態。
- 重跑時 `git pull origin master` 會 fast-forward，本地未 push commit 會卡住。
- 此時需要：`cd <repo> && git reset --hard origin/master` 後再重跑。

---

### Q8. 我把 author key 拼錯，commit 已 push 出去了，怎麼辦？

**短答**：驗證階段會 `✗ Author name 不符` 並 exit 1，但 commit 已經在 remote 了。請手動：

```bash
git commit --amend --author="Correct.Name <correct@cipherlab.com.tw>"
git push --force-with-lease origin master
```

**延伸**：force push 到 master 需要與其他 RD 協調（避免覆蓋別人的 commit）。

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

1. `~/apk_deploy/logs/deploy_YYYYMMDD_HHMMSS.log`（每次執行）
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

---

### Q21. `git pull` 衝突的話腳本怎麼處理？

**短答**：腳本會在 `git pull` 失敗時 die，**不嘗試自動解衝突**。

**延伸**：因為 `git checkout master && git clean -fd` 已先做了，正常情況不應有 conflict（除非有人在 server 上手動改了該 repo）。發生時請手動處理該 repo 再重跑。

---

### Q22. 同時有兩個人跑 deploy 會怎樣？

**短答**：腳本**沒有 lock**。兩人同時跑同一機種有機率：

- 一方 push 被拒（remote tip changed），會在腳本中 die。
- 另一方成功後，第一方重跑時會 `git pull` 對齊。

**延伸**：建議 release window 有人協調，目前**沒有看到實際衝突**過。長期可加 file lock。

---

### Q23. Server 上的 repo 被別人手動 push 了 commit，會被洗掉嗎？

**短答**：**不會**。腳本只在自己這次部署的範圍內 commit，`git pull origin master` 會先拉下別人的 commit。

**延伸**：但若別人剛好 push 了相同 `Android.mk` 的改動，腳本的 sed 可能會產生 merge conflict — 此時 `git pull` 失敗，腳本 die。

---

## G. 路線圖（如果被問到「未來會加什麼」）

- **CI 整合**：build server build 完自動丟 staging（需求待確認）
- **驗證擴充**：apksigner 簽章、aapt 版號比對（低風險，可隨時加）
- **集中 log**：rsync 到中央 storage 或寫到 GitLab CI artifact
- **權限收斂**：`--author` 對照 `$USER`，避免 typo / 假冒
- **Slack/Mail 通知**：成功 / 失敗時自動通知 release channel
- **Web UI**：若部署頻率高，可考慮輕量 web frontend（**目前 not planned**）

---
