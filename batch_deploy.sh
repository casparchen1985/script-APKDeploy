#!/usr/bin/env bash
# =============================================================================
# batch_deploy.sh — 批次部署，讀取 deploy_plan.xml 逐筆呼叫 deploy_apk.sh
#
# 用法:
#   ./batch_deploy.sh --plan deploy_plan.xml [--dry-run]
#
# 依賴: python3（macOS / Linux / Windows 均內建，無需額外安裝）
#
# deploy_plan.xml 結構:
#   <deploy-plan>
#     <task>
#       <app>KeyMappingManager</app>
#       <apk>~/apk_deploy/toBeUploaded/KeyMappingManager_v1.2.3.apk</apk>
#       <author>Bob</author>
#       <message>Update KMM to v1.2.3: fix key remap crash</message>
#       <devices>
#         <device>rk26s</device>
#         <device>rs36s</device>
#       </devices>
#     </task>
#   </deploy-plan>
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy_apk.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PLAN_FILE=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan)    PLAN_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN="--dry-run"; shift ;;
    -h|--help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'; exit 0 ;;
    *) echo "未知參數: $1"; exit 1 ;;
  esac
done

[[ -z "${PLAN_FILE}" ]] && { echo "用法: $0 --plan <deploy_plan.xml>"; exit 1; }
[[ -f "${PLAN_FILE}"  ]] || { echo "找不到 plan 檔案: ${PLAN_FILE}";    exit 1; }

# ---------- 確認 python3 可用 ----------
command -v python3 &>/dev/null || {
  echo "ERROR: 需要 python3 來解析 XML（macOS/Linux/Windows 均內建）"
  exit 1
}

# ---------- 用 python3 解析 XML，輸出為 task 清單 ----------
# 每個 task 輸出一行，格式: APP\tAPK\tAUTHOR\tMESSAGE\tDEV1 DEV2 DEV3
TASK_LIST=$(python3 - "${PLAN_FILE}" << 'PYEOF'
import sys, xml.etree.ElementTree as ET

path = sys.argv[1]
try:
    tree = ET.parse(path)
except ET.ParseError as e:
    print(f"ERROR: XML 解析失敗: {e}", file=sys.stderr)
    sys.exit(1)

root = tree.getroot()
tasks = root.findall('task')
if not tasks:
    print("ERROR: deploy_plan.xml 中找不到任何 <task>", file=sys.stderr)
    sys.exit(1)

for i, task in enumerate(tasks, 1):
    def require(tag):
        el = task.find(tag)
        if el is None or not (el.text or '').strip():
            print(f"ERROR: task #{i} 缺少 <{tag}>", file=sys.stderr)
            sys.exit(1)
        return el.text.strip()

    app     = require('app')
    apk     = require('apk')
    author  = require('author')
    message = require('message')

    devices_el = task.find('devices')
    if devices_el is None:
        print(f"ERROR: task #{i} 缺少 <devices>", file=sys.stderr)
        sys.exit(1)
    devices = [d.text.strip() for d in devices_el.findall('device') if (d.text or '').strip()]
    if not devices:
        print(f"ERROR: task #{i} <devices> 內沒有任何 <device>", file=sys.stderr)
        sys.exit(1)

    print(f"{app}\t{apk}\t{author}\t{message}\t{' '.join(devices)}")
PYEOF
)

echo -e "${BOLD}====== Batch Deploy ======${RESET}"
echo -e "Plan : ${CYAN}${PLAN_FILE}${RESET}"
echo -e "Tasks: ${CYAN}$(echo "${TASK_LIST}" | wc -l | tr -d ' ')${RESET}"
echo ""

TOTAL=0; PASS=0; FAIL=0
FAILED_TASKS=()

while IFS=$'\t' read -r app apk author message devices_str; do
  TOTAL=$(( TOTAL + 1 ))
  echo -e "${BOLD}--- Task ${TOTAL}: ${app} ---${RESET}"

  read -ra device_arr <<< "${devices_str}"

  if bash "${DEPLOY_SCRIPT}" \
       --app     "${app}" \
       --apk     "${apk}" \
       --author  "${author}" \
       --message "${message}" \
       --device  "${device_arr[@]}" \
       ${DRY_RUN}; then
    PASS=$(( PASS + 1 ))
    echo -e "${GREEN}Task ${TOTAL} [${app}] 完成${RESET}\n"
  else
    FAIL=$(( FAIL + 1 ))
    FAILED_TASKS+=("${app}")
    echo -e "${RED}Task ${TOTAL} [${app}] 失敗${RESET}\n"
  fi
  echo ""
done <<< "${TASK_LIST}"

echo -e "${BOLD}====== Batch Result ======${RESET}"
echo -e "  總計: ${TOTAL}  ${GREEN}成功: ${PASS}${RESET}  ${RED}失敗: ${FAIL}${RESET}"
[[ ${FAIL} -gt 0 ]] && echo -e "  失敗任務: ${RED}${FAILED_TASKS[*]}${RESET}"

[[ ${FAIL} -eq 0 ]] && exit 0 || exit 1
