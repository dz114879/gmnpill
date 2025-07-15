#!/bin/bash

# Fail fast on any error, undefined variable, or pipe failure
set -euo pipefail

# ===== Configuration =====
# --- Static ---
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_VERSION="4.0 (Refactored)"
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

# ===== Global State =====
# Check for jq availability
HAS_JQ=false
if command -v jq &>/dev/null; then
    HAS_JQ=true
fi
# ===== End Global State =====


# ===== Utility Functions =====
_log_internal() {
    local level="$1"
    local msg="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo >&2 "[$timestamp] [$level] $msg"
}

log_info() { _log_internal "INFO" "$1"; }
log_warn() { _log_internal "WARN" "$1"; }
log_error() { _log_internal "ERROR" "$1"; }
log_success() { _log_internal "SUCCESS" "$1"; }

# Check for required command-line tools
check_dependencies() {
    log_info "Checking dependencies..."
    local missing_deps=0
    for cmd in gcloud bc; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command '$cmd' is not installed. Please install it and try again."
            missing_deps=$((missing_deps + 1))
        fi
    done
    if [ "$missing_deps" -gt 0 ]; then exit 1; fi

    if [ "$HAS_JQ" = true ]; then
        log_info "Found 'jq'. JSON parsing will be fast."
    else
        log_warn "Command 'jq' not found. Using slower sed/grep for JSON parsing. Install 'jq' for better performance."
    fi
    log_info "Dependency check passed."
}

# Robust JSON parser, prefers jq, falls back to sed/grep
parse_json() {
    local json="$1"
    local field="$2"
    local value=""

    if [ -z "$json" ]; then return 1; fi

    if [ "$HAS_JQ" = true ]; then
        # jq is robust and safe
        value=$(echo "$json" | jq -r "$field" 2>/dev/null)
    else
        # Fallback for systems without jq
        case "$field" in
            ".keyString") value=$(echo "$json" | sed -n 's/.*"keyString": *"\([^"]*\)".*/\1/p');;
            *) local field_name; field_name=$(echo "$field" | tr -d '.["]'); value=$(echo "$json" | grep -oP "(?<=\"$field_name\":\s*\")[^\"]*");;
        esac
    fi

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
            log_error "Permission or authentication error, stopping retries."
            rm -f "$error_log"
            return 1
        fi

        if [ $attempt -lt $max_attempts ]; then
            sleep $timeout
            timeout=$((timeout * 2))
        fi
        attempt=$((attempt + 1))
    done

    log_error "Command failed after $max_attempts attempts. Last error: $(cat "$error_log")"
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
# These functions perform a single action and print their output for the parallel runner.
# On success, they print the item (e.g., project_id) and return 0.
# On failure, they print nothing and return 1.

task_create_project() {
    local project_id="$1"
    if gcloud projects create "$project_id" --name="$project_id" --no-set-as-default --quiet &>/dev/null; then
        echo "$project_id"
        return 0
    else
        log_error "Failed to create project: $project_id"
        return 1
    fi
}

task_enable_api() {
    local project_id="$1"
    if retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services enable generativelanguage.googleapis.com --project="$project_id" --quiet; then
        echo "$project_id"
        return 0
    else
        log_error "Failed to enable API for project: $project_id"
        return 1
    fi
}

task_create_key() {
    local project_id="$1"
    local create_output
    if ! create_output=$(retry_with_backoff "$MAX_RETRY_ATTEMPTS" gcloud services api-keys create --project="$project_id" --display-name="Gemini API Key for $project_id" --format="json" --quiet); then
        log_error "Key creation command failed for project: $project_id"
        return 1
    fi

    local api_key
    api_key=$(parse_json "$create_output" ".keyString")
    if [ -n "$api_key" ]; then
        log_success "Successfully extracted key for: $project_id"
        write_keys_to_files "$api_key"
        echo "$project_id" # Signal success
        return 0
    else
        log_error "Failed to parse API key for project: $project_id"
        return 1
    fi
}

task_delete_project() {
    local project_id="$1"
    if gcloud projects delete "$project_id" --quiet; then
        log_success "Successfully deleted project: $project_id"
        ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] DELETED: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
        echo "$project_id"
        return 0
    else
        local error_msg="Failed to delete project: $project_id"
        log_error "$error_msg"
        ( flock 201; echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILED_DELETE: $project_id" >> "$DELETION_LOG"; ) 201>"${TEMP_DIR}/${DELETION_LOG}.lock"
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
        log_info "No items to process for stage: '$description'."
        return 0
    fi

    log_info "Starting parallel stage: '$description' for $total_items items (Max parallel: $MAX_PARALLEL_JOBS)..."

    local i=0
    local completed_count=0
    local success_count=0
    
    # Export necessary functions and variables for subshells
    export -f "$task_func" log_info log_warn log_error log_success retry_with_backoff parse_json write_keys_to_files
    export -f _log_internal
    export TEMP_DIR MAX_RETRY_ATTEMPTS PURE_KEY_FILE COMMA_SEPARATED_KEY_FILE DELETION_LOG HAS_JQ

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
    log_info "Stage '$description' complete. Success: $success_count, Failed: $fail_count."
    log_info "======================================================"

    # Return success if all items succeeded
    [ "$fail_count" -eq 0 ]
}
# ===== End Parallel Execution Engine =====


# ===== Main Feature Functions =====
create_projects_and_get_keys() {
    local start_time=$SECONDS
    log_info "======================================================"
    log_info "Mode: Create $TOTAL_PROJECTS projects and get API keys"
    log_info "======================================================"
    log_info "Using random username: ${EMAIL_USERNAME}"
    log_info "Script will start in 3 seconds..."
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
    # The `run_parallel` function now handles its own output, so we capture it.
    mapfile -t created_project_ids < <(run_parallel task_create_project "Phase 1: Create Projects" "${projects_to_create[@]}")
    if [ ${#created_project_ids[@]} -eq 0 ]; then
        log_error "Project creation phase failed. No projects were created. Aborting."
        return 1
    fi

    # --- PHASE 2: Global Wait ---
    log_info "Phase 2: Global wait for ${GLOBAL_WAIT_SECONDS}s for GCP backend to sync..."
    for ((i=1; i<=${GLOBAL_WAIT_SECONDS}; i++)); do
        sleep 1
        show_progress "$i" "${GLOBAL_WAIT_SECONDS}"
        echo -n " Waiting..."
    done
    echo; log_info "Wait complete."
    log_info "======================================================"

    # --- PHASE 3: Enable APIs ---
    local enabled_project_ids=()
    mapfile -t enabled_project_ids < <(run_parallel task_enable_api "Phase 3: Enable APIs" "${created_project_ids[@]}")
    if [ ${#enabled_project_ids[@]} -eq 0 ]; then
        log_error "API enabling phase failed. No APIs were enabled. Aborting."
        return 1
    fi

    # --- PHASE 4: Create Keys ---
    local keys_created_for_projects=()
    mapfile -t keys_created_for_projects < <(run_parallel task_create_key "Phase 4: Create API Keys" "${enabled_project_ids[@]}")
    
    # --- FINAL REPORT ---
    local successful_keys=${#keys_created_for_projects[@]}
    local duration=$((SECONDS - start_time))
    local minutes=$((duration / 60))
    local seconds_rem=$((duration % 60))
    local success_rate=0
    if [ "$TOTAL_PROJECTS" -gt 0 ]; then
        success_rate=$(echo "scale=2; $successful_keys * 100 / $TOTAL_PROJECTS" | bc)
    fi

    echo
    log_info "========== Execution Report =========="
    log_info "Planned Target: $TOTAL_PROJECTS projects"
    log_info "Successfully Got Keys: $successful_keys"
    log_info "Failed: $((TOTAL_PROJECTS - successful_keys))"
    log_info "Success Rate: $success_rate%"
    if [ "$successful_keys" -gt 0 ]; then
        log_info "Average Time per Key: $((duration / successful_keys))s"
    fi
    log_info "Total Execution Time: $minutes min $seconds_rem sec"
    log_info "API keys saved to:"
    log_info "- Plain keys (one per line): $PURE_KEY_FILE"
    log_info "- Comma-separated keys: $COMMA_SEPARATED_KEY_FILE"
    log_warn "Reminder: Projects need a valid billing account to use the APIs."
    log_info "===================================="
}

delete_all_projects() {
    local start_time=$SECONDS
    log_info "======================================================"
    log_info "Mode: Delete All Existing Projects"
    log_info "======================================================"
    
    log_info "Fetching project list..."
    local project_list_str
    if ! project_list_str=$(gcloud projects list --format="value(projectId)" --filter="projectId!~^sys-" --quiet); then
        log_error "Failed to fetch project list from gcloud."
        return 1
    fi
    
    local all_projects=($project_list_str)

    if [ ${#all_projects[@]} -eq 0 ]; then
        log_info "No user projects found to delete."
        return 0
    fi

    local total_to_delete=${#all_projects[@]}
    log_warn "Found $total_to_delete projects to delete."
    
    local confirm
    read -p "!!! DANGER !!! This will delete ALL $total_to_delete projects. Type 'DELETE-ALL' to confirm: " confirm
    if [ "$confirm" != "DELETE-ALL" ]; then
        log_info "Deletion cancelled by user."
        return 1
    fi

    # Prepare deletion log
    echo "Project Deletion Log - $(date +%Y-%m-%d_%H:%M:%S)" > "$DELETION_LOG"
    echo "------------------------------------" >> "$DELETION_LOG"

    local deleted_projects=()
    mapfile -t deleted_projects < <(run_parallel task_delete_project "Deleting Projects" "${all_projects[@]}")

    # --- FINAL REPORT ---
    local successful_deletions=${#deleted_projects[@]}
    local failed_deletions=$((total_to_delete - successful_deletions))
    local duration=$((SECONDS - start_time))
    local minutes=$((duration / 60))
    local seconds_rem=$((duration % 60))

    echo
    log_info "========== Deletion Report =========="
    log_info "Attempted to Delete: $total_to_delete projects"
    log_info "Successfully Deleted: $successful_deletions"
    log_info "Failed to Delete: $failed_deletions"
    log_info "Total Execution Time: $minutes min $seconds_rem sec"
    log_info "Detailed log saved to: $DELETION_LOG"
    log_info "====================================="
}

configure_settings() {
    while true; do
        clear
        echo "======================================================"
        echo "               Configure Settings"
        echo "======================================================"
        echo "Current Settings:"
        echo "1. Project Prefix:         $PROJECT_PREFIX"
        echo "2. Max Parallel Jobs:      $MAX_PARALLEL_JOBS"
        echo "3. Max Retry Attempts:     $MAX_RETRY_ATTEMPTS"
        echo "4. Global Wait Time (s):   $GLOBAL_WAIT_SECONDS"
        echo ""
        echo "0. Return to Main Menu"
        echo "======================================================"
        
        local setting_choice
        read -p "Select setting to change [0-4]: " setting_choice

        case $setting_choice in
            1) 
                read -p "New project prefix (lowercase, digits, hyphens, start with letter, max 20 chars): " new_prefix
                if [[ -n "$new_prefix" && "$new_prefix" =~ ^[a-z][a-z0-9-]{0,19}$ ]]; then
                    PROJECT_PREFIX="$new_prefix"
                    log_success "Project prefix updated."
                elif [ -n "$new_prefix" ]; then
                    log_warn "Invalid format. Not updated."
                fi
                sleep 1
                ;;
            2) 
                read -p "New max parallel jobs (e.g., 10-100): " new_parallel
                if [[ "$new_parallel" =~ ^[1-9][0-9]*$ ]]; then
                    MAX_PARALLEL_JOBS=$new_parallel
                    log_success "Max parallel jobs updated."
                else
                    log_warn "Invalid number. Not updated."
                fi
                sleep 1
                ;;
            3) 
                read -p "New max retry attempts (e.g., 1-5): " new_retries
                if [[ "$new_retries" =~ ^[1-9][0-9]*$ ]]; then
                    MAX_RETRY_ATTEMPTS=$new_retries
                    log_success "Max retries updated."
                else
                    log_warn "Invalid number. Not updated."
                fi
                sleep 1
                ;;
            4) 
                read -p "New global wait time in seconds (e.g., 60-120): " new_wait
                if [[ "$new_wait" =~ ^[1-9][0-9]*$ ]]; then
                    GLOBAL_WAIT_SECONDS=$new_wait
                    log_success "Global wait time updated."
                else
                    log_warn "Invalid number. Not updated."
                fi
                sleep 1
                ;;
            0) return ;;
            *) 
                log_warn "Invalid option '$setting_choice'."
                sleep 2
                ;;
        esac
    done
}

show_menu() {
    clear
    echo "======================================================"
    echo "    GCP Gemini API Key Manager - v${SCRIPT_VERSION}"
    echo "======================================================"
    local current_account; current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -n 1)
    local current_project; current_project=$(gcloud config get-value project 2>/dev/null)
    echo "Account: ${current_account:-Not logged in}"
    echo "Project: ${current_project:-Not set}"
    echo "------------------------------------------------------"
    echo "Config: Create ${TOTAL_PROJECTS} projects | Parallel: ${MAX_PARALLEL_JOBS} | Wait: ${GLOBAL_WAIT_SECONDS}s"
    echo "======================================================"
    echo "Please select an option:"
    echo "1. [FAST] Create ${TOTAL_PROJECTS} projects & get keys"
    echo "2. [DANGER] Delete ALL existing projects"
    echo "3. Configure settings"
    echo "0. Exit"
    echo "======================================================"
    read -p "Enter your choice [0-3]: " choice
    
    case $choice in
        1) create_projects_and_get_keys ;;
        2) delete_all_projects ;;
        3) configure_settings ;;
        0) log_info "Exiting."; exit 0 ;;
        *) log_warn "Invalid option '$choice'."; sleep 2 ;;
    esac

    if [[ "$choice" =~ ^[1-3]$ ]]; then
        echo ""
        read -p "Press Enter to return to the main menu..."
    fi
}
# ===== End Main Feature Functions =====


# ===== Main Execution =====
main() {
    # Setup temporary directory and cleanup trap
    mkdir -p "$TEMP_DIR"
    trap 'log_info "Cleaning up temporary files..."; rm -rf "$TEMP_DIR"' EXIT SIGINT SIGTERM

    # Initial checks
    check_dependencies
    
    log_info "Checking GCP login status..."
    if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &>/dev/null; then
        log_warn "You are not logged into GCP. Attempting to log in..."
        if ! gcloud auth login; then
            log_error "GCP login failed. Please log in manually and restart."
            exit 1
        fi
    fi
    log_info "GCP login check passed."

    # Main loop
    while true; do
        show_menu
    done
}

# Run the main function
main
# ===== End Main Execution =====