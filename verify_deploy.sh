#!/usr/bin/env bash
# =============================================================================
# verify_deploy.sh — 只做驗證，不進行部署（用於部署後人工複查）
#
# 本腳本在 upload server（app_dev@192.168.8.17）上直接執行。
#
# 用法:
#   ./verify_deploy.sh \
#     --app     KeyMappingManager \
#     --apk     ~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk \
#     --libs    ~/apk_deploy/toBeUploaded/.../arm64-v8a  (可選；含 libs 時提供)
#     --author  Bob \
#     --message "SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3" \
#     --device  rk26s rs36s rk95u
#
# 驗證項目（無 --libs 5 項；有 --libs 8 項）:
#   ✓ APK MD5
#   ✓ Android.mk LOCAL_SRC_FILES
#   ✓ Android.mk LOCAL_TARGET_CPU_ABI  (當 --libs 提供)
#   ✓ Android.mk LOCAL_PREBUILT_JNI_LIBS 列表  (當 --libs 提供)
#   ✓ JNI Libs files MD5  (當 --libs 提供)
#   ✓ Commit author name / email
#   ✓ Commit message
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
source "${CONFIG_DIR}/devices.conf"
source "${CONFIG_DIR}/authors.conf"

# APK_STAGING_DIR 固定為腳本同層的 toBeUploaded/（devices.conf 可覆寫）
if [[ -z "${APK_STAGING_DIR}" ]]; then
  APK_STAGING_DIR="${SCRIPT_DIR}/toBeUploaded"
else
  APK_STAGING_DIR="${APK_STAGING_DIR/#\~/$HOME}"
fi

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# log: 螢幕加 [MM-DD HH:MM:SS] 時間戳前綴（無 log 檔，純畫面輸出）
log() { echo -e "[$(date '+%m-%d %H:%M:%S')] $*"; }

APP_NAME=""; APK_PATH=""; LIBS_PATH=""; AUTHOR_KEY=""; COMMIT_MSG=""; DEVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP_NAME="$2";   shift 2 ;;
    --apk)     APK_PATH="$2";   shift 2 ;;
    --libs)    LIBS_PATH="$2";  shift 2 ;;
    --author)  AUTHOR_KEY="$2"; shift 2 ;;
    --message) COMMIT_MSG="$2"; shift 2 ;;
    --device)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do DEVICES+=("$1"); shift; done
      ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0 ;;
    *) echo "未知參數: $1"; exit 1 ;;
  esac
done

[[ -z "${APP_NAME}" ]]     && { echo "--app 必填";     exit 1; }
[[ -z "${APK_PATH}" ]]     && { echo "--apk 必填";     exit 1; }
[[ -z "${AUTHOR_KEY}" ]]   && { echo "--author 必填";  exit 1; }
[[ -z "${COMMIT_MSG}" ]]   && { echo "--message 必填"; exit 1; }
[[ ${#DEVICES[@]} -eq 0 ]] && { echo "--device 至少一個"; exit 1; }

# ~ 展開
APK_PATH="${APK_PATH/#\~/$HOME}"
[[ -f "${APK_PATH}" ]] || { echo "找不到 APK: ${APK_PATH}"; exit 1; }

# --libs 驗證 + ABI 偵測（optional）
ABI_NAME=""
LIB_FILES=()
if [[ -n "${LIBS_PATH}" ]]; then
  LIBS_PATH="${LIBS_PATH/#\~/$HOME}"
  LIBS_PATH="${LIBS_PATH%/}"
  [[ -e "${LIBS_PATH}" ]] || { echo "--libs 路徑不存在"; exit 1; }
  [[ -d "${LIBS_PATH}" ]] || { echo "--libs 不是資料夾"; exit 1; }
  ABI_NAME="$(basename "${LIBS_PATH}")"
  if [[ "${ABI_NAME}" == "." || "${ABI_NAME}" == ".." || -z "${ABI_NAME}" ]]; then
    echo "--libs 路徑不合理（basename 為 . / .. / 空）"; exit 1
  fi
  while IFS= read -r -d '' f; do
    LIB_FILES+=("$f")
  done < <(find "${LIBS_PATH}" -type f -not -path '*/.*' -print0 2>/dev/null | LC_ALL=C sort -z)
  [[ ${#LIB_FILES[@]} -eq 0 ]] && { echo "--libs 路徑為空目錄，無檔案可部署"; exit 1; }
fi

# 解析 author
author_var="AUTHOR_${AUTHOR_KEY}"
AUTHOR_RAW="${!author_var:-}"
[[ -z "${AUTHOR_RAW}" ]] && { echo "authors.conf 找不到: ${AUTHOR_KEY}"; exit 1; }
GIT_AUTHOR_NAME="${AUTHOR_RAW%%|*}"
GIT_AUTHOR_EMAIL="${AUTHOR_RAW##*|}"

APK_FILENAME="$(basename "${APK_PATH}")"
STAGING_MD5=$(md5sum "${APK_PATH}" | awk '{print $1}')

echo ""
echo -e "${BOLD}====== Verify Summary ======${RESET}"
echo -e "  APP        : ${CYAN}${APP_NAME}${RESET}"
echo -e "  APK        : ${CYAN}${APK_FILENAME}${RESET}"
if [[ -n "${LIBS_PATH}" ]]; then
  echo -e "  Libs ABI   : ${CYAN}${ABI_NAME}${RESET}  (${#LIB_FILES[@]} 個檔案)"
fi
echo -e "  Author     : ${CYAN}${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>${RESET}"
echo -e "  Message    : ${CYAN}${COMMIT_MSG}${RESET}"
echo -e "  Devices    : ${CYAN}${DEVICES[*]}${RESET}"
echo -e "============================"
echo ""

PASS=0; FAIL=0; FAILED=()

PASS_TAG="${GREEN}✓ PASS${RESET}"
FAIL_TAG="${RED}✗ FAIL${RESET}"

for dev in "${DEVICES[@]}"; do
  repo_var="DEVICE_${dev}"
  REPO="${!repo_var:-}"
  if [[ -z "${REPO}" ]]; then
    log "${RED}[${dev}] devices.conf 中未定義，略過${RESET}"
    FAIL=$(( FAIL+1 )); FAILED+=("${dev}"); continue
  fi
  REPO="${REPO/#\~/$HOME}"

  # 機種專屬 APK 目錄覆寫：DEVICE_<NAME>_APK_SUBDIR 優先，否則使用全域 APK_SUBDIR
  subdir_var="DEVICE_${dev}_APK_SUBDIR"
  EFFECTIVE_APK_SUBDIR="${!subdir_var:-${APK_SUBDIR}}"

  # APK 與 Android.mk 都在 <EFFECTIVE_APK_SUBDIR>/<APP_NAME>/ 下
  MODULE_DIR="${REPO}/${EFFECTIVE_APK_SUBDIR}/${APP_NAME}"
  APK_DEPLOYED="${MODULE_DIR}/${APK_FILENAME}"
  MK_PATH="${MODULE_DIR}/Android.mk"
  LIBS_REMOTE_DIR="${MODULE_DIR}/libs/${ABI_NAME}"
  ERRORS=0
  R_APK=""; R_MK=""; R_ABI=""; R_LIB_LIST=""; R_LIB_FILES=""; R_NAME=""; R_EMAIL=""; R_MSG=""

  log "${BOLD}[${dev}] 驗證中...${RESET}"

  # --- APK MD5 ---
  log "--- 驗證 APK ---"
  if [[ -f "${APK_DEPLOYED}" ]]; then
    DEPLOYED_MD5=$(md5sum "${APK_DEPLOYED}" | awk '{print $1}')
    if [[ "${DEPLOYED_MD5}" == "${STAGING_MD5}" ]]; then
      log "  ✓ APK MD5 驗證通過: ${DEPLOYED_MD5}"
      R_APK="${PASS_TAG}"
    else
      log "  ✗ APK MD5 不符! staging=${STAGING_MD5} deployed=${DEPLOYED_MD5}"
      R_APK="${FAIL_TAG}"
      ERRORS=$(( ERRORS+1 ))
    fi
  else
    log "  ✗ 找不到已部署的 APK: ${APK_DEPLOYED}"
    R_APK="${FAIL_TAG}"
    ERRORS=$(( ERRORS+1 ))
  fi

  # --- Android.mk LOCAL_SRC_FILES ---
  log "--- 驗證 Android.mk LOCAL_SRC_FILES ---"
  if grep -q "${APK_FILENAME}" "${MK_PATH}" 2>/dev/null; then
    log "  ✓ LOCAL_SRC_FILES 已更新為 ${APK_FILENAME}"
    R_MK="${PASS_TAG}"
  else
    log "  ✗ LOCAL_SRC_FILES 未包含 ${APK_FILENAME}"
    R_MK="${FAIL_TAG}"
    ERRORS=$(( ERRORS+1 ))
  fi

  # --- libs 相關（只在 --libs 提供時驗證）---
  if [[ -n "${LIBS_PATH}" ]]; then
    log "--- 驗證 Android.mk LOCAL_TARGET_CPU_ABI ---"
    ABI_LINE_VAL=$(grep -E '^LOCAL_TARGET_CPU_ABI[ \t]*:=' "${MK_PATH}" 2>/dev/null | head -1 | sed -E 's|^LOCAL_TARGET_CPU_ABI[ \t]*:=[ \t]*||; s|[ \t]+$||')
    if [[ "${ABI_LINE_VAL}" == "${ABI_NAME}" ]]; then
      log "  ✓ LOCAL_TARGET_CPU_ABI = ${ABI_NAME}"
      R_ABI="${PASS_TAG}"
    else
      log "  ✗ LOCAL_TARGET_CPU_ABI 不符! expected='${ABI_NAME}' got='${ABI_LINE_VAL}'"
      R_ABI="${FAIL_TAG}"
      ERRORS=$(( ERRORS+1 ))
    fi

    log "--- 驗證 Android.mk LOCAL_PREBUILT_JNI_LIBS ---"
    LIB_LIST_OK=true
    for f in "${LIB_FILES[@]}"; do
      rel="${f#${LIBS_PATH}/}"
      EXPECTED_LIB_LINE="libs/\$(LOCAL_TARGET_CPU_ABI)/${rel}"
      if ! grep -qF "${EXPECTED_LIB_LINE}" "${MK_PATH}" 2>/dev/null; then
        log "  ✗ LOCAL_PREBUILT_JNI_LIBS 缺項: ${EXPECTED_LIB_LINE}"
        LIB_LIST_OK=false
        ERRORS=$(( ERRORS+1 ))
      fi
    done
    if ${LIB_LIST_OK}; then
      log "  ✓ LOCAL_PREBUILT_JNI_LIBS 含 ${#LIB_FILES[@]} 筆，全數對齊"
      R_LIB_LIST="${PASS_TAG}"
    else
      R_LIB_LIST="${FAIL_TAG}"
    fi

    log "--- 驗證 JNI Libs files (MD5) ---"
    lib_pass=0; lib_fail=0
    FAILED_LIBS=()
    for f in "${LIB_FILES[@]}"; do
      rel="${f#${LIBS_PATH}/}"
      remote="${LIBS_REMOTE_DIR}/${rel}"
      if [[ ! -f "${remote}" ]]; then
        FAILED_LIBS+=("${rel}  (missing)")
        lib_fail=$(( lib_fail+1 ))
        continue
      fi
      src_md5=$(md5sum "${f}"      | awk '{print $1}')
      dst_md5=$(md5sum "${remote}" | awk '{print $1}')
      if [[ "${src_md5}" == "${dst_md5}" ]]; then
        lib_pass=$(( lib_pass+1 ))
      else
        FAILED_LIBS+=("${rel}  (MD5 mismatch)")
        lib_fail=$(( lib_fail+1 ))
      fi
    done
    if [[ ${lib_fail} -eq 0 ]]; then
      log "  ✓ ${lib_pass}/${#LIB_FILES[@]} libs MD5 全對"
      R_LIB_FILES="${PASS_TAG}"
    else
      log "  ✗ ${lib_pass}/${#LIB_FILES[@]} libs MD5 對；失敗 ${lib_fail} 個："
      for fl in "${FAILED_LIBS[@]}"; do
        log "      ${fl}"
      done
      R_LIB_FILES="${FAIL_TAG}"
      ERRORS=$(( ERRORS+1 ))
    fi
  fi

  # --- Commit author & message ---
  log "--- 驗證 commit author ---"
  C_NAME=$(    git -C "${REPO}" log -1 --pretty=format:"%an")
  C_EMAIL=$(   git -C "${REPO}" log -1 --pretty=format:"%ae")
  C_SUBJECT=$( git -C "${REPO}" log -1 --pretty=format:"%s")
  C_HASH=$(    git -C "${REPO}" log -1 --pretty=format:"%h")

  if [[ "${C_NAME}" == "${GIT_AUTHOR_NAME}" ]]; then
    log "  ✓ Author name  : ${C_NAME}"
    R_NAME="${PASS_TAG}"
  else
    log "  ✗ Author name 不符! expected='${GIT_AUTHOR_NAME}' got='${C_NAME}'"
    R_NAME="${FAIL_TAG}"
    ERRORS=$(( ERRORS+1 ))
  fi

  if [[ "${C_EMAIL}" == "${GIT_AUTHOR_EMAIL}" ]]; then
    log "  ✓ Author email : ${C_EMAIL}"
    R_EMAIL="${PASS_TAG}"
  else
    log "  ✗ Author email 不符! expected='${GIT_AUTHOR_EMAIL}' got='${C_EMAIL}'"
    R_EMAIL="${FAIL_TAG}"
    ERRORS=$(( ERRORS+1 ))
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
    ERRORS=$(( ERRORS+1 ))
  fi

  log "  → commit hash: [${C_HASH}]"

  # ---------- 驗證結果摘要 ----------
  echo ""
  log "${BOLD}--- 驗證結果摘要 [${dev}] ---${RESET}"
  log "  ${R_APK}    APK MD5"
  log "  ${R_MK}    Android.mk LOCAL_SRC_FILES"
  if [[ -n "${LIBS_PATH}" ]]; then
    log "  ${R_ABI}    Android.mk LOCAL_TARGET_CPU_ABI = ${ABI_NAME}"
    log "  ${R_LIB_LIST}    Android.mk LOCAL_PREBUILT_JNI_LIBS (${#LIB_FILES[@]} entries)"
    log "  ${R_LIB_FILES}    JNI Libs files (${#LIB_FILES[@]} files MD5)"
  fi
  log "  ${R_NAME}    Commit Author Name"
  log "  ${R_EMAIL}    Commit Author Email"
  log "  ${R_MSG}    Commit Message"

  if [[ ${ERRORS} -eq 0 ]]; then
    log "${GREEN}[${dev}] 驗證通過 ✓${RESET}"
    PASS=$(( PASS+1 ))
  else
    log "${RED}[${dev}] 驗證失敗 ✗ (${ERRORS} 個問題)${RESET}"
    FAIL=$(( FAIL+1 )); FAILED+=("${dev}")
  fi
  echo ""
done

echo -e "${BOLD}====== Verify Result ======${RESET}"
echo -e "  ${GREEN}通過: ${PASS}${RESET}  ${RED}失敗: ${FAIL}${RESET}"
[[ ${FAIL} -gt 0 ]] && echo -e "  失敗機種: ${RED}${FAILED[*]}${RESET}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
