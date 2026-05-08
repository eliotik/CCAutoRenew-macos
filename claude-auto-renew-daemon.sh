#!/bin/bash

# Claude Auto-Renewal Daemon - Continuous Running Script
# Runs continuously in the background, checking for renewal windows

LOG_FILE="$HOME/.claude-auto-renew-daemon.log"
PID_FILE="$HOME/.claude-auto-renew-daemon.pid"
LAST_ACTIVITY_FILE="$HOME/.claude-last-activity"
START_TIME_FILE="$HOME/.claude-auto-renew-start-time"
STOP_TIME_FILE="$HOME/.claude-auto-renew-stop-time"
MESSAGE_FILE="$HOME/.claude-auto-renew-message"
DIR_FILE="$HOME/.claude-auto-renew-dir"
SESSION_FILE="$HOME/.claude-auto-renew-session"
CONTINUE_FILE="$HOME/.claude-auto-renew-continue"
DISABLE_CCUSAGE=false

# Function to log messages
log_message() {
    # Send to log file and also to stderr (so it's not captured by $(...) blocks)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE" >&2
}

# Function to handle shutdown
cleanup() {
    log_message "Daemon shutting down..."
    rm -f "$PID_FILE"
    exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Function to check if we're in the active monitoring window
is_monitoring_active() {
    local current_epoch="${1:-$(date +%s)}"
    local start_epoch=""
    local stop_epoch=""
    
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi
    
    # If no start time set, always active (unless stop time is set and passed)
    if [ -z "$start_epoch" ]; then
        if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
            return 1  # Past stop time
        else
            return 0  # Active
        fi
    fi
    
    # Check if we're before start time
    if [ "$current_epoch" -lt "$start_epoch" ]; then
        return 1  # Before start time
    fi
    
    # Check if we're past stop time
    if [ -n "$stop_epoch" ] && [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 1  # Past stop time
    fi
    
    return 0  # In active window
}

# Function to check if we should schedule next day restart
should_restart_tomorrow() {
    local current_epoch="${1:-$(date +%s)}"
    
    if [ ! -f "$START_TIME_FILE" ] || [ ! -f "$STOP_TIME_FILE" ]; then
        return 1  # No scheduling needed
    fi
    
    local stop_epoch=$(cat "$STOP_TIME_FILE")
    
    # Check if we've passed stop time
    if [ "$current_epoch" -ge "$stop_epoch" ]; then
        return 0  # Should restart tomorrow
    fi
    
    return 1  # Not yet time
}

# Function to schedule restart for next day
schedule_next_day_restart() {
    if [ ! -f "$START_TIME_FILE" ]; then
        return 1
    fi
    
    local start_epoch=$(cat "$START_TIME_FILE")
    local stop_epoch=""
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
    fi
    
    # Calculate tomorrow's start time
    local next_start=$((start_epoch + 86400))
    local next_stop=""
    
    if [ -n "$stop_epoch" ]; then
        next_stop=$((stop_epoch + 86400))
    fi
    
    # Update the time files for tomorrow
    echo "$next_start" > "$START_TIME_FILE"
    if [ -n "$next_stop" ]; then
        echo "$next_stop" > "$STOP_TIME_FILE"
    fi
    
    # Remove activation marker so it gets recreated tomorrow
    rm -f "${START_TIME_FILE}.activated" 2>/dev/null
    
    log_message "🔄 Scheduled restart for tomorrow at $(date -d "@$next_start" 2>/dev/null || date -r "$next_start")"
    
    return 0
}

# Function to get time until start
get_time_until_start() {
    local current_epoch="${1:-$(date +%s)}"
    
    if [ ! -f "$START_TIME_FILE" ]; then
        echo "0"
        return
    fi
    
    local start_epoch=$(cat "$START_TIME_FILE")
    local diff=$((start_epoch - current_epoch))
    
    if [ "$diff" -le 0 ]; then
        echo "0"
    else
        echo "$diff"
    fi
}

# Function to get ccusage command
get_ccusage_cmd() {
    if command -v ccusage &> /dev/null; then
        echo "ccusage"
    elif command -v bunx &> /dev/null; then
        echo "bunx ccusage"
    elif command -v npx &> /dev/null; then
        echo "npx ccusage@latest"
    else
        return 1
    fi
}

# Function to get minutes until reset
get_minutes_until_reset() {
    # If ccusage is disabled, return nothing to force time-based checking
    if [ "$DISABLE_CCUSAGE" = true ]; then
        return 1
    fi
    
    local ccusage_cmd=$(get_ccusage_cmd)
    if [ $? -ne 0 ]; then
        return 1
    fi
    
    # Try to get time remaining from ccusage
    local output=""
    
    # Method 1: Use jq if available for better precision
    if command -v jq &> /dev/null; then
        # Try to get active block info in JSON format
        local json_output=$($ccusage_cmd blocks -a -j 2>/dev/null)
        if [ -n "$json_output" ] && [ "$json_output" != "null" ]; then
            # Priority 1: Time until block endTime (actual reset window)
            local end_time=$(echo "$json_output" | jq -r '.blocks[0].endTime // empty' 2>/dev/null)
            if [ -n "$end_time" ] && [ "$end_time" != "null" ]; then
                local current_ts=$(date +%s)
                # Parse ISO date (works on macOS and Linux)
                local end_ts=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$end_time" +%s 2>/dev/null || \
                              date -j -f "%Y-%m-%dT%H:%M:%S.000Z" "$end_time" +%s 2>/dev/null || \
                              date -d "$end_time" +%s 2>/dev/null)
                
                if [ -n "$end_ts" ]; then
                    local diff=$(( (end_ts - current_ts) / 60 ))
                    if [ $diff -ge 0 ]; then
                        echo "$diff"
                        return 0
                    fi
                fi
            fi
            
            # Priority 2: Projection remaining minutes (time until limit hit)
            local proj_rem=$(echo "$json_output" | jq -r '.blocks[0].projection.remainingMinutes // empty' 2>/dev/null)
            if [ -n "$proj_rem" ] && [ "$proj_rem" != "null" ] && [ "$proj_rem" != "0" ]; then
                echo "$proj_rem"
                return 0
            fi
        fi
    fi
    
    # Method 2: Fallback to regex on text output
    # Try active block first
    output=$($ccusage_cmd blocks -a 2>/dev/null | grep -i "remaining" | head -1)
    
    # Fallback to general blocks if active fails
    if [ -z "$output" ]; then
        output=$($ccusage_cmd blocks 2>/dev/null | grep -i "time remaining" | head -1)
    fi
    
    if [ -z "$output" ]; then
        output=$($ccusage_cmd blocks --live 2>/dev/null | grep -i "remaining" | head -1)
    fi
    
    # Parse time
    local hours=0
    local minutes=0
    
    if [[ "$output" =~ ([0-9]+)h[[:space:]]*([0-9]+)m ]]; then
        hours=${BASH_REMATCH[1]}
        minutes=${BASH_REMATCH[2]}
    elif [[ "$output" =~ ([0-9]+)m ]]; then
        minutes=${BASH_REMATCH[1]}
    fi
    
    echo $((hours * 60 + minutes))
}

# Function to start Claude session
start_claude_session() {
    log_message "Starting Claude session for renewal..."
    
    if ! command -v claude &> /dev/null; then
        log_message "ERROR: claude command not found"
        return 1
    fi
    
    # Check if custom message is available
    local selected_message=""
    
    if [ -f "$MESSAGE_FILE" ]; then
        # Use custom message
        selected_message=$(cat "$MESSAGE_FILE")
        # Strip quotes if they somehow got into the file
        selected_message="${selected_message%\"}"
        selected_message="${selected_message#\"}"
        log_message "Using custom message: \"$selected_message\""
    else
        # Define an array of predefined messages
        local messages=("hi" "hello" "hey there" "good day" "greetings" "howdy" "what's up" "salutations")
        
        # Randomly select a message from the array
        local random_index=$((RANDOM % ${#messages[@]}))
        selected_message="${messages[$random_index]}"
    fi

    # Build claude command arguments as an array
    local claude_args=("--dangerously-skip-permissions")
    
    # Add session resume parameters
    if [ -f "$SESSION_FILE" ]; then
        local session_id=$(cat "$SESSION_FILE")
        # Strip quotes to avoid double-quoting issues
        session_id="${session_id%\"}"
        session_id="${session_id#\"}"
        claude_args+=("--resume" "$session_id")
        log_message "Resuming session: $session_id"
    elif [ -f "$CONTINUE_FILE" ]; then
        claude_args+=("--continue")
        log_message "Using --continue flag"
    fi

    # Determine execution directory
    local exec_dir="."
    if [ -f "$DIR_FILE" ]; then
        exec_dir=$(cat "$DIR_FILE")
        # Expand ~ if present
        if [[ "$exec_dir" == "~"* ]]; then
            exec_dir="${HOME}${exec_dir:1}"
        fi
        if [ -d "$exec_dir" ]; then
            log_message "Executing renewal in directory: $exec_dir"
        else
            log_message "WARNING: Configured directory $exec_dir does not exist, using current directory"
            exec_dir="."
        fi
    fi
    
    # Check for tmux
    local use_tmux=false
    if command -v tmux &> /dev/null; then
        use_tmux=true
    fi

    if [ "$use_tmux" = true ]; then
        log_message "Executing via tmux session 'claude-renewal'..."
        # Kill existing renewal session if it exists
        tmux kill-session -t claude-renewal 2>/dev/null
        
        # Start new session in tmux
        # We use tee to capture output to log file and also show it in tmux
        # We add a sleep/read at the end so the user can see what happened if they attach
        tmux new-session -d -s claude-renewal -c "$exec_dir" \
            "echo \"$selected_message\" | claude ${claude_args[@]} 2>&1 | tee -a \"$LOG_FILE\"; \
             echo -e \"\n--- Renewal finished at \$(date) ---\"; \
             echo \"You can attach to this session next time to see the status.\"; \
             sleep 60"
        
        # We'll consider it successful if we could start the tmux session
        # The daemon will still log "Renewal successful!"
        date +%s > "$LAST_ACTIVITY_FILE"
        return 0
    else
        # Fallback to subshell if no tmux (with corrected argument passing)
        (cd "$exec_dir" && echo "$selected_message" | claude "${claude_args[@]}" >> "$LOG_FILE" 2>&1) &
        local pid=$!
        
        # Wait up to 15 seconds
        local count=0
        while kill -0 $pid 2>/dev/null && [ $count -lt 15 ]; do
            sleep 1
            ((count++))
        done
        
        # Kill if still running
        if kill -0 $pid 2>/dev/null; then
            kill $pid 2>/dev/null
            wait $pid 2>/dev/null
            local result=124  # timeout exit code
        else
            wait $pid
            local result=$?
        fi
        
        if [ $result -eq 0 ] || [ $result -eq 124 ]; then
            log_message "Claude session started successfully"
            date +%s > "$LAST_ACTIVITY_FILE"
            return 0
        else
            log_message "ERROR: Failed to start Claude session (Exit code: $result)"
            return 1
        fi
    fi
}

# Function to calculate next check time
calculate_sleep_duration() {
    local minutes_remaining=$(get_minutes_until_reset)
    local sleep_time=300 # Default 5 minutes
    
    if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
        log_message "Time remaining: $minutes_remaining minutes"
        
        if [ "$minutes_remaining" -le 5 ]; then
            # Check every 30 seconds when close to reset
            sleep_time=30
        elif [ "$minutes_remaining" -le 30 ]; then
            # Check every 2 minutes when within 30 minutes
            sleep_time=120
        else
            # Check every 10 minutes otherwise
            sleep_time=600
        fi
    else
        # Fallback: check based on last activity
        if [ -f "$LAST_ACTIVITY_FILE" ]; then
            local last_activity=$(cat "$LAST_ACTIVITY_FILE")
            local current_time=$(date +%s)
            local time_diff=$((current_time - last_activity))
            local remaining=$((18000 - time_diff))  # 5 hours = 18000 seconds
            
            if [ "$remaining" -le 300 ]; then  # 5 minutes
                sleep_time=30
            elif [ "$remaining" -le 1800 ]; then  # 30 minutes
                sleep_time=120
            else
                sleep_time=600
            fi
        else
            # No info available, check every 5 minutes
            sleep_time=300
        fi
    fi
    
    echo "$sleep_time"
}

# Main daemon loop
main() {
    # Check if already running
    if [ -f "$PID_FILE" ]; then
        OLD_PID=$(cat "$PID_FILE")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            echo "Daemon already running with PID $OLD_PID"
            exit 1
        else
            log_message "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi
    
    # Save PID
    echo $$ > "$PID_FILE"
    
    log_message "=== Claude Auto-Renewal Daemon Started ==="
    log_message "PID: $$"
    log_message "Logs: $LOG_FILE"
    
    # Log ccusage status
    if [ "$DISABLE_CCUSAGE" = true ]; then
        log_message "⚠️  ccusage DISABLED - Using clock-based timing only"
    else
        log_message "✅ ccusage ENABLED - Using accurate timing when available"
    fi
    
    # Check for start and stop times
    if [ -f "$START_TIME_FILE" ]; then
        start_epoch=$(cat "$START_TIME_FILE")
        log_message "Start time configured: $(date -d "@$start_epoch" 2>/dev/null || date -r "$start_epoch")"
    else
        log_message "No start time set - will begin monitoring immediately"
    fi
    
    if [ -f "$STOP_TIME_FILE" ]; then
        stop_epoch=$(cat "$STOP_TIME_FILE")
        log_message "Stop time configured: $(date -d "@$stop_epoch" 2>/dev/null || date -r "$stop_epoch")"
    else
        log_message "No stop time set - will monitor continuously"
    fi
    
    # Check for custom message
    if [ -f "$MESSAGE_FILE" ]; then
        custom_message=$(cat "$MESSAGE_FILE")
        log_message "Custom renewal message configured: \"$custom_message\""
    else
        log_message "Using default random greeting messages for renewal"
    fi
    
    # Check ccusage availability
    if [ "$DISABLE_CCUSAGE" = false ] && ! get_ccusage_cmd &> /dev/null; then
        log_message "WARNING: ccusage not found. Using time-based checking."
        log_message "Install ccusage for more accurate timing: npm install -g ccusage"
    fi
    
    # Main loop
    while true; do
        # Get current timestamp for this iteration
        local now=$(date +%s)
        
        # Check if we should schedule next day restart first
        if should_restart_tomorrow "$now"; then
            log_message "🛑 Stop time reached. Scheduling restart for tomorrow..."
            schedule_next_day_restart
            
            # Wait for tomorrow's start time
            while ! is_monitoring_active "$(date +%s)"; do
                local current_now=$(date +%s)
                time_until_start=$(get_time_until_start "$current_now")
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                
                if [ "$hours" -gt 0 ]; then
                    log_message "⏰ Waiting for tomorrow's start time (${hours}h ${minutes}m remaining)..."
                    sleep 3600  # Check every hour when waiting for tomorrow
                else
                    log_message "⏰ Waiting for start time (${minutes}m remaining)..."
                    sleep 300   # Check every 5 minutes when close
                fi
            done
            
            log_message "🌅 New day started! Resuming monitoring..."
            continue
        fi
        
        # Check if we're in monitoring window
        if ! is_monitoring_active "$now"; then
            # Calculate time until start or reason for inactivity
            if [ -f "$START_TIME_FILE" ]; then
                time_until_start=$(get_time_until_start "$now")
                hours=$((time_until_start / 3600))
                minutes=$(((time_until_start % 3600) / 60))
                seconds=$((time_until_start % 60))
                
                if [ "$time_until_start" -gt 0 ]; then
                    # Before start time
                    if [ "$hours" -gt 0 ]; then
                        log_message "⏰ Waiting for start time (${hours}h ${minutes}m remaining)..."
                        sleep 300  # Check every 5 minutes when waiting
                    elif [ "$minutes" -gt 2 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 60   # Check every minute when close
                    elif [ "$time_until_start" -gt 10 ]; then
                        log_message "⏰ Waiting for start time (${minutes}m ${seconds}s remaining)..."
                        sleep 10   # Check every 10 seconds when very close
                    else
                        log_message "⏰ Waiting for start time (${seconds}s remaining)..."
                        sleep 2    # Check every 2 seconds when imminent
                    fi
                else
                    # Not before start time, but not active - must be past stop time
                    if [ -f "$STOP_TIME_FILE" ]; then
                        log_message "🛑 Past stop time, waiting for tomorrow..."
                    else
                        # This should theoretically not happen if is_monitoring_active is consistent
                        # but if it does, just log and sleep briefly to retry
                        log_message "⚠️  Monitoring inactive (checking again in 1m)..."
                        sleep 60
                        continue
                    fi
                    sleep 300
                fi
            else
                # No start time but inactive - must be past stop time
                if [ -f "$STOP_TIME_FILE" ]; then
                    log_message "🛑 Past stop time, no restart scheduled..."
                else
                    log_message "⚠️  Monitoring inactive, no schedule set..."
                fi
                sleep 300
            fi
            continue
        fi
        
        # If we just entered active time, log it
        if [ -f "$START_TIME_FILE" ]; then
            # Check if this is the first time we're active today
            if [ ! -f "${START_TIME_FILE}.activated" ]; then
                log_message "✅ Start time reached! Beginning auto-renewal monitoring..."
                touch "${START_TIME_FILE}.activated"
            fi
        fi
        
        # Check if we're approaching stop time
        current_time=$(date +%s)
        stop_time_approaching=false
        
        if [ -f "$STOP_TIME_FILE" ]; then
            stop_epoch=$(cat "$STOP_TIME_FILE")
            time_until_stop=$((stop_epoch - current_time))
            
            # Don't start new renewals if stop time is within 10 minutes
            if [ "$time_until_stop" -le 600 ] && [ "$time_until_stop" -gt 0 ]; then
                stop_time_approaching=true
                minutes_until_stop=$((time_until_stop / 60))
                log_message "⚠️  Stop time approaching in ${minutes_until_stop} minutes - no new renewals"
            fi
        fi
        
        # Get minutes until reset
        minutes_remaining=$(get_minutes_until_reset)
        
        # Check if we should renew (only if not approaching stop time)
        should_renew=false
        
        if [ "$stop_time_approaching" = false ]; then
            if [ -n "$minutes_remaining" ] && [ "$minutes_remaining" -gt 0 ]; then
                if [ "$minutes_remaining" -le 2 ]; then
                    should_renew=true
                    log_message "Reset imminent ($minutes_remaining minutes), preparing to renew..."
                fi
            else
                # Fallback check
                if [ -f "$LAST_ACTIVITY_FILE" ]; then
                    last_activity=$(cat "$LAST_ACTIVITY_FILE")
                    current_time=$(date +%s)
                    time_diff=$((current_time - last_activity))
                    
                    if [ $time_diff -ge 18000 ]; then
                        should_renew=true
                        log_message "5 hours elapsed since last activity, renewing..."
                    fi
                else
                    # No activity recorded, safe to start
                    should_renew=true
                    log_message "No previous activity recorded, starting initial session..."
                fi
            fi
        fi
        
        # Perform renewal if needed
        if [ "$should_renew" = true ]; then
            # Wait a bit to ensure we're in the renewal window
            sleep 60
            
            # Try to start session
            if start_claude_session; then
                log_message "Renewal successful!"
                # Sleep for 5 minutes after successful renewal
                sleep 300
            else
                log_message "Renewal failed, will retry in 1 minute"
                sleep 60
            fi
        fi
        
        # Calculate how long to sleep
        sleep_duration=$(calculate_sleep_duration)
        
        # Log wait time in minutes (round up)
        if [ "$sleep_duration" -ge 60 ]; then
            log_message "Next check in $((sleep_duration / 60)) minutes"
        else
            log_message "Next check in $sleep_duration seconds"
        fi
        
        # Sleep until next check
        sleep "$sleep_duration"
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --disableccusage)
            DISABLE_CCUSAGE=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

# Start the daemon
main