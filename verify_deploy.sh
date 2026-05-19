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
#     --author  Bob \
#     --message "Update KMM to v1.2.3: fix scan lag" \
#     --device  rk26s rs36s rk95u
#
# 驗證項目:
#   ✓ 已部署的 APK 存在且 MD5 與 staging 來源一致
#   ✓ Android.mk 已包含正確 APK 檔名
#   ✓ 最新 commit author name 與 email 與 authors.conf 一致
#   ✓ 最新 commit message 與 --message 一致
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

APP_NAME=""; APK_PATH=""; AUTHOR_KEY=""; COMMIT_MSG=""; DEVICES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP_NAME="$2";   shift 2 ;;
    --apk)     APK_PATH="$2";   shift 2 ;;
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
echo -e "  APP     : ${CYAN}${APP_NAME}${RESET}"
echo -e "  APK     : ${CYAN}${APK_FILENAME}${RESET}"
echo -e "  Author  : ${CYAN}${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>${RESET}"
echo -e "  Message : ${CYAN}${COMMIT_MSG}${RESET}"
echo -e "  Devices : ${CYAN}${DEVICES[*]}${RESET}"
echo -e "============================"
echo ""

PASS=0; FAIL=0; FAILED=()

for dev in "${DEVICES[@]}"; do
  repo_var="DEVICE_${dev}"
  REPO="${!repo_var:-}"
  if [[ -z "${REPO}" ]]; then
    echo -e "${RED}[${dev}] devices.conf 中未定義，略過${RESET}"
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
  ERRORS=0

  echo -e "${BOLD}[${dev}] 驗證中...${RESET}"

  # --- APK MD5 ---
  echo "--- 驗證 APK ---"
  if [[ -f "${APK_DEPLOYED}" ]]; then
    DEPLOYED_MD5=$(md5sum "${APK_DEPLOYED}" | awk '{print $1}')
    if [[ "${DEPLOYED_MD5}" == "${STAGING_MD5}" ]]; then
      echo "  ✓ APK MD5 驗證通過: ${DEPLOYED_MD5}"
    else
      echo "  ✗ APK MD5 不符! staging=${STAGING_MD5} deployed=${DEPLOYED_MD5}"
      ERRORS=$(( ERRORS+1 ))
    fi
  else
    echo "  ✗ 找不到已部署的 APK: ${APK_DEPLOYED}"
    ERRORS=$(( ERRORS+1 ))
  fi

  # --- Android.mk ---
  echo "--- 驗證 Android.mk ---"
  if grep -q "${APK_FILENAME}" "${MK_PATH}" 2>/dev/null; then
    echo "  ✓ Android.mk 已更新為 ${APK_FILENAME}"
  else
    echo "  ✗ Android.mk 未包含 ${APK_FILENAME}"
    ERRORS=$(( ERRORS+1 ))
  fi

  # --- Commit author & message ---
  echo "--- 驗證 commit author ---"
  C_NAME=$(    git -C "${REPO}" log -1 --pretty=format:"%an")
  C_EMAIL=$(   git -C "${REPO}" log -1 --pretty=format:"%ae")
  C_SUBJECT=$( git -C "${REPO}" log -1 --pretty=format:"%s")
  C_HASH=$(    git -C "${REPO}" log -1 --pretty=format:"%h")

  if [[ "${C_NAME}" == "${GIT_AUTHOR_NAME}" ]]; then
    echo "  ✓ Author name  : ${C_NAME}"
  else
    echo "  ✗ Author name 不符! expected='${GIT_AUTHOR_NAME}' got='${C_NAME}'"
    ERRORS=$(( ERRORS+1 ))
  fi

  if [[ "${C_EMAIL}" == "${GIT_AUTHOR_EMAIL}" ]]; then
    echo "  ✓ Author email : ${C_EMAIL}"
  else
    echo "  ✗ Author email 不符! expected='${GIT_AUTHOR_EMAIL}' got='${C_EMAIL}'"
    ERRORS=$(( ERRORS+1 ))
  fi

  echo "--- 驗證 commit message ---"
  if [[ "${C_SUBJECT}" == "${COMMIT_MSG}" ]]; then
    echo "  ✓ Commit message: ${C_SUBJECT}"
  else
    echo "  ✗ Commit message 不符!"
    echo "    expected : ${COMMIT_MSG}"
    echo "    got      : ${C_SUBJECT}"
    ERRORS=$(( ERRORS+1 ))
  fi

  echo "  → commit hash: [${C_HASH}]"

  if [[ ${ERRORS} -eq 0 ]]; then
    echo -e "${GREEN}[${dev}] 驗證通過 ✓${RESET}"
    PASS=$(( PASS+1 ))
  else
    echo -e "${RED}[${dev}] 驗證失敗 ✗ (${ERRORS} 個問題)${RESET}"
    FAIL=$(( FAIL+1 )); FAILED+=("${dev}")
  fi
  echo ""
done

echo -e "${BOLD}====== Verify Result ======${RESET}"
echo -e "  ${GREEN}通過: ${PASS}${RESET}  ${RED}失敗: ${FAIL}${RESET}"
[[ ${FAIL} -gt 0 ]] && echo -e "  失敗機種: ${RED}${FAILED[*]}${RESET}"
[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
