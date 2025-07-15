#!/bin/bash

# Fail fast on any error, undefined variable, or pipe failure
set -euo pipefail

# ===== Configuration =====
# --- Static ---
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_VERSION="4.2 (jq enforced)"
readonly TIMESTAMP=$(date +%s)
readonly RANDOM_CHARS=$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 4)
readonly EMAIL_USERNAME="momo${RANDOM_CHARS}${TIMESTAMP:(-4)}"
readonly TEMP_DIR="/tmp/gcp_script_${TIMESTAMP}"
readonly DELETION_LOG="project_deletion_$(date +%Y%m%d_%H%M%S).log"
readonly PURE_KEY_FILE="key.txt"
readonly COMMA_SEPARATED_KEY_FILE="comma_separated_keys_${EMAIL_USERNAME}.txt"

# --- Dynamic (Configurable) ---
PROJECT_PREFIX="gemini-key"
TOTAL_PROJECTS=50
MAX_PARALLEL_JOBS=40
GLOBAL_WAIT_SECONDS=75
MAX_RETRY_ATTEMPTS=3
# ===== End Configuration =====


# ===== Utility Functions =====
_log_internal() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo >&2 "[$timestamp] [$level] $msg"
}

log_info() { _log_internal "信息" "$1"; }
log_warn() { _log_internal "警告" "$1"; }
log_error() { _log_internal "错误" "$1"; }
log_success() { _log_internal "成功" "$1"; }

# Attempt to install jq using common package managers
install_jq() {
    log_warn "必需的 'jq' 命令未找到，正在尝试自动安装..."
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "需要 root 权限来安装 'jq'。请使用 sudo 运行此脚本，或手动安装 'jq'。"
        return 1
    fi

    if command -v apt-get &>/dev/null; then
        log_info "检测到 Debian/Ubuntu 系统，使用 apt-get 安装..."
        apt-get update && apt-get install -y jq
    elif command -v yum &>/dev/null; then
        log_info "检测到 CentOS/RHEL 系统，使用 yum 安装..."
        yum install -y jq
    elif command -v brew &>/dev/null; then
        log_info "检测到 macOS 系统，使用 brew 安装..."
        brew install jq
    elif command -v pacman &>/dev/null; then
        log_info "检测到 Arch Linux 系统，使用 pacman 安装..."
        pacman -S --noconfirm jq
    else
        log_error "无法检测到已知的包管理器 (apt, yum, brew, pacman)。"
        log_error "请手动安装 'jq' 后再运行此脚本。"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "自动安装 'jq' 失败。请检查上面的错误信息并手动安装。"
        return 1
    fi
    log_success "'jq' 已成功安装。"
}


# Check for required command-line tools
check_dependencies() {
    log_info "正在检查依赖项..."
    local missing_deps=0
    for cmd in gcloud jq; do
        if ! command -v "$cmd" &>/dev/null; then
            if [ "$cmd" == "jq" ]; then
                install_jq || missing_deps=$((missing_deps + 1))
            else
                log_error "必需的命令 '$cmd' 未安装。请安装后再试。"
                missing_deps=$((missing_deps + 1))
            fi
        fi
    done
    if [ "$missing_deps" -gt 0 ]; then 
        log_error "依赖项检查失败，无法继续。"
        exit 1
    fi
    log_info "依赖项检查通过。"
}

# Robust JSON parser, now requires jq
parse_json() {
    local json="$1"
    local field="$2"
    local value=""

    if [ -z "$json" ]; then return 1; fi

    value=$(echo "$json" | jq -r "$field" 2>/dev/null)

    if [[ -n "$value" && "$value" != "null" ]]; then
        echo "$value"
        return 0
    else
        return 1
    fi
}

# File writing with flock to prevent race conditions
write_keys_to_files() {
    local api_key="$1"
    if [ -z "$api_key" ]; then return; fi
    (
        flock 200
        echo "$api_key" >> "$PURE_KEY_FILE"
        if [[ -s "$COMMA_SEPARATED_KEY_FILE" ]]; then
            echo -n "," >> "$COMMA_SEPARATED_KEY_FILE"
        fi
        echo -n "$api_key" >> "$COMMA_SEPARATED_KEY_FILE"
    ) 200>"${TEMP_DIR}/key_files.lock"
}

# Retry command with exponential backoff
retry_with_backoff() {
    local max_attempts=$1
    shift
    local cmd=("$@")
    local attempt=1
    local timeout=5
    local error_log="${TEMP_DIR}/error_$RANDOM.log"

    while [ $attempt -le $max_attempts ]; do
        if "${cmd[@]}" 2>"$error_log"; then
            rm -f "$error_log"
            return 0
        fi

        local error_msg
        error_msg=$(cat "$error_log")
        if [[ "$error_msg" == *"Permission denied"* || "$error_msg" == *"Authentication failed"* ]]; then
            log_error "权限或认证错误，停止重试。"
            rm -f "$error_log"
            return 1
        fi

        if [ $attempt -lt $max_attempts ]; then
            sleep $timeout
            timeout=$((timeout * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "命令在 $max_attempts 次尝试后失败。最后错误: $(cat "$error_log")"
    rm -f "$error_log"
    return 1
}

# Display a progress bar
show_progress() {
    local completed=$1
    local total=$2
    if [ "$total" -le 0 ]; then return; fi
    if [ "$completed" -gt "$total" ]; then completed=$total; fi

    local percent=$((completed * 100 / total))
    local completed_chars=$((percent * 40 / 100)) # 40-char bar
    local remaining_chars=$((40 - completed_chars))
    
    local progress_bar
    printf -v progress_bar "%${completed_chars}s" ""
    local remaining_bar
    printf -v remaining_bar "%${remaining_chars}s" ""

    # Use printf for the whole line to avoid flickering
    printf "\r[%s%s] %d%% (%d/%d)" "${progress_bar// /#}" "$remaining_bar" "$percent" "$completed" "$total"
}
# ===== End Utility Functions =====


# ===== Core Task Functions =====
task_create_project() {
    local project_id="$1"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet &>/dev/null; then
        echo "$project_id"
        return 0
    else
        log_error "创建项目失败: $project_id"
        return 1
    fi
}

task_enable_api() {
    local project_id="$1"
    if retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
        echo "$project_id"
        return 0
    else
        log_error "为项目启用API失败: $project_id"
        return 1
    fi
}

task_create_key() {
    local project_id="$1"
    local create_output
    if ! create_output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key for $project_id" --format="json" --quiet); then
        log_error "项目密钥创建命令失败: $project_id"
        return 1
    fi

    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    if [ -n "$api_key" ]; then
        log_success "成功提取密钥: $project_id"
        write_keys_to_files "$api_key"
        echo "$project_id" # Signal success
        return 0
    else
        log_error "解析项目API密钥失败: $project_id"
        return 1
    fi
}

task_delete_project() {
    local project_id="$1"
    if gcloud projects delete "$project_id" --quiet; then
        log_success "成功删除项目: $project_id"
        ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 已删除: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
        echo "$project_id"
        return 0
    else
        local error_msg="删除项目失败: $project_id"
        log_error "$error_msg"
        ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] 删除失败: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
        return 1
    fi
}
# ===== End Core Task Functions =====


# ===== Parallel Execution Engine =====
run_parallel() {
    local task_func="$1"
    local description="$2"
    shift 2
    local items=("$@")
    local total_items=${#items[@]}

    if [ "$total_items" -eq 0 ]; then
        log_info "阶段 '$description' 无项目需要处理。"
        return 0
    fi

    log_info "开始并行阶段: '$description' (共 $total_items 个项目, 最大并行数: $MAX_PARALLEL_JOBS)..."

    local i=0
    local completed_count=0
    local success_count=0
    
    # Export necessary functions and variables for subshells
    export -f "$task_func" log_info log_warn log_error log_success retry_with_backoff parse_json write_keys_to_files
    export -f _log_internal
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE DELETION_LOG

    # Create a temporary array to store PIDs of background jobs
    local pids=()

    for item in "${items[@]}"; do
        # Run the task in the background
        "$task_func" "$item" &
        pids+=($!)

        # If we've hit the job limit, wait for any job to finish
        if ((${#pids[@]} >= MAX_PARALLEL_JOBS)); then
            # Wait for the oldest job to complete
            wait "${pids[0]}"
            if [ $? -eq 0 ]; then
                success_count=$((success_count + 1))
            fi
            # Remove the completed PID from the array
            pids=("${pids[@]:1}")
            completed_count=$((completed_count + 1))
            show_progress "$completed_count" "$total_items"
        fi
    done

    # Wait for all remaining jobs to finish
    for pid in "${pids[@]}"; do
        wait "$pid"
        if [ $? -eq 0 ]; then
            success_count=$((success_count + 1))
        fi
        completed_count=$((completed_count + 1))
        show_progress "$completed_count" "$total_items"
    done

    echo # Newline after progress bar
    local fail_count=$((total_items - success_count))
    log_info "阶段 '$description' 完成。成功: $success_count, 失败: $fail_count."
    log_info "======================================================"

    # Return success if all items succeeded
    [ "$fail_count" -eq 0 ]
}
# ===== End Parallel Execution Engine =====


# ===== Main Feature Functions =====
create_projects_and_get_keys() {
    local start_time=$SECONDS
    log_info "======================================================"
    log_info "模式: 创建 $TOTAL_PROJECTS 个项目并获取API密钥"
    log_info "======================================================"
    log_info "将使用随机用户名: ${EMAIL_USERNAME}"
    log_info "脚本将在 3 秒后开始..."
    sleep 3

    # Clean/prepare key files
    >"$PURE_KEY_FILE"
    >"$COMMA_SEPARATED_KEY_FILE"

    # --- Generate Project IDs ---
    local projects_to_create=()
    for i in $(seq 1 "$TOTAL_PROJECTS"); do
        local project_num; project_num=$(printf "%03d" "$i")
        local base_id="${PROJECT_PREFIX}-${EMAIL_USERNAME}-${project_num}"
        # Ensure project ID is valid (starts with letter, 6-30 chars, lowercase, digits, hyphens)
        local project_id; project_id=$(echo "$base_id" | tr -cd 'a-z0-9-' | cut -c 1-30 | sed 's/-$//')
        if ! [[ "$project_id" =~ ^[a-z] ]]; then
            project_id="g${project_id:1}"
            project_id=$(echo "$project_id" | cut -c 1-30 | sed 's/-$//')
        fi
        projects_to_create+=("$project_id")
    done

    # --- PHASE 1: Create Projects ---
    local created_project_ids=()
    mapfile -t created_project_ids < <(run_parallel task_create_project "阶段1: 创建项目" "${projects_to_create[@]}")
    if [ ${#created_project_ids[@]} -eq 0 ]; then
        log_error "项目创建阶段失败，没有任何项目被创建。正在中止。"
        return 1
    fi

    # --- PHASE 2: Global Wait ---
    log_info "阶段2: 全局等待 ${GLOBAL_WAIT_SECONDS} 秒，以便GCP后端同步..."
    for ((i=1; i<=${GLOBAL_WAIT_SECONDS}; i++)); do
        sleep 1
        show_progress "$i" "${GLOBAL_WAIT_SECONDS}"
        echo -n " 等待中..."
    done
    echo; log_info "等待完成。"
    log_info "======================================================"

    # --- PHASE 3: Enable APIs ---
    local enabled_project_ids=()
    mapfile -t enabled_project_ids < <(run_parallel task_enable_api "阶段3: 启用API" "${created_project_ids[@]}")
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then
        log_error "API启用阶段失败，没有任何API被启用。正在中止。"
        return 1
    fi

    # --- PHASE 4: Create Keys ---
    local keys_created_for_projects=()
    mapfile -t keys_created_for_projects < <(run_parallel task_create_key "阶段4: 创建API密钥" "${enabled_project_ids[@]}")
    
    # --- FINAL REPORT ---
    local successful_keys=${#keys_created_for_projects[@]}
    local duration=$((SECONDS - start_time))
    local minutes=$((duration / 60))
    local seconds_rem=$((duration % 60))

    echo
    log_info "========== 执行报告 =========="
    log_info "计划目标: $TOTAL_PROJECTS 个项目"
    log_info "成功获取密钥: $successful_keys 个"
    log_info "失败: $((TOTAL_PROJECTS - successful_keys)) 个"
    if [ "$successful_keys" -gt 0 ]; then
        log_info "平均每个密钥耗时: $((duration / successful_keys)) 秒"
    fi
    log_info "总执行时间: $minutes 分 $seconds_rem 秒"
    log_info "API密钥已保存至:"
    log_info "- 纯密钥 (每行一个): $PURE_KEY_FILE"
    log_info "- 逗号分隔密钥: $COMMA_SEPARATED_KEY_FILE"
    log_warn "提醒: 项目需要关联有效的结算账号才能使用API。"
    log_info "===================================="
}

delete_all_projects() {
    local start_time=$SECONDS
    log_info "======================================================"
    log_info "模式: 删除所有现有项目"
    log_info "======================================================"
    
    log_info "正在获取项目列表..."
    local project_list_str
    if ! project_list_str=$(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet); then
        log_error "从gcloud获取项目列表失败。"
        return 1
    fi
    
    local all_projects=($project_list_str)

    if [ ${#all_projects[@]} -eq 0 ]; then
        log_info "未找到可删除的用户项目。"
        return 0
    fi

    local total_to_delete=${#all_projects[@]}
    log_warn "找到 $total_to_delete 个项目待删除。"
    
    local confirm
    read -p "!!! 危险操作 !!! 这将删除所有 $total_to_delete 个项目。输入 'DELETE-ALL' 确认: " confirm
    if [ "$confirm" != "DELETE-ALL" ]; then
        log_info "用户已取消删除操作。"
        return 1
    fi

    # Prepare deletion log
    echo "项目删除日志 - $(date +%Y-%m-%d_%H:%M:%S)" > "$DELETION_LOG"
    echo "------------------------------------" >> "$DELETION_LOG"

    local deleted_projects=()
    mapfile -t deleted_projects < <(run_parallel task_delete_project "正在删除项目" "${all_projects[@]}")

    # --- FINAL REPORT ---
    local successful_deletions=${#deleted_projects[@]}
    local failed_deletions=$((total_to_delete - successful_deletions))
    local duration=$((SECONDS - start_time))
    local minutes=$((duration / 60))
    local seconds_rem=$((duration % 60))

    echo
    log_info "========== 删除报告 =========="
    log_info "尝试删除: $total_to_delete 个项目"
    log_info "成功删除: $successful_deletions 个"
    log_info "删除失败: $failed_deletions 个"
    log_info "总执行时间: $minutes 分 $seconds_rem 秒"
    log_info "详细日志已保存至: $DELETION_LOG"
    log_info "====================================="
}

configure_settings() {
    while true; do
        clear
        echo "======================================================"
        echo "                     配置参数"
        echo "======================================================"
        echo "当前设置:"
        echo "1. 项目前缀:             $PROJECT_PREFIX"
        echo "2. 最大并行任务数:         $MAX_PARALLEL_JOBS"
        echo "3. 最大重试次数:         $MAX_RETRY_ATTEMPTS"
        echo "4. 全局等待时间 (秒):    $GLOBAL_WAIT_SECONDS"
        echo ""
        echo "0. 返回主菜单"
        echo "======================================================"
        
        local setting_choice
        read -p "请选择要修改的参数 [0-4]: " setting_choice

        case $setting_choice in
            1) 
                read -p "新项目前缀 (小写字母,数字,连字符,字母开头,最多20字符): " new_prefix
                if [[ -n "$new_prefix" && "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
                    PROJECT_PREFIX="$new_prefix"
                    log_success "项目前缀已更新。"
                elif [ -n "$new_prefix" ]; then
                    log_warn "格式无效，未更新。"
                fi
                sleep 1
                ;;
            2) 
                read -p "新的最大并行任务数 (例如 10-100): " new_parallel
                if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]]; then
                    MAX_PARALLEL_JOBS=$new_parallel
                    log_success "最大并行任务数已更新。"
                else
                    log_warn "无效数字，未更新。"
                fi
                sleep 1
                ;;
            3) 
                read -p "新的最大重试次数 (例如 1-5): " new_retries
                if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]]; then
                    MAX_RETRY_ATTEMPTS=$new_retries
                    log_success "最大重试次数已更新。"
                else
                    log_warn "无效数字，未更新。"
                fi
                sleep 1
                ;;
            4) 
                read -p "新的全局等待时间 (秒, 例如 60-120): " new_wait
                if [[ "$new_wait" =~ ^[1-9][0-9]*$ ]]; then
                    GLOBAL_WAIT_SECONDS=$new_wait
                    log_success "全局等待时间已更新。"
                else
                    log_warn "无效数字，未更新。"
                fi
                sleep 1
                ;;
            0) return ;;
            *) 
                log_warn "无效选项 '$setting_choice'。"
                sleep 2
                ;;
        esac
    done
}

show_menu() {
    clear
    echo "======================================================"
    echo "    GCP Gemini API 密钥管理器 - v${SCRIPT_VERSION}"
    echo "======================================================"
    local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1)
    local current_project; current_project=$(gcloud config get-value project 2>/dev/null)
    echo "当前账号: ${current_account:-未登录}"
    echo "当前项目: ${current_project:-未设置}"
    echo "------------------------------------------------------"
    echo "配置: 创建 ${TOTAL_PROJECTS} 个项目 | 并行: ${MAX_PARALLEL_JOBS} | 等待: ${GLOBAL_WAIT_SECONDS}s"
    echo "======================================================"
    echo "请选择一个操作:"
    echo "1. [高速] 创建 ${TOTAL_PROJECTS} 个项目并获取密钥"
    echo "2. [危险] 删除所有现有项目"
    echo "3. 配置参数"
    echo "0. 退出"
    echo "======================================================"
    read -p "请输入您的选择 [0-3]: " choice
    
    case $choice in
        1) create_projects_and_get_keys ;;
        2) delete_all_projects ;;
        3) configure_settings ;;
        0) log_info "正在退出..."; exit 0 ;;
        *) log_warn "无效选项 '$choice'。"; sleep 2 ;;
    esac

    if [[ "$choice" =~ ^[1-3]$ ]]; then
        echo ""
        read -p "按回车键返回主菜单..."
    fi
}
# ===== End Main Feature Functions =====


# ===== Main Execution =====
main() {
    # Setup temporary directory and cleanup trap
    mkdir -p "$TEMP_DIR"
    trap 'log_info "正在清理临时文件..."; rm -rf "$TEMP_DIR"' EXIT SIGINT SIGTERM

    # Initial checks
    check_dependencies
    
    log_info "正在检查 GCP 登录状态..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &>/dev/null; then
        log_warn "您尚未登录GCP。正在尝试登录..."
        if ! gcloud auth login; then
            log_error "GCP登录失败。请手动登录后重试。"
            exit 1
        fi
    fi
    log_info "GCP 登录状态检查通过。"

    # Main loop
    while true; do
        show_menu
    done
}

# Run the main function
main
# ===== End Main Execution =====