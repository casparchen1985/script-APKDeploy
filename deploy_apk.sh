#!/usr/bin/env bash
# =============================================================================
# deploy_apk.sh — APK 自動部署腳本
#
# 本腳本在 upload server（app_dev@192.168.8.17）上直接執行。
# RD 須先將 APK 上傳至 staging 目錄，再執行此腳本。
#
# 用法:
#   ./deploy_apk.sh \
#     --app     KeyMappingManager \
#     --apk     ~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk \
#     --author  Bob \
#     --message "Update KMM to v1.2.3: fix scan lag" \
#     --device  rk26s rs36s rk95u \
#     --dry-run
#
# 選項:
#   --app       APP 名稱（對應 repo 內目錄名稱，用來定位 Android.mk，必填）
#   --apk       staging 目錄上的 APK 路徑（必填）
#   --author    authors.conf 中的 key，例如 Bob（必填）
#   --message   git commit message（必填）
#   --device    一或多個機種，空格分隔，必須是 devices.conf 中定義的名稱（必填）
#   --dry-run   模擬執行，印出所有步驟但不實際複製檔案或 git push
#   --no-verify 跳過部署後的自動驗證步驟
#
# APK 保留策略:
#   - 檔名含版號識別 (例: _v1.2.3 / _1.2.3 / _20250513) → 保留舊版，新版共存
#   - 檔名無版號識別 → 同名覆蓋
#
# APK 放入腳本同層的 toBeUploaded/ 即可；部署成功後自動刪除，失敗或未使用的保留供重試。
# =============================================================================

set -euo pipefail

# ---------- 路徑常數 ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
LOG_DIR="${SCRIPT_DIR}/logs"
DEVICES_CONF="${CONFIG_DIR}/devices.conf"
AUTHORS_CONF="${CONFIG_DIR}/authors.conf"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/deploy_$(date +%Y%m%d_%H%M%S).log"

# ---------- 顏色輸出 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
SEP='────────────────────────────────────────'

# log: 螢幕顯示帶顏色，log 檔濾掉 ANSI 色碼，兩者都加 [MM-DD HH:MM:SS] 時間戳
log() {
  local msg="[$(date '+%m-%d %H:%M:%S')] $*"
  echo -e "${msg}"
  echo -e "${msg}" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
}
info() { log "${CYAN}INFO${RESET}  $*"; }
ok()   { log "${GREEN}OK${RESET}    $*"; }
warn() { log "${YELLOW}WARN${RESET}  $*"; }
err()  { log "${RED}ERROR${RESET} $*"; }
die()  { err "$*"; exit 1; }

# ---------- 解析參數 ----------
APP_NAME=""
APK_PATH=""
AUTHOR_KEY=""
COMMIT_MSG=""
DEVICES=()
DRY_RUN=false
NO_VERIFY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP_NAME="$2";   shift 2 ;;
    --apk)     APK_PATH="$2";   shift 2 ;;
    --author)  AUTHOR_KEY="$2"; shift 2 ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    --device)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        DEVICES+=("$1"); shift
      done
      ;;
    --dry-run)   DRY_RUN=true;   shift ;;
    --no-verify) NO_VERIFY=true; shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0 ;;
    *) die "未知參數: $1" ;;
  esac
done

# ---------- 必填驗證 ----------
[[ -z "${APP_NAME}" ]]     && die "--app 必填"
[[ -z "${APK_PATH}" ]]     && die "--apk 必填"
[[ -z "${AUTHOR_KEY}" ]]   && die "--author 必填"
[[ -z "${COMMIT_MSG}" ]]   && die "--message 必填"
[[ ${#DEVICES[@]} -eq 0 ]] && die "--device 至少指定一個機種"

# ~ 展開
APK_PATH="${APK_PATH/#\~/$HOME}"
[[ -f "${APK_PATH}" ]] || die "找不到 APK 檔案: ${APK_PATH}"

# ---------- 載入設定 ----------
source "${DEVICES_CONF}"
source "${AUTHORS_CONF}"

# APK_STAGING_DIR 固定為腳本同層的 toBeUploaded/（devices.conf 可覆寫）
if [[ -z "${APK_STAGING_DIR}" ]]; then
  APK_STAGING_DIR="${SCRIPT_DIR}/toBeUploaded"
else
  APK_STAGING_DIR="${APK_STAGING_DIR/#\~/$HOME}"
fi

# 解析 author
author_var="AUTHOR_${AUTHOR_KEY}"
AUTHOR_RAW="${!author_var:-}"
[[ -z "${AUTHOR_RAW}" ]] && die "authors.conf 中找不到 author key: ${AUTHOR_KEY}"
GIT_AUTHOR_NAME="${AUTHOR_RAW%%|*}"
GIT_AUTHOR_EMAIL="${AUTHOR_RAW##*|}"

# APK 檔名與版號識別
APK_FILENAME="$(basename "${APK_PATH}")"
APK_NAME_NO_EXT="${APK_FILENAME%.apk}"

if echo "${APK_NAME_NO_EXT}" | grep -qE '(_v?[0-9]+([._][0-9]+)+|_[0-9]{8}([0-9]{6})?)$'; then
  APK_HAS_VERSION=true
else
  APK_HAS_VERSION=false
fi

# ---------- 機種驗證 ----------
VALID_DEVICES=()
for dev in "${DEVICES[@]}"; do
  repo_var="DEVICE_${dev}"
  repo_path="${!repo_var:-}"
  if [[ -z "${repo_path}" ]]; then
    warn "devices.conf 中未定義機種: ${dev}，已略過"
  else
    VALID_DEVICES+=("${dev}")
  fi
done
[[ ${#VALID_DEVICES[@]} -eq 0 ]] && die "沒有有效機種可部署"

# ---------- 摘要 ----------
echo -e "${BOLD}====== APK Deploy Summary ======${RESET}"
echo -e "  APP       : ${CYAN}${APP_NAME}${RESET}"
echo -e "  APK       : ${CYAN}${APK_FILENAME}${RESET}"
echo -e "  版號識別  : $(${APK_HAS_VERSION} && echo "${GREEN}有版號 → 保留舊版共存${RESET}" || echo "${YELLOW}無版號 → 同名覆蓋${RESET}")"
echo -e "  Author    : ${CYAN}${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>${RESET}"
echo -e "  Message   : ${CYAN}${COMMIT_MSG}${RESET}"
echo -e "  Devices   : ${CYAN}${VALID_DEVICES[*]}${RESET}"
echo -e "  Dry-run   : ${DRY_RUN}"
echo -e "================================"
echo ""

# ---------- 輔助函式 ----------
# 本地複製（在 server 上直接操作）
copy_file() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    info "[DRY-RUN] cp ${src} ${dst}"
  else
    cp "${src}" "${dst}"
  fi
}

run() {
  if $DRY_RUN; then
    info "[DRY-RUN] $*"
  else
    eval "$@"
  fi
}

# ---------- 每台機種部署函式 ----------
deploy_device() {
  local dev="$1"
  local repo_var="DEVICE_${dev}"
  local REPO="${!repo_var}"
  REPO="${REPO/#\~/$HOME}"   # 展開 ~

  # 機種專屬 APK 目錄覆寫：DEVICE_<NAME>_APK_SUBDIR 優先，否則使用全域 APK_SUBDIR
  local subdir_var="DEVICE_${dev}_APK_SUBDIR"
  local EFFECTIVE_APK_SUBDIR="${!subdir_var:-${APK_SUBDIR}}"

  # APK 與 Android.mk 都在 <EFFECTIVE_APK_SUBDIR>/<APP_NAME>/ 下
  local MODULE_DIR="${REPO}/${EFFECTIVE_APK_SUBDIR}/${APP_NAME}"
  local APK_DEST_DIR="${MODULE_DIR}"
  local MK_PATH="${MODULE_DIR}/Android.mk"

  log "${CYAN}${SEP}${RESET}"
  log "${CYAN}  ▶  [${dev}] 開始部署${RESET}"
  log "${CYAN}${SEP}${RESET}"

  # 1. git checkout master + clean + pull
  info "[${dev}] git checkout master && git clean -fd && git pull"
  run "cd '${REPO}' && git checkout master && git clean -fd && git pull origin master"
  ok "[${dev}] repo 已同步到最新 master"

  # 2. 複製 APK 至 repo（版號策略）
  if ${APK_HAS_VERSION}; then
    info "[${dev}] APK 含版號識別，保留舊版，複製新版: ${APK_FILENAME}"
  else
    info "[${dev}] APK 無版號識別，覆蓋同名檔: ${APK_FILENAME}"
  fi
  copy_file "${APK_PATH}" "${APK_DEST_DIR}/"
  ok "[${dev}] APK 複製完成"

  # 3. 更新 Android.mk 中的 LOCAL_SRC_FILES
  info "[${dev}] 更新 Android.mk"
  if ! $DRY_RUN; then
    [[ -f "${MK_PATH}" ]] || die "找不到 Android.mk: ${MK_PATH}"
    sed -i -E "s|^(LOCAL_SRC_FILES[[:space:]]*:=[[:space:]]*).*\.apk|\1${APK_FILENAME}|" "${MK_PATH}"
    grep -q "${APK_FILENAME}" "${MK_PATH}" || die "Android.mk 更新失敗，請確認 LOCAL_SRC_FILES 行是否存在"
    log "Android.mk 已更新為 ${APK_FILENAME}"
  else
    info "[DRY-RUN] sed 更新 ${MK_PATH} → LOCAL_SRC_FILES := ${APK_FILENAME}"
  fi
  ok "[${dev}] Android.mk 更新完成"
  # 接續印出 .mk 內 LOCAL_SRC_FILES 行的實際內容（dry-run 顯示預期值）
  if ! $DRY_RUN; then
    local MK_LINE
    MK_LINE=$(grep -E '^LOCAL_SRC_FILES[[:space:]]*:=' "${MK_PATH}" | head -1)
    log "  └─ ${MK_PATH}"
    log "     ${MK_LINE}"
  else
    log "  └─ (dry-run 預期) LOCAL_SRC_FILES := ${APK_FILENAME}"
  fi

  # 4. git add + commit + push
  # 使用 --author 直接帶入 author 資訊，不修改 repo 的 git config
  info "[${dev}] git commit & push"
  run "cd '${REPO}' && \
    git add '${EFFECTIVE_APK_SUBDIR}/${APP_NAME}/${APK_FILENAME}' '${EFFECTIVE_APK_SUBDIR}/${APP_NAME}/Android.mk' && \
    git commit --author='${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>' -m '${COMMIT_MSG}' && \
    git push origin master"
  ok "[${dev}] push 完成"

  # 5. 部署後驗證
  if ! $NO_VERIFY; then
    verify_device "${dev}" "${REPO}" "${APK_DEST_DIR}" "${MK_PATH}"
  fi

  log "${GREEN}${SEP}${RESET}"
  log "${GREEN}  ✔  [${dev}] 部署成功${RESET}"
  log "${GREEN}${SEP}${RESET}\n\n"
}

# ---------- 驗證函式 ----------
verify_device() {
  local dev="$1" repo="$2" apk_dir="$3" mk_path="$4"
  info "[${dev}] 驗證部署結果..."
  local ERRORS=0
  local R_APK R_MK R_NAME R_EMAIL R_MSG
  local PASS_TAG="${GREEN}✓ PASS${RESET}"
  local FAIL_TAG="${RED}✗ FAIL${RESET}"

  log "--- 驗證 APK ---"
  local APK_DEPLOYED="${apk_dir}/${APK_FILENAME}"
  if [[ -f "${APK_DEPLOYED}" ]]; then
    local STAGING_MD5 DEPLOYED_MD5
    STAGING_MD5=$(md5sum "${APK_PATH}"     | awk '{print $1}')
    DEPLOYED_MD5=$(md5sum "${APK_DEPLOYED}" | awk '{print $1}')
    if [[ "${STAGING_MD5}" == "${DEPLOYED_MD5}" ]]; then
      log "  ✓ APK MD5 驗證通過: ${DEPLOYED_MD5}"
      R_APK="${PASS_TAG}"
    else
      log "  ✗ APK MD5 不符! staging=${STAGING_MD5} deployed=${DEPLOYED_MD5}"
      R_APK="${FAIL_TAG}"
      ERRORS=$(( ERRORS + 1 ))
    fi
  else
    log "  ✗ 找不到已部署的 APK: ${APK_DEPLOYED}"
    R_APK="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  log "--- 驗證 Android.mk ---"
  if grep -q "${APK_FILENAME}" "${mk_path}" 2>/dev/null; then
    log "  ✓ Android.mk 已更新為 ${APK_FILENAME}"
    R_MK="${PASS_TAG}"
  else
    log "  ✗ Android.mk 未包含 ${APK_FILENAME}"
    R_MK="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  log "--- 驗證 commit author ---"
  local C_NAME C_EMAIL C_SUBJECT C_HASH
  C_NAME=$(    git -C "${repo}" log -1 --pretty=format:"%an")
  C_EMAIL=$(   git -C "${repo}" log -1 --pretty=format:"%ae")
  C_SUBJECT=$( git -C "${repo}" log -1 --pretty=format:"%s")
  C_HASH=$(    git -C "${repo}" log -1 --pretty=format:"%h")

  if [[ "${C_NAME}" == "${GIT_AUTHOR_NAME}" ]]; then
    log "  ✓ Author name  : ${C_NAME}"
    R_NAME="${PASS_TAG}"
  else
    log "  ✗ Author name 不符! expected='${GIT_AUTHOR_NAME}' got='${C_NAME}'"
    R_NAME="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  if [[ "${C_EMAIL}" == "${GIT_AUTHOR_EMAIL}" ]]; then
    log "  ✓ Author email : ${C_EMAIL}"
    R_EMAIL="${PASS_TAG}"
  else
    log "  ✗ Author email 不符! expected='${GIT_AUTHOR_EMAIL}' got='${C_EMAIL}'"
    R_EMAIL="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  log "--- 驗證 commit message ---"
  if [[ "${C_SUBJECT}" == "${COMMIT_MSG}" ]]; then
    log "  ✓ Commit message: ${C_SUBJECT}"
    R_MSG="${PASS_TAG}"
  else
    log "  ✗ Commit message 不符!"
    log "    expected : ${COMMIT_MSG}"
    log "    got      : ${C_SUBJECT}"
    R_MSG="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  log "  → commit hash: [${C_HASH}]"

  # ---------- 驗證結果摘要 ----------
  log ""
  log "${BOLD}--- 驗證結果摘要 [${dev}] ---${RESET}"
  log "  ${R_APK}    APK MD5"
  log "  ${R_MK}    Android.mk LOCAL_SRC_FILES"
  log "  ${R_NAME}    Commit Author Name"
  log "  ${R_EMAIL}    Commit Author Email"
  log "  ${R_MSG}    Commit Message"

  [[ ${ERRORS} -eq 0 ]] || { err "[${dev}] 驗證發現 ${ERRORS} 個問題"; return 1; }
  ok "[${dev}] 驗證全部通過 ✓"
}

# ---------- 主流程 ----------
FAILED=()
for dev in "${VALID_DEVICES[@]}"; do
  if deploy_device "${dev}"; then
    :
  else
    err "[${dev}] 部署失敗！"
    FAILED+=("${dev}")
  fi
done

# ---------- 清除 staging APK ----------
# 規則：所有指定機種皆部署成功 → 刪除；任一失敗 → 保留供重試
if [[ ${#FAILED[@]} -eq 0 ]]; then
  if $DRY_RUN; then
    info "[DRY-RUN] rm ${APK_PATH}  # 全部成功，清除 staging APK"
  else
    rm -f "${APK_PATH}"
    ok "Staging APK 已清除: ${APK_FILENAME}"
  fi
else
  warn "有機種部署失敗，staging APK 保留供重試: ${APK_FILENAME}"
  warn "重試時直接重新執行相同指令即可，APK 仍在 ${SCRIPT_DIR}/toBeUploaded/"
fi

# ---------- 最終結果 ----------
echo ""
echo -e "${BOLD}====== Deploy Result ======${RESET}"
TOTAL=${#VALID_DEVICES[@]}
FAIL_COUNT=${#FAILED[@]}
OK_COUNT=$(( TOTAL - FAIL_COUNT ))
echo -e "  總計: ${TOTAL}  ${GREEN}成功: ${OK_COUNT}${RESET}  ${RED}失敗: ${FAIL_COUNT}${RESET}"
if [[ ${FAIL_COUNT} -gt 0 ]]; then
  echo -e "  失敗機種: ${RED}${FAILED[*]}${RESET}"
fi
echo -e "  Log: ${LOG_FILE}"
echo -e "==========================="

[[ ${FAIL_COUNT} -eq 0 ]] && exit 0 || exit 1
