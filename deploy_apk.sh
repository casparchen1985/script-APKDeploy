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
#     --message "SW_CLUTY-381 : [Cipherlab] Update KeyMappingManager v1.2.3" \
#     --device  rk26s rs36s rk95u \
#     --dry-run
#
# 選項:
#   --app       APP 名稱（對應 repo 內目錄名稱，用來定位 Android.mk，必填）
#   --apk       staging 目錄上的 APK 路徑（必填）
#   --libs      ABI 資料夾路徑，basename 即 LOCAL_TARGET_CPU_ABI（可選）
#               內部任意檔案（含子目錄、無副檔名、非 .so 都接受）
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
# 起始 LOG_FILE 用 placeholder 名；解析完 --author / --app 後 rename 為
# deploy-<AuthorKey>-<AppName>-YYYYMMDD_HHMMSS.log
DATE_STAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/deploy-pending-${DATE_STAMP}.log"

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
LIBS_PATH=""
AUTHOR_KEY=""
COMMIT_MSG=""
DEVICES=()
DRY_RUN=false
NO_VERIFY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)     APP_NAME="$2";   shift 2 ;;
    --apk)     APK_PATH="$2";   shift 2 ;;
    --libs)    LIBS_PATH="$2";  shift 2 ;;
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

# ---------- LOG_FILE rename: deploy-<Author>-<App>-DATE.log ----------
NEW_LOG="${LOG_DIR}/deploy-${AUTHOR_KEY}-${APP_NAME}-${DATE_STAMP}.log"
if [[ "${LOG_FILE}" != "${NEW_LOG}" ]]; then
  [[ -f "${LOG_FILE}" ]] && mv "${LOG_FILE}" "${NEW_LOG}"
  LOG_FILE="${NEW_LOG}"
fi

# ---------- 載入設定 ----------
source "${DEVICES_CONF}"
source "${AUTHORS_CONF}"

# APK_STAGING_DIR 固定為腳本同層的 toBeUploaded/（devices.conf 可覆寫）
if [[ -z "${APK_STAGING_DIR}" ]]; then
  APK_STAGING_DIR="${SCRIPT_DIR}/toBeUploaded"
else
  APK_STAGING_DIR="${APK_STAGING_DIR/#\~/$HOME}"
fi

# ---------- --libs 驗證 + ABI 偵測（optional）----------
# 注意：必須在 APK_STAGING_DIR 設好之後執行，因為要做 staging 路徑限制檢查
ABI_NAME=""
LIB_FILES=()          # staging 來源檔案清單（cp 上傳用 + MD5 比對來源）
REMOTE_LIB_FILES=()   # remote libs/<ABI>/ 真實清單（每台機種 cp 完後 enumerate，寫入 .mk 用）
if [[ -n "${LIBS_PATH}" ]]; then
  LIBS_PATH="${LIBS_PATH/#\~/$HOME}"
  LIBS_PATH="${LIBS_PATH%/}"   # 去除末尾斜線方便 basename

  [[ -e "${LIBS_PATH}" ]] || die "--libs 路徑不存在"
  [[ -d "${LIBS_PATH}" ]] || die "--libs 不是資料夾"

  # 安全限制：--libs 必須位於 staging 目錄之下，避免全成功後 rm -rf 誤刪外部資料
  LIBS_PATH_ABS=$(cd "${LIBS_PATH}" && pwd -P)
  STAGING_DIR_ABS=$(cd "${APK_STAGING_DIR}" && pwd -P)
  if [[ "${LIBS_PATH_ABS}" != "${STAGING_DIR_ABS}"/* ]]; then
    die "--libs 路徑必須位於 staging 目錄 ${APK_STAGING_DIR}/ 之下（rm -rf 清理安全限制）"
  fi
  LIBS_PATH="${LIBS_PATH_ABS}"   # 後續一律用 canonical 絕對路徑

  ABI_NAME="$(basename "${LIBS_PATH}")"
  if [[ "${ABI_NAME}" == "." || "${ABI_NAME}" == ".." || -z "${ABI_NAME}" ]]; then
    die "--libs 路徑不合理（basename 為 . / .. / 空）"
  fi

  # 遞迴枚舉 lib 檔案：排除 hidden（任何路徑段以 . 開頭）、symlink
  # 排序：字母升序、大小寫敏感（LC_ALL=C）
  while IFS= read -r -d '' f; do
    LIB_FILES+=("$f")
  done < <(find "${LIBS_PATH}" -type f -not -path '*/.*' -print0 2>/dev/null | LC_ALL=C sort -z)

  [[ ${#LIB_FILES[@]} -eq 0 ]] && die "--libs 路徑為空目錄，無檔案可部署"
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
echo -e "  APP        : ${CYAN}${APP_NAME}${RESET}"
echo -e "  APK        : ${CYAN}${APK_FILENAME}${RESET}"
echo -e "  版號識別   : $(${APK_HAS_VERSION} && echo "${GREEN}有版號 → 保留舊版共存${RESET}" || echo "${YELLOW}無版號 → 同名覆蓋${RESET}")"
if [[ -n "${LIBS_PATH}" ]]; then
  echo -e "  Libs ABI   : ${CYAN}${ABI_NAME}${RESET}  (${#LIB_FILES[@]} 個檔案)"
fi
echo -e "  Author     : ${CYAN}${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>${RESET}"
echo -e "  Message    : ${CYAN}${COMMIT_MSG}${RESET}"
echo -e "  Devices    : ${CYAN}${VALID_DEVICES[*]}${RESET}"
echo -e "  Dry-run    : ${DRY_RUN}"
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
    # 用 subshell 包住 eval，避免內部 `cd` 污染外層 script 的 cwd
    ( eval "$@" )
  fi
}

# ---------- enumerate remote libs ----------
# cp 完成後執行，掃描 remote libs/<ABI>/ 內所有檔案（hidden / symlink 跳過、LC_ALL=C 排序），
# 結果寫入 global REMOTE_LIB_FILES（remote 絕對路徑）。LOCAL_PREBUILT_JNI_LIBS 以此清單為準。
#
# Dry-run 時實際沒 cp，因此 union(pre-existing remote, staging 即將 cp 上去的檔案) 來預測 cp 後狀態。
enumerate_remote_libs() {
  local dev="$1"
  local remote_dir="$2"
  REMOTE_LIB_FILES=()

  declare -A rel_set

  # 已存在 remote 的檔案
  if [[ -d "${remote_dir}" ]]; then
    while IFS= read -r -d '' f; do
      rel_set["${f#${remote_dir}/}"]=1
    done < <(find "${remote_dir}" -type f -not -path '*/.*' -print0 2>/dev/null)
  fi

  # Dry-run 預測：union 加上 staging 將 cp 上去的檔案
  if $DRY_RUN; then
    for sf in "${LIB_FILES[@]}"; do
      rel_set["${sf#${LIBS_PATH}/}"]=1
    done
  fi

  while IFS= read -r rel; do
    [[ -z "${rel}" ]] && continue
    REMOTE_LIB_FILES+=("${remote_dir}/${rel}")
  done < <(printf '%s\n' "${!rel_set[@]}" | LC_ALL=C sort)

  if $DRY_RUN; then
    log "[${dev}] remote libs/${ABI_NAME}/ 預測共 ${#REMOTE_LIB_FILES[@]} 檔（dry-run union）"
  else
    log "[${dev}] remote libs/${ABI_NAME}/ 實際共 ${#REMOTE_LIB_FILES[@]} 檔（將寫入 LOCAL_PREBUILT_JNI_LIBS）"
  fi
}

# ---------- libs 部署函式 ----------
# 逐檔判定 Added / Updated / Skipped，並印到 log。
# 絕不刪除 remote 既有檔案/資料夾；空子資料夾不傳遞。
deploy_libs() {
  local dev="$1"
  local libs_remote_dir="$2"   # <repo>/.../<APP>/libs/<ABI_NAME>
  local count_added=0 count_updated=0 count_skipped=0

  log "[${dev}] cp libs 處理結果（共 ${#LIB_FILES[@]} 檔）："

  for src_file in "${LIB_FILES[@]}"; do
    local rel_path="${src_file#${LIBS_PATH}/}"
    local target_file="${libs_remote_dir}/${rel_path}"
    local target_subdir
    target_subdir="$(dirname "${target_file}")"

    # 判定動作（dry-run 也照樣判定，以便預覽）
    local action="Added"
    if [[ -f "${target_file}" ]]; then
      local src_md5 dst_md5
      src_md5=$(md5sum "${src_file}"    | awk '{print $1}')
      dst_md5=$(md5sum "${target_file}" | awk '{print $1}')
      if [[ "${src_md5}" == "${dst_md5}" ]]; then
        action="Skipped"
      else
        action="Updated"
      fi
    fi

    case "${action}" in
      Added)
        if ! $DRY_RUN; then
          mkdir -p "${target_subdir}"
          cp "${src_file}" "${target_file}"
        fi
        log "  [ Added ]   libs/${ABI_NAME}/${rel_path}"
        count_added=$(( count_added + 1 ))
        ;;
      Updated)
        if ! $DRY_RUN; then
          cp "${src_file}" "${target_file}"
        fi
        log "  [Updated]   libs/${ABI_NAME}/${rel_path}"
        count_updated=$(( count_updated + 1 ))
        ;;
      Skipped)
        log "  [Skipped]   libs/${ABI_NAME}/${rel_path}"
        count_skipped=$(( count_skipped + 1 ))
        ;;
    esac
  done

  ok "[${dev}] libs 處理完成 (Added ${count_added} / Updated ${count_updated} / Skipped ${count_skipped})"
}

# ---------- Android.mk 更新函式 ----------
# 更新 LOCAL_SRC_FILES（必更）、LOCAL_TARGET_CPU_ABI、LOCAL_PREBUILT_JNI_LIBS（後兩者需 --libs）。
# 缺欄位則自動 insert 到 `include $(BUILD_PREBUILT)` 之前；錨點不存在 → die。
update_mk() {
  local dev="$1"
  local mk_path="$2"
  local remote_libs_dir="${3:-}"   # cp 後 enumerate 的 remote libs/<ABI>/

  if $DRY_RUN; then
    info "[DRY-RUN] 更新 ${mk_path}"
    log "  └─ (dry-run 預期)"
    log "     LOCAL_SRC_FILES := ${APK_FILENAME}"
    if [[ -n "${LIBS_PATH}" ]]; then
      log "     LOCAL_TARGET_CPU_ABI := ${ABI_NAME}"
      log "     LOCAL_PREBUILT_JNI_LIBS:"
      for f in "${REMOTE_LIB_FILES[@]}"; do
        local rel="${f#${remote_libs_dir}/}"
        log "       libs/\$(LOCAL_TARGET_CPU_ABI)/${rel}"
      done
    fi
    ok "[${dev}] Android.mk 更新完成"
    return 0
  fi

  [[ -f "${mk_path}" ]] || die "找不到 Android.mk: ${mk_path}"

  # 收集 lib 相對路徑（一行一筆）給 python — 來源是 REMOTE_LIB_FILES（cp 後 enumerate 的真實 remote 清單）
  local libs_rel=""
  if [[ -n "${LIBS_PATH}" ]]; then
    libs_rel=$(for f in "${REMOTE_LIB_FILES[@]}"; do echo "${f#${remote_libs_dir}/}"; done)
  fi

  set +e
  MK_PATH="${mk_path}" \
  APK_FN="${APK_FILENAME}" \
  ABI_NAME="${ABI_NAME}" \
  LIB_PATHS="${libs_rel}" \
  python3 - <<'PYEOF'
import os, re, sys

mk_path  = os.environ['MK_PATH']
apk_fn   = os.environ['APK_FN']
abi_name = os.environ.get('ABI_NAME', '')
lib_paths_raw = os.environ.get('LIB_PATHS', '')
lib_paths = [l for l in lib_paths_raw.split('\n') if l]

with open(mk_path, 'r') as f:
    content = f.read()

# 1) LOCAL_SRC_FILES → literal 替換
content = re.sub(
    r'^(LOCAL_SRC_FILES[ \t]*:=[ \t]*).*$',
    lambda m: m.group(1) + apk_fn,
    content,
    flags=re.MULTILINE,
)

if abi_name:
    # 2) LOCAL_TARGET_CPU_ABI
    abi_line = f'LOCAL_TARGET_CPU_ABI := {abi_name}'
    if re.search(r'^LOCAL_TARGET_CPU_ABI[ \t]*:=', content, re.MULTILINE):
        content = re.sub(
            r'^LOCAL_TARGET_CPU_ABI[ \t]*:=.*$',
            abi_line,
            content,
            flags=re.MULTILINE,
        )
    else:
        m = re.search(r'^include\s+\$\(BUILD_PREBUILT\)', content, re.MULTILINE)
        if not m:
            sys.stderr.write("MK_ANCHOR_MISSING\n")
            sys.exit(2)
        content = content[:m.start()] + abi_line + '\n' + content[m.start():]

    # 3) LOCAL_PREBUILT_JNI_LIBS（多行）— 用 line-based 處理
    lines = content.split('\n')
    new_lines = []
    insert_idx = None
    in_old_block = False

    for line in lines:
        if not in_old_block and re.match(r'^LOCAL_PREBUILT_JNI_LIBS[ \t]*:=', line):
            in_old_block = True
            insert_idx = len(new_lines)
            new_lines.append(None)   # placeholder
            if not line.rstrip().endswith('\\'):
                in_old_block = False
            continue
        if in_old_block:
            if not line.rstrip().endswith('\\'):
                in_old_block = False
            continue
        new_lines.append(line)

    # 組新區塊
    if lib_paths:
        if len(lib_paths) == 1:
            block = [f'LOCAL_PREBUILT_JNI_LIBS := libs/$(LOCAL_TARGET_CPU_ABI)/{lib_paths[0]}']
        else:
            block = ['LOCAL_PREBUILT_JNI_LIBS := \\']
            for i, p in enumerate(lib_paths):
                suffix = ' \\' if i < len(lib_paths) - 1 else ''
                block.append(f'    libs/$(LOCAL_TARGET_CPU_ABI)/{p}{suffix}')
    else:
        block = ['LOCAL_PREBUILT_JNI_LIBS :=']

    if insert_idx is not None:
        new_lines = new_lines[:insert_idx] + block + new_lines[insert_idx + 1:]
    else:
        inserted = False
        out = []
        for line in new_lines:
            if not inserted and re.match(r'^include\s+\$\(BUILD_PREBUILT\)', line):
                out.extend(block)
                out.append('')
                inserted = True
            out.append(line)
        if not inserted:
            sys.stderr.write("MK_ANCHOR_MISSING\n")
            sys.exit(2)
        new_lines = out

    content = '\n'.join(new_lines)

with open(mk_path, 'w') as f:
    f.write(content)
PYEOF
  local rc=$?
  set -e

  if [[ ${rc} -eq 2 ]]; then
    die "Android.mk 缺 \`include \$(BUILD_PREBUILT)\` 錨點，無法決定 LOCAL_TARGET_CPU_ABI / LOCAL_PREBUILT_JNI_LIBS 插入位置"
  elif [[ ${rc} -ne 0 ]]; then
    die "Android.mk 更新失敗（Python 處理階段）"
  fi

  # 印更新後的關鍵欄位
  log "Android.mk 已更新："
  local SRC_LINE ABI_LINE
  SRC_LINE=$(grep -E '^LOCAL_SRC_FILES[ \t]*:=' "${mk_path}" | head -1)
  log "  └─ ${SRC_LINE}"
  if [[ -n "${LIBS_PATH}" ]]; then
    ABI_LINE=$(grep -E '^LOCAL_TARGET_CPU_ABI[ \t]*:=' "${mk_path}" | head -1)
    log "  └─ ${ABI_LINE}"
    log "  └─ LOCAL_PREBUILT_JNI_LIBS:"
    for f in "${REMOTE_LIB_FILES[@]}"; do
      local rel="${f#${remote_libs_dir}/}"
      log "       libs/\$(LOCAL_TARGET_CPU_ABI)/${rel}"
    done
  fi
  ok "[${dev}] Android.mk 更新完成"
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
  local LIBS_REMOTE_DIR="${MODULE_DIR}/libs/${ABI_NAME}"   # 當 --libs 提供時用

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

  # 3. 複製 libs 至 repo（僅當 --libs 提供）
  if [[ -n "${LIBS_PATH}" ]]; then
    info "[${dev}] 偵測 ABI 資料夾: ${ABI_NAME}"
    deploy_libs "${dev}" "${LIBS_REMOTE_DIR}"
    # cp 完成後 enumerate remote libs，這份清單會寫入 LOCAL_PREBUILT_JNI_LIBS
    enumerate_remote_libs "${dev}" "${LIBS_REMOTE_DIR}"
  fi

  # 4. 更新 Android.mk（在所有 cp 結束之後才動）
  info "[${dev}] 更新 Android.mk"
  update_mk "${dev}" "${MK_PATH}" "${LIBS_REMOTE_DIR}"

  # 5. git add + commit + push
  info "[${dev}] git commit & push"
  local GIT_ADD_PATHS="'${EFFECTIVE_APK_SUBDIR}/${APP_NAME}/${APK_FILENAME}' '${EFFECTIVE_APK_SUBDIR}/${APP_NAME}/Android.mk'"
  if [[ -n "${LIBS_PATH}" ]]; then
    GIT_ADD_PATHS="${GIT_ADD_PATHS} '${EFFECTIVE_APK_SUBDIR}/${APP_NAME}/libs'"
  fi
  run "cd '${REPO}' && \
    git add ${GIT_ADD_PATHS} && \
    git commit --author='${GIT_AUTHOR_NAME} <${GIT_AUTHOR_EMAIL}>' -m '${COMMIT_MSG}' && \
    git push origin master"
  ok "[${dev}] push 完成"

  # 6. 部署後驗證；驗證失敗即視為該機種部署失敗，回傳非零
  if ! $NO_VERIFY; then
    if ! verify_device "${dev}" "${REPO}" "${APK_DEST_DIR}" "${MK_PATH}" "${LIBS_REMOTE_DIR}"; then
      log "${RED}${SEP}${RESET}"
      log "${RED}  ✗  [${dev}] 部署失敗（驗證未通過）${RESET}"
      log "${RED}${SEP}${RESET}\n\n"
      return 1
    fi
  fi

  log "${GREEN}${SEP}${RESET}"
  log "${GREEN}  ✔  [${dev}] 部署成功${RESET}"
  log "${GREEN}${SEP}${RESET}\n\n"
}

# ---------- 驗證函式 ----------
verify_device() {
  local dev="$1" repo="$2" apk_dir="$3" mk_path="$4" libs_remote_dir="${5:-}"
  info "[${dev}] 驗證部署結果..."
  local ERRORS=0
  local R_APK R_MK R_ABI R_LIB_LIST R_LIB_FILES R_NAME R_EMAIL R_MSG
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

  log "--- 驗證 Android.mk LOCAL_SRC_FILES ---"
  if grep -q "${APK_FILENAME}" "${mk_path}" 2>/dev/null; then
    log "  ✓ LOCAL_SRC_FILES 已更新為 ${APK_FILENAME}"
    R_MK="${PASS_TAG}"
  else
    log "  ✗ LOCAL_SRC_FILES 未包含 ${APK_FILENAME}"
    R_MK="${FAIL_TAG}"
    ERRORS=$(( ERRORS + 1 ))
  fi

  # ---------- 以下三項僅當 --libs 提供時驗證 ----------
  if [[ -n "${LIBS_PATH}" ]]; then
    log "--- 驗證 Android.mk LOCAL_TARGET_CPU_ABI ---"
    local ABI_LINE_VAL
    ABI_LINE_VAL=$(grep -E '^LOCAL_TARGET_CPU_ABI[ \t]*:=' "${mk_path}" 2>/dev/null | head -1 | sed -E 's|^LOCAL_TARGET_CPU_ABI[ \t]*:=[ \t]*||; s|[ \t]+$||')
    if [[ "${ABI_LINE_VAL}" == "${ABI_NAME}" ]]; then
      log "  ✓ LOCAL_TARGET_CPU_ABI = ${ABI_NAME}"
      R_ABI="${PASS_TAG}"
    else
      log "  ✗ LOCAL_TARGET_CPU_ABI 不符! expected='${ABI_NAME}' got='${ABI_LINE_VAL}'"
      R_ABI="${FAIL_TAG}"
      ERRORS=$(( ERRORS + 1 ))
    fi

    log "--- 驗證 Android.mk LOCAL_PREBUILT_JNI_LIBS ---"
    # 預期清單來源：REMOTE_LIB_FILES（cp 後 enumerate 的真實 remote 清單，跟 update_mk 寫入時一致）
    local LIB_LIST_OK=true
    local EXPECTED_LIB_LINE
    for f in "${REMOTE_LIB_FILES[@]}"; do
      local rel="${f#${libs_remote_dir}/}"
      EXPECTED_LIB_LINE="libs/\$(LOCAL_TARGET_CPU_ABI)/${rel}"
      if ! grep -qF "${EXPECTED_LIB_LINE}" "${mk_path}" 2>/dev/null; then
        log "  ✗ LOCAL_PREBUILT_JNI_LIBS 缺項: ${EXPECTED_LIB_LINE}"
        LIB_LIST_OK=false
        ERRORS=$(( ERRORS + 1 ))
      fi
    done
    if ${LIB_LIST_OK}; then
      log "  ✓ LOCAL_PREBUILT_JNI_LIBS 含 ${#REMOTE_LIB_FILES[@]} 筆，全數對齊"
      R_LIB_LIST="${PASS_TAG}"
    else
      R_LIB_LIST="${FAIL_TAG}"
    fi

    log "--- 驗證 JNI Libs files (MD5) ---"
    local lib_pass=0 lib_fail=0
    local FAILED_LIBS=()
    for f in "${LIB_FILES[@]}"; do
      local rel="${f#${LIBS_PATH}/}"
      local remote="${libs_remote_dir}/${rel}"
      if [[ ! -f "${remote}" ]]; then
        FAILED_LIBS+=("${rel}  (missing)")
        lib_fail=$(( lib_fail + 1 ))
        continue
      fi
      local src_md5 dst_md5
      src_md5=$(md5sum "${f}"      | awk '{print $1}')
      dst_md5=$(md5sum "${remote}" | awk '{print $1}')
      if [[ "${src_md5}" == "${dst_md5}" ]]; then
        lib_pass=$(( lib_pass + 1 ))
      else
        FAILED_LIBS+=("${rel}  (MD5 mismatch)")
        lib_fail=$(( lib_fail + 1 ))
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
      ERRORS=$(( ERRORS + 1 ))
    fi
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
  if [[ -n "${LIBS_PATH}" ]]; then
    log "  ${R_ABI}    Android.mk LOCAL_TARGET_CPU_ABI = ${ABI_NAME}"
    log "  ${R_LIB_LIST}    Android.mk LOCAL_PREBUILT_JNI_LIBS (${#REMOTE_LIB_FILES[@]} entries from remote)"
    log "  ${R_LIB_FILES}    JNI Libs files (${#LIB_FILES[@]} files MD5 vs staging)"
  fi
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

# ---------- 清除 staging（APK + libs）----------
# 規則：所有指定機種皆部署成功 → 刪除；任一失敗 → 保留供重試
if [[ ${#FAILED[@]} -eq 0 ]]; then
  if $DRY_RUN; then
    info "[DRY-RUN] rm ${APK_PATH}  # 全部成功，清除 staging APK"
    if [[ -n "${LIBS_PATH}" ]]; then
      info "[DRY-RUN] rm -rf ${LIBS_PATH}  # 全部成功，清除 staging libs 目錄"
    fi
  else
    rm -f "${APK_PATH}"
    ok "Staging APK 已清除: ${APK_FILENAME}"
    if [[ -n "${LIBS_PATH}" ]]; then
      rm -rf "${LIBS_PATH}"
      ok "Staging libs 目錄已清除: ${LIBS_PATH}"
    fi
  fi
else
  warn "有機種部署失敗，staging 保留供重試:"
  warn "  APK : ${APK_FILENAME}"
  [[ -n "${LIBS_PATH}" ]] && warn "  Libs: ${LIBS_PATH}"
  warn "重試時直接重新執行相同指令即可。"
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
