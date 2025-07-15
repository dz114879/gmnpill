#!/bin/bash

# ==============================================================================
# GCP Gemini API 密钥懒人管理工具 v4.0 (Refactored)
#
# 重构说明:
# - 并行处理: 使用 xargs -P 代替手动的后台作业管理，简化并行逻辑。
# - 数据流: 使用函数返回值和数组代替临时文件在阶段间传递数据。
# - JSON解析: 优先使用 'jq' (如果可用)，否则回退到 sed/grep。
# - 模块化: 代码结构更清晰，函数职责更单一。
# ==============================================================================

# ===== 配置 (可修改) =====
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=50
MAX_PARALLEL_JOBS=40
GLOBAL_WAIT_SECONDS=75
MAX_RETRY_ATTEMPTS=3
# ===== 配置结束 =====

# ===== 全局常量 (勿动) =====
readonly TIMESTAMP=$(date +%s)
readonly RANDOM_CHARS=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
readonly EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
readonly PURE_KEY_FILE="key.txt"
readonly COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"
readonly DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
readonly TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
SECONDS=0 # 用于计时
# ===== 全局常量结束 =====

# ===== 初始化与清理 =====
mkdir -p "$TEMP_DIR"
trap 'cleanup_resources' EXIT SIGINT SIGTERM

cleanup_resources() {
  log "INFO" "执行退出清理..."
  rm -rf "$TEMP_DIR"
}
# ===== 初始化与清理结束 =====

# ===== 工具函数 =====

# 日志记录
_log_internal() {
  local level="$1" msg="$2"
  printf "[%s] [%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$msg"
}
log() { _log_internal "$1" "$2"; }

# JSON 解析 (优先使用 jq)
parse_json() {
  local json="$1" field="$2" value=""
  if ! command -v jq &> /dev/null; then
    # 备用方法: sed/grep
    case "$field" in
      ".keyString") value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p');;
      *) local field_name; field_name=$(echo "$field" | tr -d '.["]'); value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*");;
    esac
  else
    # 首选方法: jq
    value=$(echo "$json" | jq -r "$field")
  fi
  
  if [[ -n "$value" && "$value" != "null" ]]; then
    echo "$value"
    return 0
  else
    return 1
  fi
}

# 带退避的重试
retry_with_backoff() {
  local max_attempts=$1 cmd=$2 attempt=1 timeout=5
  shift 2
  local args=("$@")
  
  while (( attempt <= max_attempts )); do
    # 通过eval执行命令以正确处理带引号的参数
    if output=$(eval "$cmd" "${args[@]}" 2>&1); then
      echo "$output"
      return 0
    fi
    
    if [[ "$output" == *"Permission denied"* || "$output" == *"Authentication failed"* ]]; then
      log "ERROR" "权限或认证错误，停止重试: $output"
      return 1
    fi
    
    if (( attempt < max_attempts )); then
      sleep $timeout
      timeout=$((timeout * 2))
    fi
    ((attempt++))
  done
  
  log "ERROR" "命令在 $max_attempts 次尝试后最终失败。最后错误: $output"
  return 1
}

# 进度条显示
show_progress() {
    local completed=$1 total=$2
    if (( total <= 0 )); then return; fi
    (( completed > total )) && completed=$total
    
    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 50 / 100))
    local remaining_chars=$((50 - completed_chars))
    
    local progress_bar; progress_bar=$(printf "%${completed_chars}s" "" | tr ' ' '#')
    local remaining_bar; remaining_bar=$(printf "%${remaining_chars}s" "")
    
    printf "\r[%s%s] %d%% (%d/%d)" "$progress_bar" "$remaining_bar" "$percent" "$completed" "$total"
}

# 写入密钥到文件 (带锁)
write_keys_to_files() {
    local api_key="$1"
    if [ -z "$api_key" ]; then return; fi
    (
        flock 200
        echo "$api_key" >> "$PURE_KEY_FILE"
        # 如果文件非空，则先加逗号
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# ===== 核心 GCP 任务函数 =====
# 每个函数接受一个 project_id，成功时将 project_id 输出到 stdout，失败时返回非零退出码。

task_create_project() {
    local project_id="$1"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet &>/dev/null; then
        echo "$project_id" # 成功，输出ID
        return 0
    else
        log "ERROR" "创建项目失败: $project_id"
        return 1
    fi
}

task_enable_api() {
    local project_id="$1"
    local cmd="gcloud services enable generativelanguage.googleapis.com --project=\"$project_id\" --quiet"
    if retry_with_backoff $MAX_RETRY_ATTEMPTS "$cmd"; then
        echo "$project_id" # 成功，输出ID
        return 0
    else
        log "ERROR" "启用API失败: $project_id"
        return 1
    fi
}

task_create_key() {
    local project_id="$1"
    local cmd="gcloud services api-keys create --project=\"$project_id\" --display-name=\"Gemini API Key for $project_id\" --format=\"json\" --quiet"
    
    local create_output
    if ! create_output=$(retry_with_backoff $MAX_RETRY_ATTEMPTS "$cmd"); then
        log "ERROR" "创建密钥失败: $project_id"
        return 1
    fi
    
    local api_key
    if api_key=$(parse_json "$create_output" ".keyString"); then
        log "SUCCESS" "成功提取密钥: $project_id"
        write_keys_to_files "$api_key"
        echo "$project_id" # 成功，输出ID
        return 0
    else
        log "ERROR" "提取密钥失败: $project_id (无法从gcloud输出解析keyString)"
        return 1
    fi
}

task_delete_project() {
  local project_id="$1"
  if gcloud projects delete "$project_id" --quiet &>/dev/null; then
    log "SUCCESS" "成功删除项目: $project_id"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已删除: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    echo "$project_id"
    return 0
  else
    log "ERROR" "删除项目失败: $project_id"
    ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除失败: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
    return 1
  fi
}

# ===== 并行执行器 =====
# 使用 xargs -P 和 mapfile 进行高性能并行处理
run_parallel() {
    local task_func="$1" description="$2"
    shift 2
    local items=("$@")
    local total_items=${#items[@]}

    if (( total_items == 0 )); then
        log "INFO" "在 '$description' 阶段没有项目需要处理。"
        # 输出空内容，以便调用方的 mapfile 不会出错
        echo ""
        return 0
    fi

    log "INFO" "开始并行执行 '$description' (共 $total_items 个项目，最多 $MAX_PARALLEL_JOBS 个并行)..."
    
    # 导出所需函数和变量，以便 xargs 的子shell可以访问
    export -f "$task_func" log _log_internal retry_with_backoff parse_json write_keys_to_files show_progress
    export MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE TEMP_DIR DELETION_LOG
    
    local success_results=()
    # 使用 mapfile 和进程替换直接从 xargs 的输出中读取结果
    # 这避免了子shell问题和临时文件I/O，性能更高
    mapfile -t success_results < <(printf "%s\n" "${items[@]}" | xargs -I {} -P "$MAX_PARALLEL_JOBS" bash -c "$task_func '{}'")

    local final_success_count=${#success_results[@]}
    local final_fail_count=$((total_items - final_success_count))

    # 任务完成后，一次性报告结果
    show_progress "$total_items" "$total_items" # 显示100%完成
    echo
    log "INFO" "阶段 '$description' 完成。成功: $final_success_count, 失败: $final_fail_count"
    log "INFO" "======================================================"
    
    # 将成功的结果输出到 stdout，以便调用者可以捕获它们
    if (( final_success_count > 0 )); then
        printf "%s\n" "${success_results[@]}"
    fi

    if (( final_fail_count > 0 )); then
        return 1
    else
        return 0
    fi
}

# ===== 主工作流 =====

create_projects_and_get_keys() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "高速模式: 创建固定的 $TOTAL_PROJECTS 个项目并获取API密钥"
    log "INFO" "======================================================"
    log "INFO" "将使用随机生成的用户名: ${EMAIL_USERNAME}"
    log "INFO" "脚本将在 3 秒后开始执行..."; sleep 3

    # --- 准备工作 ---
    > "$PURE_KEY_FILE"; > "$COMMA_SEPARATED_KEY_FILE"
    
    # --- 阶段 0: 生成项目ID列表 ---
    local projects_to_create=()
    for i in $(seq 1 $TOTAL_PROJECTS); do
        local project_num; project_num=$(printf "%03d" $i)
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        # 清理并确保项目ID有效
        local project_id; project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
            project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//')
        fi
        projects_to_create+=("$project_id")
    done

    # --- 阶段 1: 创建项目 ---
    # 使用 mapfile 和进程替换来直接捕获 run_parallel 的成功输出
    mapfile -t created_project_ids < <(run_parallel task_create_project "阶段1: 创建项目" "${projects_to_create[@]}")
    if (( ${#created_project_ids[@]} == 0 )); then
        log "ERROR" "项目创建阶段失败，没有任何项目成功创建。中止操作。"
        return 1
    fi

    # --- 阶段 2: 全局等待 ---
    log "INFO" "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒，以便GCP后端同步项目状态..."
    for ((i=1; i<=${GLOBAL_WAIT_SECONDS}; i++)); do
        sleep 1; show_progress "$i" "${GLOBAL_WAIT_SECONDS}"; echo -n " 等待中..."
    done
    echo; log "INFO" "等待完成。"; log "INFO" "======================================================"

    # --- 阶段 3: 启用API ---
    # 同样，直接捕获启用了API的项目ID
    mapfile -t enabled_project_ids < <(run_parallel task_enable_api "阶段3: 启用API" "${created_project_ids[@]}")
    if (( ${#enabled_project_ids[@]} == 0 )); then
        log "ERROR" "API启用阶段失败，没有任何项目成功启用API。中止操作。"
        generate_report 0 "$TOTAL_PROJECTS"
        return 1
    fi

    # --- 阶段 4: 创建密钥 ---
    run_parallel task_create_key "阶段4: 创建密钥" "${enabled_project_ids[@]}"

    # --- 最终报告 ---
    local successful_keys; successful_keys=$(wc -l < "$PURE_KEY_FILE" | xargs)
    generate_report "$successful_keys" "$TOTAL_PROJECTS"
    log "INFO" "======================================================"
    log "INFO" "请检查文件 '$PURE_KEY_FILE' 和 '$COMMA_SEPARATED_KEY_FILE' 中的内容"
    if (( successful_keys < TOTAL_PROJECTS )); then
        log "WARN" "有 $((TOTAL_PROJECTS - successful_keys)) 个项目未能成功获取密钥，请检查上方日志了解详情。"
    fi
    log "INFO" "提醒：项目需要关联有效的结算账号才能实际使用 API 密钥"
    log "INFO" "======================================================"
}

delete_all_existing_projects() {
    SECONDS=0
    log "INFO" "======================================================"
    log "INFO" "功能2: 删除所有现有项目"
    log "INFO" "======================================================"
    
    log "INFO" "正在获取项目列表..."
    local all_projects
    if ! all_projects=$(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet); then
        log "ERROR" "无法获取项目列表。"
        return 1
    fi
    
    mapfile -t all_projects_arr <<< "$all_projects"
    
    if (( ${#all_projects_arr[@]} == 0 )); then
        log "INFO" "未找到任何用户项目，无需删除。"
        return 0
    fi
    
    local total_to_delete=${#all_projects_arr[@]}
    log "INFO" "找到 $total_to_delete 个用户项目需要删除"
    
    read -p "!!! 危险操作 !!! 确认要删除所有 $total_to_delete 个项目吗？(输入 'DELETE-ALL' 确认): " confirm
    if [[ "$confirm" != "DELETE-ALL" ]]; then
        log "INFO" "删除操作已取消"
        return 1
    fi
    
    echo "项目删除日志 ($(date +%Y-%m-%d_%H:%M:%S))" > "$DELETION_LOG"
    echo "------------------------------------" >> "$DELETION_LOG"
    
    run_parallel task_delete_project "删除项目" "${all_projects_arr[@]}"
    
    local duration=$SECONDS
    local minutes=$((duration / 60))
    local seconds_rem=$((duration % 60))
    
    echo
    echo "========== 删除报告 =========="
    echo "总计尝试删除: $total_to_delete 个项目"
    # Note: Success/Fail count is already printed by run_parallel
    echo "总执行时间: $minutes 分 $seconds_rem 秒"
    echo "详细日志已保存至: $DELETION_LOG"
    echo "=========================="
}

generate_report() {
  local success=$1 attempted=$2
  local failed=$((attempted - success))
  local duration=$SECONDS
  local minutes=$((duration / 60))
  local seconds_rem=$((duration % 60))
  
  echo
  echo "========== 执行报告 =========="
  echo "计划目标: $attempted 个项目"
  echo "成功获取密钥: $success 个"
  echo "失败: $failed 个"
  if (( success > 0 )); then
    local avg_time=$((duration / success))
    echo "平均处理时间 (成功项目): $avg_time 秒/项目"
  fi
  echo "总执行时间: $minutes 分 $seconds_rem 秒"
  echo "API密钥已保存至:"
  echo "- 纯API密钥 (每行一个): $PURE_KEY_FILE"
  echo "- 逗号分隔密钥 (单行): $COMMA_SEPARATED_KEY_FILE"
  echo "=========================="
}

# ===== UI & 菜单 =====

configure_settings() {
  while true; do
      clear
      echo "======================================================"
      echo "                      配置参数"
      echo "======================================================"
      echo "当前设置:"
      echo "1. 项目前缀 (用于新建项目): $PROJECT_PREFIX"
      echo "2. 最大并行任务数: $MAX_PARALLEL_JOBS"
      echo "3. 最大重试次数 (用于API调用): $MAX_RETRY_ATTEMPTS"
      echo "4. 全局等待时间 (秒): $GLOBAL_WAIT_SECONDS"
      echo "5. 固定创建数量: $TOTAL_PROJECTS"
      echo "0. 返回主菜单"
      echo "======================================================"
      read -p "请选择要修改的设置 [0-5]: " setting_choice
      
      case $setting_choice in
        1) read -p "请输入新的项目前缀 (留空取消): " new_prefix
           if [[ -n "$new_prefix" && "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
               PROJECT_PREFIX="$new_prefix"
           elif [[ -n "$new_prefix" ]]; then
               echo "无效的前缀格式。必须以小写字母开头，只包含小写字母、数字和连字符。"
               sleep 2
           fi
           ;;
        2) read -p "请输入最大并行任务数 (建议 20-80，留空取消): " new_parallel
           if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]]; then MAX_PARALLEL_JOBS=$new_parallel; fi
           ;;
        3) read -p "请输入最大重试次数 (建议 1-5，留空取消): " new_retries
           if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]]; then MAX_RETRY_ATTEMPTS=$new_retries; fi
           ;;
        4) read -p "请输入新的全局等待时间 (秒, 建议 60-120, 留空取消): " new_wait
           if [[ "$new_wait" =~ ^[1-9][0-9]*$ ]]; then GLOBAL_WAIT_SECONDS=$new_wait; fi
           ;;
        5) read -p "请输入新的固定创建数量 (建议 10-100, 留空取消): " new_total
           if [[ "$new_total" =~ ^[1-9][0-9]*$ ]]; then TOTAL_PROJECTS=$new_total; fi
           ;;
        0) return ;;
        *) echo "无效选项 '$setting_choice'，请重新选择。"; sleep 2 ;;
      esac
  done
}

show_menu() {
  clear
  echo "======================================================"
  echo "  GCP Gemini API 密钥懒人管理工具 v4.0 (Refactored)"
  echo "======================================================"
  local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1)
  local current_project; current_project=$(gcloud config get-value project 2>/dev/null)
  
  echo "当前账号: ${current_account:-无法获取}"
  echo "当前项目: ${current_project:-未设置}"
  echo "固定创建数量: $TOTAL_PROJECTS"
  echo "并行任务数: $MAX_PARALLEL_JOBS"
  echo "全局等待: ${GLOBAL_WAIT_SECONDS}s"
  echo
  echo "请选择功能:"
  echo "1. [极限速度] 一键创建${TOTAL_PROJECTS}个项目并获取API密钥"
  echo "2. 一键删除所有现有项目"
  echo "3. 修改配置参数"
  echo "0. 退出"
  echo "======================================================"
  read -p "请输入选项 [0-3]: " choice
  
  case $choice in
    1) create_projects_and_get_keys ;;
    2) delete_all_existing_projects ;;
    3) configure_settings ;;
    0) log "INFO" "正在退出..."; exit 0 ;;
    *) echo "无效选项 '$choice'，请重新选择。"; sleep 2 ;;
  esac
  
  if [[ "$choice" =~ ^[1-3]$ ]]; then
    echo
    read -p "按回车键返回主菜单..."
  fi
}

# ===== 主程序入口 =====
main() {
    log "INFO" "检查 GCP 登录状态..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" >/dev/null; then
        log "WARN" "无法获取活动账号信息，请尝试登录:"
        if ! gcloud auth login; then
            log "ERROR" "登录失败。"
            exit 1
        fi
    fi
    log "INFO" "GCP 账号检查通过。"

    log "INFO" "检查 GCP 项目配置..."
    if ! gcloud config get-value project >/dev/null; then
        log "WARN" "尚未设置默认GCP项目。建议使用 'gcloud config set project YOUR_PROJECT_ID' 设置。"
        sleep 3
    else
        log "INFO" "GCP 项目配置检查完成。"
    fi
    
    if ! command -v jq > /dev/null; then
        log "INFO" "未找到 'jq' 命令，将使用 sed/grep 解析JSON。建议安装 'jq' 以提高可靠性。"
    else
        log "INFO" "检测到 'jq'，将用于JSON解析。"
    fi


    while true; do
        show_menu
    done
}

# 执行主函数
main