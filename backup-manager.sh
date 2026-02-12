#!/bin/bash

# Unified Backup Manager
# Handles both backup creation and cleanup with retention policies

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================

# Determine script directory and config file path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/backup-manager.conf"

# Load configuration file
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Configuration file not found: $CONFIG_FILE" >&2
  echo "Please create the configuration file or ensure it exists in the script directory." >&2
  exit 1
fi

# Source the configuration file
if ! source "$CONFIG_FILE"; then
  echo "Error: Failed to load configuration file: $CONFIG_FILE" >&2
  exit 1
fi

# Validate required configuration variables
if [[ -z "$BACKUP_TYPE" ]] || [[ -z "$BACKUP_DIR" ]] || [[ -z "$REMOTE_BACKUP_DIR" ]]; then
  echo "Error: Required configuration variables are missing in $CONFIG_FILE" >&2
  echo "Required: BACKUP_TYPE, BACKUP_DIR, REMOTE_BACKUP_DIR" >&2
  exit 1
fi

# Validate arrays are set
if [[ ! -v DOCKER_SERVICES[@] ]]; then
  echo "Warning: DOCKER_SERVICES array is not set in $CONFIG_FILE" >&2
  DOCKER_SERVICES=()
fi

if [[ ! -v SYSTEM_DIRECTORIES[@] ]]; then
  echo "Warning: SYSTEM_DIRECTORIES array is not set in $CONFIG_FILE" >&2
  SYSTEM_DIRECTORIES=()
fi

# Validate rclone remote if using rclone backup
if [[ $BACKUP_TYPE -eq 2 ]]; then
  # Extract remote name from REMOTE_BACKUP_DIR (format: "remote-name:path")
  REMOTE_NAME="${REMOTE_BACKUP_DIR%%:*}"
  
  if [[ -z "$REMOTE_NAME" ]]; then
    echo "Error: Invalid REMOTE_BACKUP_DIR format: $REMOTE_BACKUP_DIR" >&2
    echo "Expected format: 'remote-name:path' (e.g., 'b2:/backups')" >&2
    exit 1
  fi
  
  # Check if remote exists in rclone config
  if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
    echo "Error: Rclone remote '$REMOTE_NAME' not found in rclone configuration" >&2
    echo "" >&2
    echo "Available remotes:" >&2
    rclone listremotes 2>/dev/null | sed 's/^/  /' >&2
    echo "" >&2
    echo "Please either:" >&2
    echo "  1. Update REMOTE_BACKUP_DIR in $CONFIG_FILE to use an existing remote" >&2
    echo "  2. Create the remote '$REMOTE_NAME' using: rclone config" >&2
    exit 1
  fi
fi

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Global variables
UPLOAD_FAILURES=0
DRY_RUN=true
NON_INTERACTIVE=false
SERVICE_FILTER=""

# Backup statistics
BACKUP_STATS_SERVICES=0
BACKUP_STATS_FAILED=0
BACKUP_STATS_SUCCESS=0
BACKUP_STATS_SERVICES_LIST=()

# Cleanup statistics
CLEANUP_STATS_TOTAL=0
CLEANUP_STATS_KEPT=0
CLEANUP_STATS_DELETED=0
CLEANUP_STATS_SPACE_FREED_MB=0

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

# Trim leading and trailing whitespace (for service names and filter matching)
trim_whitespace() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

# Function to escape JSON strings
escape_json() {
  echo "$1" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g'
}

# Function to send message to Discord webhook
send_discord_notification() {
  local title="$1"
  local description="$2"
  local color="$3"  # decimal color code (e.g., 3066993 for green, 15158332 for red)
  local fields="$4"  # JSON array of field objects
  
  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    return 0  # Webhook not configured, silently skip
  fi
  
  # Escape title and description for JSON
  local title_escaped=$(escape_json "$title")
  local desc_escaped=$(escape_json "$description")
  
  # Build embed JSON
  local embed_json=$(cat <<EOF
{
  "embeds": [{
    "title": "$title_escaped",
    "description": "$desc_escaped",
    "color": $color,
    "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "fields": $fields
  }]
}
EOF
)
  
  # Send to Discord
  local response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "$embed_json" \
    "$DISCORD_WEBHOOK_URL" 2>/dev/null)
  
  local http_code=$(echo "$response" | tail -n1)
  
  if [[ "$http_code" != "200" ]] && [[ "$http_code" != "204" ]]; then
    echo -e "${YELLOW}Warning: Failed to send Discord notification (HTTP $http_code)${NC}" >&2
    return 1
  fi
  
  return 0
}

# Function to format backup summary for Discord
send_backup_summary() {
  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    return 0
  fi
  
  local status="✅ Success"
  local color=3066993  # Green
  local description="Backup operations completed"
  
  if [[ $BACKUP_STATS_FAILED -gt 0 ]]; then
    status="⚠️ Partial Failure"
    color=16776960  # Yellow
    description="Some backups completed with errors"
  fi
  
  if [[ $BACKUP_STATS_SERVICES -eq 0 ]]; then
    status="ℹ️ Skipped"
    color=3447003  # Blue
    description="No services matched the filter"
  fi
  
  # Build fields array
  local fields="["
  fields+="{\"name\":\"Services Backed Up\",\"value\":\"$BACKUP_STATS_SERVICES\",\"inline\":true},"
  fields+="{\"name\":\"Successful\",\"value\":\"$BACKUP_STATS_SUCCESS\",\"inline\":true},"
  fields+="{\"name\":\"Failed\",\"value\":\"$BACKUP_STATS_FAILED\",\"inline\":true}"
  
  if [[ ${#BACKUP_STATS_SERVICES_LIST[@]} -gt 0 ]]; then
    local services_list=$(IFS=', '; echo "${BACKUP_STATS_SERVICES_LIST[*]}")
    local services_escaped=$(escape_json "$services_list")
    fields+=",{\"name\":\"Services\",\"value\":\"\`$services_escaped\`\",\"inline\":false}"
  fi
  
  if [[ -n "$SERVICE_FILTER" ]]; then
    local filter_escaped=$(escape_json "$SERVICE_FILTER")
    fields+=",{\"name\":\"Filter\",\"value\":\"\`$filter_escaped\`\",\"inline\":false}"
  fi
  
  fields+="]"
  
  send_discord_notification "$status - Backup Complete" "$description" "$color" "$fields"
}

# Function to format cleanup summary for Discord
send_cleanup_summary() {
  if [[ -z "$DISCORD_WEBHOOK_URL" ]]; then
    return 0
  fi
  
  local status="🧹 Cleanup Complete"
  local color=3066993  # Green
  local description="Backup cleanup operations completed"
  local mode="Dry Run"
  
  if [[ "$DRY_RUN" == false ]]; then
    mode="Executed"
    if [[ $CLEANUP_STATS_DELETED -gt 0 ]]; then
      description="Deleted $CLEANUP_STATS_DELETED backup(s)"
    fi
  else
    description="Preview of cleanup operations (no files deleted)"
  fi
  
  # Build fields array
  local fields="["
  fields+="{\"name\":\"Mode\",\"value\":\"$mode\",\"inline\":true},"
  fields+="{\"name\":\"Total Backups\",\"value\":\"$CLEANUP_STATS_TOTAL\",\"inline\":true},"
  fields+="{\"name\":\"Kept\",\"value\":\"$CLEANUP_STATS_KEPT\",\"inline\":true},"
  fields+="{\"name\":\"Deleted\",\"value\":\"$CLEANUP_STATS_DELETED\",\"inline\":true}"
  
  if [[ $CLEANUP_STATS_SPACE_FREED_MB -gt 0 ]]; then
    fields+=",{\"name\":\"Space Freed\",\"value\":\"${CLEANUP_STATS_SPACE_FREED_MB} MB\",\"inline\":true}"
  fi
  
  fields+=",{\"name\":\"Retention Policy\",\"value\":\"Daily: ${KEEP_DAILY}d, Weekly: ${KEEP_WEEKLY}d, Monthly: ${KEEP_MONTHLY}d\",\"inline\":false}"
  fields+="]"
  
  send_discord_notification "$status" "$description" "$color" "$fields"
}

show_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --backup, -b          Run backup operations only (default if no options)"
  echo "  --cleanup, -c         Run cleanup operations only"
  echo "  --all, -a             Run both backup and cleanup"
  echo "  --execute, -e         Execute cleanup deletions (required for cleanup)"
  echo "  --non-interactive, -y Run in non-interactive mode (for cron/automation)"
  echo "  --service, -s NAME    Backup only specific service(s) (comma-separated)"
  echo "  --help, -h            Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0                                    # Backup all services (default)"
  echo "  $0 --backup                           # Create backups for all services"
  echo "  $0 --backup --service wz-vaultwarden  # Backup only vaultwarden"
  echo "  $0 --backup --service wz-vaultwarden,wz-authentik  # Backup multiple services"
  echo "  $0 --cleanup                          # Show what would be cleaned (dry run)"
  echo "  $0 --cleanup --execute                # Actually delete old backups"
  echo "  $0 --cleanup --execute --non-interactive  # Non-interactive cleanup"
  echo "  $0 --all                              # Backup then cleanup (dry run)"
  echo ""
  echo "Cron Examples:"
  echo "  # Backup vaultwarden daily at 2 AM"
  echo "  0 2 * * * /path/to/backup-manager.sh --backup --service wz-vaultwarden --non-interactive"
  echo ""
  echo "  # Backup all services daily at 3 AM"
  echo "  0 3 * * * /path/to/backup-manager.sh --backup --non-interactive"
  echo ""
  echo "  # Cleanup weekly on Sunday at 4 AM"
  echo "  0 4 * * 0 /path/to/backup-manager.sh --cleanup --execute --non-interactive"
}

# ============================================================================
# BACKUP FUNCTIONS
# ============================================================================

# Function to backup a system directory (non-Docker)
backup_system_directory() {
  local BACKUP_NAME="$1"
  local DIR_PATH="$2"

  # Verify the directory exists
  if [[ ! -d "$DIR_PATH" ]]; then
    echo -e "${RED}Directory $DIR_PATH does not exist. Skipping backup.${NC}"
    return 1
  fi

  # Create the backup zip with timestamp for versioning
  timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
  zip_file="${BACKUP_NAME}_backup_${timestamp}.zip"
  echo "Creating backup for $BACKUP_NAME: $zip_file"
  
  # Create zip from the directory
  zip -r "$zip_file" "$DIR_PATH" || { 
    echo -e "${RED}Failed to zip directory $DIR_PATH for $BACKUP_NAME. Exiting.${NC}"
    return 1
  }

  if [[ $BACKUP_TYPE -eq 1 ]]; then
    # Local-only backup
    echo "Moving $zip_file to local backup directory: $BACKUP_DIR"
    mv "$zip_file" "$BACKUP_DIR/" || {
      echo -e "${RED}Failed to move $zip_file to $BACKUP_DIR. Exiting.${NC}"
      return 1
    }
  elif [[ $BACKUP_TYPE -eq 2 ]]; then
    # Rclone backup
    echo "Uploading $zip_file to $REMOTE_BACKUP_DIR/$BACKUP_NAME/"
    rclone copy -vv "$zip_file" "$REMOTE_BACKUP_DIR/$BACKUP_NAME/"

    # Check if the upload was successful
    if [[ $? -ne 0 ]]; then
      echo -e "${RED}Upload failed for $BACKUP_NAME. Moving backup to local storage.${NC}"
      mv "$zip_file" "$BACKUP_DIR/"
      UPLOAD_FAILURES=1
    else
      echo "Upload successful, removing $zip_file"
      rm "$zip_file"
    fi
  else
    echo -e "${RED}Invalid BACKUP_TYPE specified. Exiting.${NC}"
    return 1
  fi
}

# Function to process a single Docker service
backup_docker_service() {
  local SERVICE_ENTRY="$1"

  # Check if entry contains exclusions (separated by |)
  if [[ "$SERVICE_ENTRY" == *"|"* ]]; then
    IFS='|' read -r SERVICE_PART EXCLUSIONS_PART <<< "$SERVICE_ENTRY"
    # Parse exclusions (colon-separated)
    EXCLUDE_PATTERNS=(${EXCLUSIONS_PART//:/ })
  else
    SERVICE_PART="$SERVICE_ENTRY"
    EXCLUDE_PATTERNS=()
  fi

  # Split the entry into service name and directories
  IFS=':' read -r SERVICE_NAME MAIN_DIR ADDITIONAL_DIRS <<< "$SERVICE_PART"
  DIRECTORIES=($MAIN_DIR ${ADDITIONAL_DIRS//:/ })

  echo "Stopping containers in $SERVICE_NAME"

  cd "$MAIN_DIR" || { 
    echo -e "${RED}Failed to navigate to $MAIN_DIR. Exiting.${NC}"
    exit 1
  }

  # Stop all services in the directory
  docker compose stop
  if [[ $? -ne 0 ]]; then
    echo -e "${RED}Failed to stop containers in $SERVICE_NAME. Exiting.${NC}"
    exit 1
  fi

  # Create the backup zip
  timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
  zip_file="${SERVICE_NAME}_backup_${timestamp}.zip"
  echo "Creating backup for $SERVICE_NAME: $zip_file"
  
  # Build zip command with exclusions
  ZIP_ARGS=(-r "$zip_file")
  for DIR in "${DIRECTORIES[@]}"; do
    ZIP_ARGS+=("$DIR")
  done
  
  # Add exclusion patterns (zip -x expects patterns relative to the directories being zipped)
  for EXCLUDE in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ -n "$EXCLUDE" ]]; then
      ZIP_ARGS+=(-x "$EXCLUDE")
      echo "  Excluding pattern: $EXCLUDE"
    fi
  done
  
  # Execute zip command
  zip "${ZIP_ARGS[@]}" || { 
    echo -e "${RED}Failed to zip directories for $SERVICE_NAME. Exiting.${NC}"
    exit 1
  }

  if [[ $BACKUP_TYPE -eq 1 ]]; then
    # Local-only backup
    echo "Moving $zip_file to local backup directory: $BACKUP_DIR"
    mv "$zip_file" "$BACKUP_DIR/" || {
      echo -e "${RED}Failed to move $zip_file to $BACKUP_DIR. Exiting.${NC}"
      exit 1
    }
  elif [[ $BACKUP_TYPE -eq 2 ]]; then
    # Rclone backup
    echo "Uploading $zip_file to $REMOTE_BACKUP_DIR/$SERVICE_NAME/"
    rclone copy -vv "$zip_file" "$REMOTE_BACKUP_DIR/$SERVICE_NAME/"

    # Check if the upload was successful
    if [[ $? -ne 0 ]]; then
      echo -e "${RED}Upload failed for $SERVICE_NAME. Moving backup to local storage.${NC}"
      mv "$zip_file" "$BACKUP_DIR/"
      UPLOAD_FAILURES=1
    else
      echo "Upload successful, removing $zip_file"
      rm "$zip_file"
    fi
  else
    echo -e "${RED}Invalid BACKUP_TYPE specified. Exiting.${NC}"
    exit 1
  fi

  # Restart the container for the service
  echo "Restarting containers in $SERVICE_NAME"
  cd "$MAIN_DIR" || { 
    echo -e "${RED}Failed to navigate to $MAIN_DIR. Exiting.${NC}"
    exit 1
  }
  docker compose start
}

# Function to check if service should be backed up
should_backup_service() {
  local service_name
  service_name=$(trim_whitespace "$1")
  
  # If no filter specified, backup all services
  if [[ -z "$SERVICE_FILTER" ]]; then
    return 0
  fi
  
  # Check if service name matches any in the filter (comma-separated)
  IFS=',' read -ra FILTER_ARRAY <<< "$SERVICE_FILTER"
  for filter_item in "${FILTER_ARRAY[@]}"; do
    filter_item=$(trim_whitespace "$filter_item")
    if [[ -n "$filter_item" ]] && [[ "$service_name" == "$filter_item" ]]; then
      return 0
    fi
  done
  
  return 1
}

# Function to run all backups
run_backups() {
  echo -e "${BLUE}=== Starting Backup Operations ===${NC}"
  
  if [[ -n "$SERVICE_FILTER" ]]; then
    echo "Service filter active: $SERVICE_FILTER"
  fi
  
  # Ensure the local backup directory exists
  if [[ ! -d "$BACKUP_DIR" ]]; then
    echo "Creating local backup directory: $BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
  fi

  # Process Docker services with thread control
  PIDS=()
  CURRENT_THREADS=0
  SERVICES_BACKED_UP=0
  BACKUP_STATS_SERVICES=0
  BACKUP_STATS_FAILED=0
  BACKUP_STATS_SUCCESS=0
  BACKUP_STATS_SERVICES_LIST=()
  
  for SERVICE_ENTRY in "${DOCKER_SERVICES[@]}"; do
    # Extract service name (first field only; read assigns remainder to last variable)
    IFS=':' read -r SERVICE_NAME _ <<< "${SERVICE_ENTRY%%|*}"
    SERVICE_NAME=$(trim_whitespace "$SERVICE_NAME")
    [[ -z "$SERVICE_NAME" ]] && continue

    # Check if this service should be backed up
    if ! should_backup_service "$SERVICE_NAME"; then
      echo "Skipping $SERVICE_NAME (not in filter)"
      continue
    fi
    
    BACKUP_STATS_SERVICES_LIST+=("$SERVICE_NAME")
    backup_docker_service "$SERVICE_ENTRY" &
    PIDS+=("$!")
    CURRENT_THREADS=$((CURRENT_THREADS + 1))
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))

    # Wait for threads to finish if limit is reached
    if [[ $CURRENT_THREADS -ge $MAX_THREADS ]]; then
      for PID in "${PIDS[@]}"; do
        wait "$PID"
      done
      PIDS=()
      CURRENT_THREADS=0
    fi
  done

  # Wait for any remaining background processes to complete and track results
  for PID in "${PIDS[@]}"; do
    if wait "$PID"; then
      BACKUP_STATS_SUCCESS=$((BACKUP_STATS_SUCCESS + 1))
    else
      BACKUP_STATS_FAILED=$((BACKUP_STATS_FAILED + 1))
    fi
  done
  
  BACKUP_STATS_SERVICES=$SERVICES_BACKED_UP

  # Backup system directories (non-Docker)
  echo ""
  echo "Starting system directory backups..."
  SYSTEM_BACKED_UP=0
  for SYSTEM_ENTRY in "${SYSTEM_DIRECTORIES[@]}"; do
    IFS=':' read -r BACKUP_NAME DIR_PATH <<< "$SYSTEM_ENTRY"
    BACKUP_NAME=$(trim_whitespace "$BACKUP_NAME")
    [[ -z "$BACKUP_NAME" ]] && continue

    # Check if this system directory should be backed up
    if [[ -n "$SERVICE_FILTER" ]] && ! should_backup_service "$BACKUP_NAME"; then
      echo "Skipping $BACKUP_NAME (not in filter)"
      continue
    fi
    
    if backup_system_directory "$BACKUP_NAME" "$DIR_PATH"; then
      BACKUP_STATS_SUCCESS=$((BACKUP_STATS_SUCCESS + 1))
      BACKUP_STATS_SERVICES_LIST+=("$BACKUP_NAME")
    else
      BACKUP_STATS_FAILED=$((BACKUP_STATS_FAILED + 1))
    fi
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
    SYSTEM_BACKED_UP=$((SYSTEM_BACKED_UP + 1))
  done
  
  BACKUP_STATS_SERVICES=$SERVICES_BACKED_UP
  
  if [[ $SYSTEM_BACKED_UP -eq 0 ]] && [[ -n "$SERVICE_FILTER" ]]; then
    echo "No system directories matched the filter."
  fi

  if [[ $SERVICES_BACKED_UP -eq 0 ]]; then
    echo -e "${YELLOW}No services matched the filter. Nothing to backup.${NC}"
    return
  fi

  # Check for upload failures and print a red alert if any occurred
  if [[ $UPLOAD_FAILURES -ne 0 ]]; then
    echo -e "${RED}ALERT: One or more backups failed to upload. Check $BACKUP_DIR for local copies.${NC}"
    BACKUP_STATS_FAILED=$((BACKUP_STATS_FAILED + UPLOAD_FAILURES))
  else
    echo "All backups uploaded successfully."
  fi

  echo "Backup process complete."
  
  # Send Discord notification
  send_backup_summary
}

# ============================================================================
# CLEANUP FUNCTIONS
# ============================================================================

# Function to parse timestamp from backup filename
parse_timestamp() {
  local filename="$1"
  if [[ "$filename" =~ _backup_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2})\.zip ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Function to convert timestamp to epoch seconds
timestamp_to_epoch() {
  local timestamp="$1"
  local date_part="${timestamp%%_*}"
  local time_part="${timestamp#*_}"
  local formatted_time="${time_part//-/:}"
  local epoch=$(date -d "${date_part} ${formatted_time}" +%s 2>/dev/null)
  if [[ -z "$epoch" ]] || [[ "$epoch" == "0" ]]; then
    echo "0"
  else
    echo "$epoch"
  fi
}

# Function to get age of backup in days
get_age_days() {
  local backup_timestamp="$1"
  local backup_epoch=$(timestamp_to_epoch "$backup_timestamp")
  local current_epoch=$(date +%s)
  local age_seconds=$((current_epoch - backup_epoch))
  echo $((age_seconds / 86400))
}

# Function to check if backup should be kept (daily retention)
should_keep_daily() {
  local age_days="$1"
  [[ $age_days -le $KEEP_DAILY ]]
}

# Function to get week identifier (YYYY-WW)
get_week_id() {
  local timestamp="$1"
  local epoch=$(timestamp_to_epoch "$timestamp")
  date -d "@$epoch" +"%Y-W%V" 2>/dev/null || echo ""
}

# Function to get month identifier (YYYY-MM)
get_month_id() {
  local timestamp="$1"
  local epoch=$(timestamp_to_epoch "$timestamp")
  date -d "@$epoch" +"%Y-%m" 2>/dev/null || echo ""
}

# Function to process backups for cleanup
cleanup_service_backups() {
  local service_name="$1"
  local service_path="${REMOTE_BACKUP_DIR}/${service_name}/"
  
  echo -e "\n${BLUE}=== Processing: $service_name ===${NC}"
  
  # List all backups with sizes (format: size filename)
  local backups_raw=$(rclone ls "$service_path" 2>/dev/null | grep "_backup_.*\.zip$")
  
  if [[ -z "$backups_raw" ]]; then
    echo "  No backups found for $service_name"
    return
  fi
  
  # Parse backups into arrays
  declare -A backup_files
  declare -A backup_sizes
  declare -A backup_epochs
  declare -a backup_timestamps
  
  while IFS= read -r line; do
    local size=$(echo "$line" | awk '{print $1}')
    local filename=$(echo "$line" | awk '{for(i=2;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/[[:space:]]*$//')
    local timestamp=$(parse_timestamp "$filename")
    
    if [[ -n "$timestamp" ]]; then
      backup_files["$timestamp"]="$filename"
      backup_sizes["$timestamp"]="$size"
      backup_epochs["$timestamp"]=$(timestamp_to_epoch "$timestamp")
      backup_timestamps+=("$timestamp")
    fi
  done <<< "$backups_raw"
  
  if [[ ${#backup_timestamps[@]} -eq 0 ]]; then
    echo "  No valid backups found for $service_name"
    return
  fi
  
  # Validate timestamps
  local invalid_count=0
  for ts in "${backup_timestamps[@]}"; do
    if [[ "${backup_epochs[$ts]}" == "0" ]]; then
      echo -e "  ${RED}WARNING: Failed to parse timestamp for ${backup_files[$ts]}${NC}"
      invalid_count=$((invalid_count + 1))
    fi
  done
  
  if [[ $invalid_count -gt 0 ]]; then
    echo -e "  ${RED}ERROR: $invalid_count backup(s) have invalid timestamps and will be skipped${NC}"
  fi
  
  # Sort timestamps by epoch (oldest first)
  local sorted_timestamps=($(
    for ts in "${backup_timestamps[@]}"; do
      echo "${backup_epochs[$ts]} $ts"
    done | sort -n | awk '{print $2}'
  ))
  
  local total_backups=${#sorted_timestamps[@]}
  local to_delete=0
  local to_keep=0
  local total_size=0
  local delete_size=0
  
  echo "  Total backups: $total_backups"
  
  # Build retention sets
  declare -A keep_weekly
  declare -A keep_monthly
  
  # First pass: identify which backups to keep for weekly/monthly retention
  for timestamp in "${sorted_timestamps[@]}"; do
    if [[ "${backup_epochs[$timestamp]}" == "0" ]]; then
      continue
    fi
    
    local age_days=$(get_age_days "$timestamp")
    
    # Weekly retention: keep oldest in each week
    if [[ $age_days -gt $KEEP_DAILY ]] && [[ $age_days -le $KEEP_WEEKLY ]]; then
      local week_id=$(get_week_id "$timestamp")
      if [[ -n "$week_id" ]]; then
        if [[ -z "${keep_weekly[$week_id]}" ]] || [[ "${backup_epochs[$timestamp]}" -lt "${backup_epochs[${keep_weekly[$week_id]}]}" ]]; then
          keep_weekly["$week_id"]="$timestamp"
        fi
      fi
    fi
    
    # Monthly retention: keep oldest in each month
    if [[ $age_days -gt $KEEP_WEEKLY ]] && [[ $age_days -le $KEEP_MONTHLY ]]; then
      local month_id=$(get_month_id "$timestamp")
      if [[ -n "$month_id" ]]; then
        if [[ -z "${keep_monthly[$month_id]}" ]] || [[ "${backup_epochs[$timestamp]}" -lt "${backup_epochs[${keep_monthly[$month_id]}]}" ]]; then
          keep_monthly["$month_id"]="$timestamp"
        fi
      fi
    fi
  done
  
  # Second pass: decide what to keep/delete
  for timestamp in "${sorted_timestamps[@]}"; do
    if [[ "${backup_epochs[$timestamp]}" == "0" ]]; then
      continue
    fi
    
    local filename="${backup_files[$timestamp]}"
    local age_days=$(get_age_days "$timestamp")
    local size="${backup_sizes[$timestamp]}"
    local should_keep=false
    local reason=""
    
    total_size=$((total_size + size))
    
    # Check retention policies
    if should_keep_daily "$age_days"; then
      should_keep=true
      reason="Daily retention (${age_days} days old)"
    else
      local week_id=$(get_week_id "$timestamp")
      local month_id=$(get_month_id "$timestamp")
      
      if [[ $age_days -gt $KEEP_DAILY ]] && [[ $age_days -le $KEEP_WEEKLY ]] && [[ "${keep_weekly[$week_id]}" == "$timestamp" ]]; then
        should_keep=true
        reason="Weekly retention (${age_days} days old, oldest in week)"
      elif [[ $age_days -gt $KEEP_WEEKLY ]] && [[ $age_days -le $KEEP_MONTHLY ]] && [[ "${keep_monthly[$month_id]}" == "$timestamp" ]]; then
        should_keep=true
        reason="Monthly retention (${age_days} days old, oldest in month)"
      else
        should_keep=false
        if [[ $age_days -gt $KEEP_MONTHLY ]]; then
          reason="Beyond retention period (${age_days} days old)"
        else
          reason="Not oldest in period (${age_days} days old)"
        fi
      fi
    fi
    
    if [[ "$should_keep" == true ]]; then
      to_keep=$((to_keep + 1))
      echo -e "  ${GREEN}KEEP${NC}: $filename ($reason)"
    else
      to_delete=$((to_delete + 1))
      delete_size=$((delete_size + size))
      if [[ "$DRY_RUN" == true ]]; then
        echo -e "  ${YELLOW}[DRY RUN] DELETE${NC}: $filename ($reason)"
      else
        echo -e "  ${RED}DELETE${NC}: $filename ($reason)"
        rclone delete "${service_path}${filename}" 2>/dev/null
        if [[ $? -eq 0 ]]; then
          echo -e "    ${GREEN}Deleted successfully${NC}"
        else
          echo -e "    ${RED}Failed to delete${NC}"
        fi
      fi
    fi
  done
  
  # Format sizes
  local total_size_mb=$((total_size / 1024 / 1024))
  local delete_size_mb=$((delete_size / 1024 / 1024))
  
  # Accumulate global statistics
  CLEANUP_STATS_TOTAL=$((CLEANUP_STATS_TOTAL + total_backups))
  CLEANUP_STATS_KEPT=$((CLEANUP_STATS_KEPT + to_keep))
  CLEANUP_STATS_DELETED=$((CLEANUP_STATS_DELETED + to_delete))
  CLEANUP_STATS_SPACE_FREED_MB=$((CLEANUP_STATS_SPACE_FREED_MB + delete_size_mb))
  
  echo "  Summary:"
  echo "    Keeping: $to_keep backups"
  echo "    Deleting: $to_delete backups"
  echo "    Total size: ${total_size_mb} MB"
  echo "    Space to free: ${delete_size_mb} MB"
}

# Function to run cleanup
run_cleanup() {
  echo -e "${BLUE}=== Starting Cleanup Operations ===${NC}"
  
  # Initialize cleanup statistics
  CLEANUP_STATS_TOTAL=0
  CLEANUP_STATS_KEPT=0
  CLEANUP_STATS_DELETED=0
  CLEANUP_STATS_SPACE_FREED_MB=0
  
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}DRY RUN MODE - No files will be deleted${NC}"
    if [[ "$NON_INTERACTIVE" == false ]]; then
      echo "Run with --execute or -e to actually delete files"
    fi
  else
    echo -e "${RED}EXECUTE MODE - Files will be permanently deleted!${NC}"
  fi

  echo ""
  echo "Retention Policy:"
  echo "  - Keep all backups from last $KEEP_DAILY days (daily)"
  echo "  - Keep one backup per week for last $((KEEP_WEEKLY / 7)) weeks (weekly)"
  echo "  - Keep one backup per month for last $((KEEP_MONTHLY / 30)) months (monthly)"
  echo "  - Delete everything older than $((KEEP_MONTHLY / 30)) months"
  echo ""

  # Get list of all services/directories in remote backup
  echo "Discovering services..."
  services=$(rclone lsd "$REMOTE_BACKUP_DIR" 2>/dev/null | awk '{print $5}')

  if [[ -z "$services" ]]; then
    echo -e "${RED}Error: Could not list remote backup directory${NC}"
    echo "Check your rclone configuration and remote path: $REMOTE_BACKUP_DIR"
    return 1
  fi

  # Process each service
  total_services=0
  while IFS= read -r service; do
    if [[ -n "$service" ]]; then
      cleanup_service_backups "$service"
      total_services=$((total_services + 1))
    fi
  done <<< "$services"

  echo ""
  echo -e "${BLUE}=== Cleanup Complete ===${NC}"
  echo "Processed $total_services service(s)"

  if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "This was a dry run. To actually delete files, run:"
    echo "  $0 --cleanup --execute"
  fi
  
  # Send Discord notification
  send_cleanup_summary
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

# Parse command line arguments
DO_BACKUP=false
DO_CLEANUP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --backup|-b)
      DO_BACKUP=true
      shift
      ;;
    --cleanup|-c)
      DO_CLEANUP=true
      shift
      ;;
    --all|-a)
      DO_BACKUP=true
      DO_CLEANUP=true
      shift
      ;;
    --execute|-e)
      DRY_RUN=false
      shift
      ;;
    --non-interactive|-y)
      NON_INTERACTIVE=true
      shift
      ;;
    --service|-s)
      if [[ -z "$2" ]]; then
        echo -e "${RED}Error: --service requires a service name${NC}"
        show_usage
        exit 1
      fi
      SERVICE_FILTER=$(trim_whitespace "$2")
      shift 2
      ;;
    --help|-h)
      show_usage
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      show_usage
      exit 1
      ;;
  esac
done

# Default behavior: if nothing specified, run backup only (not cleanup)
# Cleanup must be explicitly requested with --cleanup or --all
if [[ "$DO_BACKUP" == false ]] && [[ "$DO_CLEANUP" == false ]]; then
  DO_BACKUP=true
  # DO_CLEANUP remains false - cleanup must be explicitly requested
fi

# Handle interactive confirmation for cleanup in non-interactive mode
if [[ "$DO_CLEANUP" == true ]] && [[ "$DRY_RUN" == false ]] && [[ "$NON_INTERACTIVE" == false ]]; then
  echo -e "${YELLOW}WARNING: Execute mode enabled. Backups will be permanently deleted!${NC}"
  read -p "Are you sure you want to proceed? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Execute requested operations
if [[ "$DO_BACKUP" == true ]]; then
  run_backups
  echo ""
fi

if [[ "$DO_CLEANUP" == true ]]; then
  run_cleanup
fi

exit 0
