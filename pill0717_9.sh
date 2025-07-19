#!/usr/bin/env bash
###############################################################################
# GCP 项目 & Gemini API Key 批量管理脚本 (优化版)
# 原始作者: 类脑 @momo & @ddddd1996  修改作者: 类脑 @KKTsN
# 优化重构: (本版本) Apple 风格强化版
# 版本: v2.0
#
# 主要改进说明:
# 1. 并行调度修复: 原 run_parallel 使用 wait -n 后又对每个 PID 二次 wait，存在统计不准确潜在风险。
#    新实现采用 “启动 -> 记录PID -> 统一等待” 模式，逻辑更清晰，避免重复 wait。
# 2. 解析增强: 移除对 grep -P (在 macOS 默认不可用) 的依赖；优先使用 jq（若已安装），否则使用 sed 纯文本解析。
# 3. 可靠重试: retry_with_backoff 引入随机抖动 (jitter)，避免多个并发重试雪崩。
# 4. 跨平台锁: 移除对 flock 的硬依赖（macOS 无该命令）；改为 mkdir 原子目录锁，兼容 Linux/macOS。
# 5. 更安全随机: 使用 < /dev/urandom + tr + head -c，减少不必要的 cat 和 pipe。
# 6. 可选 CLI 参数: 支持非交互模式 (示例: ./5_optimized.sh --create -c 50 -j 20)。
# 7. 日志系统: 彩色输出（TTY 时启用），结构化时间戳 + 级别；支持 NO_COLOR 关闭。
# 8. 资源清理: trap 统一清理临时目录和心跳进程。
# 9. 键文件写入: 使用原子锁，确保高并发写入不交叉。
# 10. 可维护性: 模块分层、函数职责明确、变量命名规范、增加帮助说明。
# 11. 性能细节: 减少多余子进程 / subshell；控制并发检查采用 jobs -rp；只在需要时启动心跳。
# 12. 用户体验: 菜单更清晰；新增 --yes 跳过危险操作确认；进度行实时刷新。
# 13. 错误可诊断: 更聚焦的错误输出，保留失败场景上下文；重试过程中权限/认证错误立即中止。
# 14. 可扩展性: 增加配置入口 (环境变量 + CLI + 菜单)，支持脚本在自动化流水线中复用。
#
# 禁用彩色输出: NO_COLOR=1 ./5_optimized.sh --create
###############################################################################

# ========================== 安全与基础设置 ===========================
# 不使用 set -e 以便精细控制每一步错误；保留 pipefail 捕获管道错误
set -o pipefail
IFS=$'\n\t'

# ========================== 颜色与日志系统 ===========================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  COLOR_INFO='\033[34m'
  COLOR_WARN='\033[33m'
  COLOR_ERROR='\033[31m'
  COLOR_SUCCESS='\033[32m'
  COLOR_HEART='\033[35m'
  COLOR_RESET='\033[0m'
else
  COLOR_INFO='' COLOR_WARN='' COLOR_ERROR='' COLOR_SUCCESS='' COLOR_HEART='' COLOR_RESET=''
fi

log() {
  # 用法: log LEVEL MESSAGE
  local level=$1; shift
  local msg=$*
  local ts shell_level col
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    INFO)    col=$COLOR_INFO ;;
    WARN)    col=$COLOR_WARN ;;
    ERROR)   col=$COLOR_ERROR ;;
    SUCCESS) col=$COLOR_SUCCESS ;;
    HEARTBEAT) col=$COLOR_HEART ;;
    *)       col=$COLOR_INFO ;;
  esac
  printf '[%s] [%s%s%s] %s\n' "$ts" "$col" "$level" "$COLOR_RESET" "$msg"
}

# ========================== 全局配置 (可被 CLI / 菜单 / 环境覆盖) ===========================
API_NAME="generativelanguage.googleapis.com"
DEFAULT_TOTAL_PROJECTS=${TOTAL_PROJECTS:-75}       # 可被 --count 覆盖
DEFAULT_MAX_PARALLEL=${MAX_PARALLEL_JOBS:-15}
DEFAULT_GLOBAL_WAIT=${GLOBAL_WAIT_SECONDS:-75}
DEFAULT_MAX_RETRIES=${MAX_RETRY_ATTEMPTS:-3}
PROJECT_PREFIX=${PROJECT_PREFIX:-"hajimi-miyc"}

# 运行时变量
TOTAL_PROJECTS=$DEFAULT_TOTAL_PROJECTS
MAX_PARALLEL_JOBS=$DEFAULT_MAX_PARALLEL
GLOBAL_WAIT_SECONDS=$DEFAULT_GLOBAL_WAIT
MAX_RETRY_ATTEMPTS=$DEFAULT_MAX_RETRIES
AUTO_CONFIRM_DELETE=false
NON_INTERACTIVE_ACTION=""   # create | delete | ""

# 临时目录 + 结果文件
RUN_TIMESTAMP=$(date +%s)
TEMP_DIR=$(mktemp -d -t gcp_script_${RUN_TIMESTAMP}.XXXXXX 2>/dev/null || echo "/tmp/gcp_script_${RUN_TIMESTAMP}")
mkdir -p "$TEMP_DIR"
EMAIL_RANDOM=$(tr -dc 'a-z0-9' < /dev/urandom | head -c 4)
EMAIL_USERNAME="KK${EMAIL_RANDOM}${RUN_TIMESTAMP:(-4)}TsN"
PURE_KEY_FILE="key.txt"
COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
SECONDS=0
HEARTBEAT_PID=""

# ========================== 清理机制 ===========================
cleanup() {
  if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

# ========================== 心跳机制 ===========================
start_heartbeat() {
  local message="$1"; local interval=${2:-15}
  stop_heartbeat
  (
    while true; do
      log HEARTBEAT "$message"
      sleep "$interval" || break
    done
  ) &
  HEARTBEAT_PID=$!
}

stop_heartbeat() {
  if [ -n "$HEARTBEAT_PID" ] && kill -0 "$HEARTBEAT_PID" 2>/dev/null; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
  HEARTBEAT_PID=""
}

# ========================== 依赖检测 ===========================
require_command() {
  local cmd=$1
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log ERROR "缺少依赖命令: $cmd (请先安装)"
    return 1
  fi
  return 0
}

preflight_checks() {
  require_command gcloud || exit 1
  # jq 可选，不强制
  if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null 2>&1; then
    log WARN "未检测到已登录账号，尝试执行 gcloud auth login ..."
    if ! gcloud auth login; then
      log ERROR "gcloud 登录失败，退出。"
      exit 1
    fi
  fi
  if ! gcloud config get-value project >/dev/null 2>&1; then
    log WARN "未设置默认项目 (可忽略)。建议: gcloud config set project <PROJECT_ID>"
  fi
}

# ========================== JSON 解析 (keyString) ===========================
parse_key_string() {
  # 输入: JSON 字符串 (包含 keyString 字段)
  local json="$1"
  if [ -z "$json" ]; then return 1; fi
  if command -v jq >/dev/null 2>&1; then
    local v</PROJECT_ID>
    v=$(jq -r '.keyString // empty' 2>/dev/null <<<"$json") || true
    if [ -n "$v" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi
  # sed 回退方案 (兼容 macOS)
  local sed_val
  sed_val=$(printf '%s' "$json" | sed -n 's/.*"keyString"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -n "$sed_val" ] && printf '%s\n' "$sed_val"
  [ -n "$sed_val" ]
}

# ========================== 原子写入密钥 ===========================
write_key() {
  local api_key="$1"
  [ -z "$api_key" ] && return 0
  # 目录锁 (原子 mkdir)
  while ! mkdir "$TEMP_DIR/keys.lock" 2>/dev/null; do sleep 0.02; done
  {
    printf '%s\n' "$api_key" >> "$PURE_KEY_FILE"
    # 逗号分隔文件按需追加逗号
    if [ -s "$COMMA_SEPARATED_KEY_FILE" ]; then printf ',' >> "$COMMA_SEPARATED_KEY_FILE"; fi
    printf '%s' "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
  }
  rmdir "$TEMP_DIR/keys.lock" 2>/dev/null || true
}

# ========================== 重试 & 回退 ===========================
retry_with_backoff() {
  local max_attempts=$1; shift
  local attempt=1
  local delay=5
  local cmd=("$@")
  local stderr_file
  stderr_file=$(mktemp -p "$TEMP_DIR" retry_stderr.XXXX)
  while [ $attempt -le $max_attempts ]; do
    if "${cmd[@]}" 2>"$stderr_file"; then
      rm -f "$stderr_file"
      return 0
    fi
    local err
    err=$(cat "$stderr_file")
    if [[ "$err" == *"Permission denied"* || "$err" == *"Authentication failed"* || "$err" == *"forbidden"* ]]; then
      log ERROR "权限/认证错误, 停止重试: ${cmd[*]}"
      rm -f "$stderr_file"
      return 1
    fi
    if [ $attempt -lt $max_attempts ]; then
      local jitter=$((RANDOM % 3))
      log WARN "命令失败(第 $attempt/$max_attempts 次): ${cmd[*]} -> $err | ${delay}s 后重试 (含抖动+$jitter)"
      sleep $((delay + jitter))
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  log ERROR "命令最终失败(共 $max_attempts 次): ${cmd[*]} | 最终错误: $(cat "$stderr_file")"
  rm -f "$stderr_file"
  return 1
}

# ========================== 项目 ID 生成 ===========================</<<"$json")>
# 生成 TOTAL_PROJECTS 个唯一项目 ID (尽量满足 GCP 规则: 小写字母开头, 长度<=30, 允许 a-z0-9-)
make_project_ids() {
  local i id base padded
  local arr=()
  for i in $(seq 1 "$TOTAL_PROJECTS"); do
    padded=$(printf '%03d' "$i")
    base="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${padded}"
    id=$(echo "$base" | tr -cd 'a-z0-9-' | cut -c1-30 | sed 's/-$//')
    # 确保首字符为字母
    if ! [[ $id =~ ^[a-z] ]]; then
      id="g${id}"; id=$(echo "$id" | cut -c1-30 | sed 's/-$//')
    fi
    arr+=("$id")
  done
  printf '%s\n' "${arr[@]}"
}

# ========================== 任务函数 ===========================
# 所有任务函数: 成功返回 0, 失败返回非 0

create_project_task() {
  local project_id="$1"; local success_file="$2"
  if gcloud projects describe "$project_id" >/dev/null 2>&1; then
    log WARN "项目已存在 (跳过创建): $project_id"
    echo "$project_id" >> "$success_file"
    return 0
  fi
  if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet >/dev/null 2>&1; then
    echo "$project_id" >> "$success_file"
    return 0
  else
    log ERROR "创建项目失败: $project_id"
    return 1
  fi
}

enable_api_task() {
  local project_id="$1"; local success_file="$2"
  if retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services enable "$API_NAME" --project="$project_id" --quiet; then
    echo "$project_id" >> "$success_file"
    return 0
  else
    log ERROR "启用 API 失败: $project_id"
    return 1
  fi
}

create_key_task() {
  local project_id="$1"; local dummy_file="$2" # dummy_file 占位保持函数签名一致
  local output
  if ! output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services api-keys create\"$1\"; local success_file=\"$2\"\n  if retry_with_backoff \"$MAX_RETRY_ATTEMPTS\" gcloud services enable \"$API_NAME\" --project=\"$project_id\" --quiet; then\n    echo \"$project_id\" >> \"$success_file\"\n    return 0\n  else\n    log ERROR \"启用 API 失败: $project_id\"\n    return 1\n  fi\n}\n\ncreate_key_task() {\n  local project_id=\"$1\"; local dummy_file=\"$2\" # dummy_file 占位保持函数签名一致\n  local output\n  if ! output=$(retry_with_backoff \"$MAX_RETRY_ATTEMPTS\" gcloud services api-keys create \\\n        --project=\"$project_id\" \\\n        --display-name=\"Gemini API Key for $project_id\" \\\: $project_id" >> "$DELETION_LOG"
    return 0
  else
    log ERROR "删除失败: $project_id"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除失败: $project_id" >> "$DELETION_LOG"
    return 1
  fi
}

# ========================== 并行调度器 ===========================</=30,>
# 用法: run_parallel <描述> </描述><任务函数名> </任务函数名><成功记录文件> </成功记录文件><item1> </item1><item2> ...
run_parallel() {
  local desc="$1"; shift
  local task_func="$1"; shift
  local success_file="$1"; shift
  local items=("$@")
  local total=${#items[@]}
  [ $total -eq 0 ] && log INFO "无任务可执行: $desc" && return 0

  : > "$success_file"
  local pids=()
  local started=0 completed=0 success=0 fail=0

  log INFO "开始: $desc (并行度: $MAX_PARALLEL_JOBS, 任务数: $total)"
  start_heartbeat "$desc 运行中..." 20

  for item in "${items[@]}"; do
    # 控制并发: 当前运行后台任务数 >= 限制则等待短暂
    while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$MAX_PARALLEL_JOBS" ]; do
      sleep 0.2
    done
    ("$task_func" "$item" "$success_file") &
    pids+=("$!")
    started=$((started + 1))
  done

  # 统一收割结果
  for pid in "${pids[@]}"; do
    if wait "$pid"; then
      success=$((success + 1))
    else
      fail=$((fail + 1))
    fi
    completed=$((completed + 1))
    printf "\r%s 进度: %d/%d (成功:%d 失败:%d)" "$desc" "$completed" "$total" "$success" "$fail"
  done
  echo
  stop_heartbeat
  log INFO "完成: $desc | 成功: $success | 失败: $fail"
  [ $fail -eq 0 ]
}

# ========================== 报告函数 ===========================
report_creation() {
  local success_keys="$1"; local target="$2"
  echo
  echo "========== 执行报告 =========="
  echo "计划目标: ${target} 个项目"
  echo "成功获取密钥: ${success_keys} 个"
  echo "失败: $((target - success_keys)) 个"
  echo "API 密钥已保存:"
  echo " - 每行一个: $PURE_KEY_FILE"
  echo " - 逗号分隔: $COMMA_SEPARATED_KEY_FILE"
  echo "================================"
}

report_deletion() {
  local total="$1"; local duration=$SECONDS
  local minutes=$((duration / 60)); local seconds=$((duration % 60))
  echo
  echo "========== 删除报告 =========="
  echo "尝试删除: $total 个项目"
  local succ fail
  succ=$(grep -c '已删除:' "$DELETION_LOG" 2>/dev/null || echo 0)
  fail=$(grep -c '删除失败:' "$DELETION_LOG" 2>/dev/null || echo 0)
  echo "成功删除: $succ"
  echo "删除失败: $fail"
  echo "耗时: ${minutes}分${seconds}秒"
  echo "详细日志: $DELETION_LOG"
  echo "================================"
}

# ========================== 核心功能: 创建项目并获取密钥 ===========================
create_projects_and_get_keys() {
  SECONDS=0
  log INFO "任务: 创建 ${TOTAL_PROJECTS} 个项目并获取 API Key (用户名: $EMAIL_USERNAME)"
  : > "$PURE_KEY_FILE"
  : > "$COMMA_SEPARATED_KEY_FILE"

  log INFO "生成项目 ID 列表..."</item2>
  mapfile -t PROJECT_IDS < <(make_project_ids)

  # 阶段 1: 创建项目
  local CREATED_FILE="$TEMP_DIR/created_projects.txt"; : > "$CREATED_FILE"
  run_parallel "阶段1: 创建项目" create_project_task "$CREATED_FILE" "${PROJECT_IDS[@]}" || true
  mapfile -t CREATED_IDS < "$CREATED_FILE" 2>/dev/null || true
  if [ ${#CREATED_IDS[@]} -eq 0 ]; then
    log ERROR "项目创建阶段全部失败，终止。"
    report_creation 0 "$TOTAL_PROJECTS"
    return 1
  fi

  # 阶段 2: 全局等待 (可调整或动态探测)
  log INFO "阶段2: 等待 ${GLOBAL_WAIT_SECONDS}s 以确保项目在后端完全可用..."
  start_heartbeat "全局等待中..." 10
  sleep "$GLOBAL_WAIT_SECONDS"
  stop_heartbeat
  log INFO "阶段2完成"

  # 阶段 3: 启用 API
  local ENABLED_FILE="$TEMP_DIR/enabled_projects.txt"; : > "$ENABLED_FILE"
  run_parallel "阶段3: 启用 API (${API_NAME})" enable_api_task "$ENABLED_FILE" "${CREATED_IDS[@]}" || true
  mapfile -t ENABLED_IDS < "$ENABLED_FILE" 2>/dev/null || true
  if [ ${#ENABLED_IDS[@]} -eq 0 ]; then
    log ERROR "API 启用阶段失败，无可用项目。"
    report_creation 0 "$TOTAL_PROJECTS"
    return 1
  fi

  # 阶段 4: 创建密钥
  run_parallel "阶段4: 创建密钥" create_key_task /dev/null "${ENABLED_IDS[@]}" || true

  local SUCCESS_KEYS
  SUCCESS_KEYS=$(wc -l < "$PURE_KEY_FILE" 2>/dev/null | tr -d ' ' || echo 0)
  report_creation "$SUCCESS_KEYS" "$TOTAL_PROJECTS"
  if [ "$SUCCESS_KEYS" -lt "$TOTAL_PROJECTS" ]; then
    log WARN "有 $((TOTAL_PROJECTS - SUCCESS_KEYS)) 个项目未获取到密钥，请查看日志。"
  fi
  log SUCCESS "任务完成。耗时: ${SECONDS}s"
}

# ========================== 删除所有项目 ===========================
delete_all_projects() {
  SECONDS=0
  log WARN "危险操作: 将删除当前账号下所有(非 sys- 前缀)项目"
  local PROJECT_LIST EC
  if ! PROJECT_LIST=$(gcloud projects list --format='value(projectId)' --filter='projectId!~^sys-' 2>/dev/null); then
    log ERROR "获取项目列表失败"
    return 1
  fi
  local arr=()</(make_project_ids)>
  while IFS= read -r line; do [ -n "$line" ] && arr+=("$line"); done <<<"$PROJECT_LIST"
  local total=${#arr[@]}
  if [ $total -eq 0 ]; then
    log INFO "没有可删除的用户项目。"
    return 0
  fi
  if ! $AUTO_CONFIRM_DELETE; then
    read -r -p "确认删除全部 $total 个项目? 输入 'DELETE-ALL' 继续: " confirm
    if [ "$confirm" != "DELETE-ALL" ]; then
      log INFO "删除操作已取消。"
      return 1
    fi
  fi
  echo "项目删除日志 ($(date +%Y-%m-%d_%H:%M:%S))" > "$DELETION_LOG"
  echo "--------------------------------" >> "$DELETION_LOG"
  run_parallel "删除项目" delete_project_task /dev/null "${arr[@]}" || true
  report_deletion "$total"
}

# ========================== 配置交互 (菜单内) ===========================
configure_settings() {
  while true; do
    clear
    echo "================ 配置参数 ================"
    echo "1. 项目创建数量: $TOTAL_PROJECTS"
    echo "2. 项目前缀: $PROJECT_PREFIX"
    echo "3. 最大并行任务数: $MAX_PARALLEL_JOBS"
    echo "4. 最大重试次数: $MAX_RETRY_ATTEMPTS"
    echo "5. 全局等待时间(秒): $GLOBAL_WAIT_SECONDS"
    echo "0. 返回"
    echo "=========================================="
    read -r -p "选择要修改的设置 [0-5]: " opt
    case "$opt" in
      1) read -r -p "输入项目数量(1-75): " val; [[ "$val" =~ ^[1-9][0-9]*$ ]] && [ "$val" -le 200 ] && TOTAL_PROJECTS=$val ;;</<<"$PROJECT_LIST">
      2) read -r -p "输入项目前缀(字母开头, <=20, a-z0-9-): " val; [[ "$val" =~ ^[a-z][a-z0-9-]{0,19}$ ]] && PROJECT_PREFIX=$val ;;
      3) read -r -p "输入并行数(1-40): " val; [[ "$val" =~ ^[1-9][0-9]*$ ]] && [ "$val" -le 100 ] && MAX_PARALLEL_JOBS=$val ;;
      4) read -r -p "输入最大重试(1-10): " val; [[ "$val" =~ ^[1-9][0-9]*$ ]] && [ "$val" -le 10 ] && MAX_RETRY_ATTEMPTS=$val ;;
      5) read -r -p "输入全局等待秒数(10-300): " val; [[ "$val" =~ ^[1-9][0-9]*$ ]] && [ "$val" -le 300 ] && GLOBAL_WAIT_SECONDS=$val ;;
      0) return ;;
      *) echo "无效选项"; sleep 1 ;;
    esac
  done
}

# ========================== 主菜单 ===========================
show_menu() {
  clear
  cat <<'BANNER'
   ______   ______   ____     __  __           __
  / ____/  / ____/  / __ \   / / / /  ___     / /  ____     ___     _____
 / / __   / /      / /_/ /  / /_/ /  / _ \   / /  / __ \   / _ \   / ___/
/ /_/ /  / /___   / ____/  / __  /  /  __/  / /  / /_/ /  /  __/  / /
\____/   \____/  /_/      /_/ /_/   \___/  /_/  / .___/   \___/  /_/
                                              /_/
BANNER
  echo "GCP 项目 & 密钥管理工具 (v1.2)"
  echo "======================================================"
  local current_account current_project
  current_account=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n1)
  current_project=$(gcloud config get-value project 2>/dev/null || echo '未设置')
  [ -z "$current_account" ] && current_account='无法获取'
  echo "当前账号: $current_account"
  echo "默认项目: $current_project"
  echo "固定创建数量: $TOTAL_PROJECTS"
  echo "并行任务数: $MAX_PARALLEL_JOBS"
  echo "全局等待: ${GLOBAL_WAIT_SECONDS}s"
  echo "重试次数: $MAX_RETRY_ATTEMPTS"
  echo "======================================================"
  echo "1. 创建 ${TOTAL_PROJECTS} 个项目并获取 API Key"
  echo "2. 删除所有现有项目"
  echo "3. 修改配置参数"
  echo "0. 退出"
  echo "======================================================"
  read -r -p "请选择 [0-3]: " choice
  case "$choice" in
    1) create_projects_and_get_keys ;;
    2) delete_all_projects ;;
    3) configure_settings ;;
    0) log INFO "退出"; exit 0 ;;
    *) echo "无效选项"; sleep 1 ;;
  esac
  read -r -p "按回车返回菜单..." _
}

# ========================== CLI 参数解析 ===========================
print_help() {
  cat <<EOF
用法: $0 [选项]

选项 (可与菜单交互二选一):
  --create              非交互模式: 直接批量创建项目并获取密钥
  --delete              非交互模式: 删除所有项目
  -c, --count N         创建项目数量 (覆盖默认 $TOTAL_PROJECTS)
  -j, --jobs N          最大并行任务数 (默认 $MAX_PARALLEL_JOBS)
  -w, --wait N          全局等待秒数 (默认 $GLOBAL_WAIT_SECONDS)
  -r, --retries N       最大重试次数 (默认 $MAX_RETRY_ATTEMPTS)
  -p, --prefix STR      项目前缀 (默认 $PROJECT_PREFIX)
  -y, --yes             删除操作自动确认
  --no-color            禁用彩色输出 (等同于 NO_COLOR=1)
  -h, --help            显示帮助

示例:
  $0 --create -c 50 -j 20 -w 90
  NO_COLOR=1 $0 --delete --yes
EOF
}

parse_cli() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --create) NON_INTERACTIVE_ACTION="create"; shift ;;
      --delete) NON_INTERACTIVE_ACTION="delete"; shift ;;
      -c|--count) TOTAL_PROJECTS=$2; shift 2 ;;
      -j|--jobs) MAX_PARALLEL_JOBS=$2; shift 2 ;;
      -w|--wait) GLOBAL_WAIT_SECONDS=$2; shift 2 ;;
      -r|--retries) MAX_RETRY_ATTEMPTS=$2; shift 2 ;;
      -p|--prefix) PROJECT_PREFIX=$2; shift 2 ;;
      -y|--yes) AUTO_CONFIRM_DELETE=true; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) log WARN "忽略未知参数: $1"; shift ;;
    esac
  done
}

# ========================== 主流程 ===========================
main() {
  parse_cli "$@"
  preflight_checks
  log INFO "用户名随机片段: $EMAIL_USERNAME"
  log INFO "配置: 数量=$TOTAL_PROJECTS 并行=$MAX_PARALLEL_JOBS 等待=${GLOBAL_WAIT_SECONDS}s 重试=$MAX_RETRY_ATTEMPTS 前缀=$PROJECT_PREFIX"

  case "$NON_INTERACTIVE_ACTION" in
    create)
      create_projects_and_get_keys
      return
      ;;
    delete)
      delete_all_projects
      return
      ;;
    "")
      # 交互模式
      while true; do
        show_menu
      done
      ;;
  esac
}

main "$@"

# 结束</=20,>