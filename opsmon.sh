#!/bin/bash

# Set the maximum number of parallel jobs (reduced to avoid rate limiting)
MAX_PARALLEL=20
PING_LOG_FILE="ping_results.log"
OPSGENIE_LOG_FILE="opsgenie_alerts.log"
OPSGENIE_TEMP_FILE=$(mktemp)  # Temporary file for Opsgenie messages
OPSGENIE_API_KEY="YOUR_API_KEY_HERE"  # Hardcoded Opsgenie API key
OPSGENIE_API_URL="https://api.eu.opsgenie.com/v2/alerts"  # Updated to EU region
MAX_ATTEMPTS=4  # Number of ping attempts before confirming failure
RETRY_DELAY=10  # Seconds to wait before retrying ping
CLOSE_RETRY_DELAY=5  # Seconds to wait before retrying a failed close request
RATE_LIMIT_DELAY=2  # Increased to 1 second to respect Opsgenie API rate limits
HOSTS_FILE="hosts.conf"  # File containing IP-to-hostname mappings

# Declare an associative array for IPs and hostnames
declare -A IP_HOSTS

# Debug flag
DEBUG_MODE=0

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG_MODE=1
            shift
            ;;
        *)
            echo "Usage: $0 [--debug]"
            exit 1
            ;;
    esac
done

# Function to append to log file
append_message() {
    local MESSAGE="$1"
    local LOG_FILE="$2"
    echo "$MESSAGE" >> "$LOG_FILE"
}

# Function to append to Opsgenie temp file and log file with debug check
append_opsgenie_message() {
    local MESSAGE="$1"
    # Check if message is a DEBUG message
    if echo "$MESSAGE" | grep -q "OPSGENIE: DEBUG:"; then
        if [ $DEBUG_MODE -eq 1 ]; then
            append_message "$MESSAGE" "$OPSGENIE_TEMP_FILE"
            append_message "$MESSAGE" "$OPSGENIE_LOG_FILE"
        fi
    else
        append_message "$MESSAGE" "$OPSGENIE_TEMP_FILE"
        append_message "$MESSAGE" "$OPSGENIE_LOG_FILE"
    fi
}

# Function to load hosts from the configuration file
load_hosts() {
    if [[ ! -f "$HOSTS_FILE" ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: Hosts file '$HOSTS_FILE' not found!" | tee -a "$PING_LOG_FILE"
        exit 1
    fi

    while IFS='=' read -r ip hostname; do
        [[ -z "$ip" || "$ip" =~ ^# ]] && continue
        ip=$(echo "$ip" | xargs)
        hostname=$(echo "$hostname" | xargs)
        if [[ -n "$ip" && -n "$hostname" ]]; then
            IP_HOSTS["$ip"]="$hostname"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - WARNING: Invalid line in '$HOSTS_FILE': '$ip=$hostname'" | tee -a "$PING_LOG_FILE"
        fi
    done < "$HOSTS_FILE"

    if [[ ${#IP_HOSTS[@]} -eq 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR: No valid hosts loaded from '$HOSTS_FILE'!" | tee -a "$PING_LOG_FILE"
        exit 1
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO: Loaded ${#IP_HOSTS[@]} hosts from '$HOSTS_FILE'" | tee -a "$PING_LOG_FILE"
}

# Function to check Opsgenie alert state
check_existing_alert() {
    local ALIAS=$1
    local RESPONSE
    local ATTEMPT=0
    local MAX_RETRIES=1

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
        RESPONSE=$(curl -s --connect-timeout 10 -X GET "$OPSGENIE_API_URL?query=alias%3A$ALIAS&sort=createdAt&order=desc&limit=1" \
            -H "Authorization: GenieKey $OPSGENIE_API_KEY")

        if [ $? -ne 0 ]; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: curl failed for $ALIAS in check"
            return 0
        fi

        if echo "$RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
            if [ $ATTEMPT -lt $MAX_RETRIES ]; then
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Rate limit exceeded for $ALIAS in check, retrying in $((RATE_LIMIT_DELAY * (ATTEMPT + 1))) seconds"
                sleep $((RATE_LIMIT_DELAY * (ATTEMPT + 1)))
                ((ATTEMPT++))
                continue
            else
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: Rate limit exceeded for $ALIAS in check after retries"
                return 0
            fi
        fi

        if ! echo "$RESPONSE" | grep -q '"data"'; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: API error for $ALIAS in check, response: $RESPONSE"
            return 0
        fi

        if echo "$RESPONSE" | grep -q '"data":\[\]'; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: No alerts found for $ALIAS in check"
            return 0
        fi

        local STATUS
        if command -v jq >/dev/null 2>&1; then
            STATUS=$(echo "$RESPONSE" | jq -r '.data[0].status // empty')
        else
            STATUS=$(echo "$RESPONSE" | grep -oP '(?<="status":")[^"]*' | head -1)
        fi

        if [ -z "$STATUS" ]; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: Unable to parse status for $ALIAS in check, response: $RESPONSE"
            return 0
        fi

        case "$STATUS" in
            "open"|"acknowledged")
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ℹ️ Existing alert for $ALIAS is $STATUS, skipping creation"
                return 1
                ;;
            *)
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: Alert for $ALIAS is $STATUS, proceeding with creation"
                return 0
                ;;
        esac
    done
}

# Function to create an alert in Opsgenie
create_opsgenie_alert() {
    local TARGET_IP=$1
    local HOSTNAME=$2
    local MESSAGE=$3
    local ALIAS=$TARGET_IP
    local ATTEMPT=0
    local MAX_RETRIES=1

    check_existing_alert "$ALIAS"
    local CHECK_RESULT=$?
    if [ $CHECK_RESULT -eq 1 ]; then
        append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: Skipping alert creation for $TARGET_IP ($HOSTNAME) due to existing active alert"
        return
    fi

    append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: No active alert for $TARGET_IP ($HOSTNAME), proceeding with creation"

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
        local CREATE_RESPONSE
        CREATE_RESPONSE=$(curl -s --connect-timeout 10 -X POST "$OPSGENIE_API_URL" \
            -H "Authorization: GenieKey $OPSGENIE_API_KEY" \
            -H "Content-Type: application/json" \
            -d '{
                "message": "'"$MESSAGE"'",
                "alias": "'"$ALIAS"'",
                "description": "Ping test failure for '"$HOSTNAME"' ('"$TARGET_IP"')",
                "priority": "P3",
                "source": "Ping Monitoring Script"
            }')

        if [ $? -eq 0 ] && ! echo "$CREATE_RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: 🚨 Alert sent to Opsgenie for $TARGET_IP ($HOSTNAME)"
            break
        elif echo "$CREATE_RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
            if [ $ATTEMPT -lt $MAX_RETRIES ]; then
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Rate limit exceeded for $TARGET_IP ($HOSTNAME) in create, retrying in $((RATE_LIMIT_DELAY * (ATTEMPT + 1))) seconds"
                sleep $((RATE_LIMIT_DELAY * (ATTEMPT + 1)))
                ((ATTEMPT++))
            else
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Failed to send alert to Opsgenie for $TARGET_IP ($HOSTNAME) due to rate limit after retries"
                break
            fi
        else
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Failed to send alert to Opsgenie for $TARGET_IP ($HOSTNAME), response: $CREATE_RESPONSE"
            break
        fi
    done
    sleep "$RATE_LIMIT_DELAY"
}

# Function to close an alert in Opsgenie
close_opsgenie_alert() {
    local TARGET_IP=$1
    local HOSTNAME=$2
    local ALIAS=$TARGET_IP
    local RESPONSE
    local ATTEMPT=0
    local MAX_RETRIES=1

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
        RESPONSE=$(curl -s --connect-timeout 10 -X GET "$OPSGENIE_API_URL?query=alias%3A$ALIAS&sort=createdAt&order=desc&limit=1" \
            -H "Authorization: GenieKey $OPSGENIE_API_KEY")

        if [ $? -ne 0 ]; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: curl failed for $TARGET_IP ($HOSTNAME) in close"
            return
        fi

        if echo "$RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
            if [ $ATTEMPT -lt $MAX_RETRIES ]; then
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Rate limit exceeded for $TARGET_IP ($HOSTNAME) in close, retrying in $((RATE_LIMIT_DELAY * (ATTEMPT + 1))) seconds"
                sleep $((RATE_LIMIT_DELAY * (ATTEMPT + 1)))
                ((ATTEMPT++))
                continue
            else
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: Rate limit exceeded for $TARGET_IP ($HOSTNAME) in close after retries"
                return
            fi
        fi

        if ! echo "$RESPONSE" | grep -q '"data"'; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: API error for $TARGET_IP ($HOSTNAME) in close, response: $RESPONSE"
            return
        fi

        if echo "$RESPONSE" | grep -q '"data":\[\]'; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: No alerts found for $TARGET_IP ($HOSTNAME) in close"
            return
        fi

        local ALERT_ID
        local STATUS
        if command -v jq >/dev/null 2>&1; then
            ALERT_ID=$(echo "$RESPONSE" | jq -r '.data[0].id // empty')
            STATUS=$(echo "$RESPONSE" | jq -r '.data[0].status // empty')
        else
            ALERT_ID=$(echo "$RESPONSE" | grep -oP '(?<="id":")[^"]*' | head -1)
            STATUS=$(echo "$RESPONSE" | grep -oP '(?<="status":")[^"]*' | head -1)
        fi

        if [ -z "$ALERT_ID" ] || [ -z "$STATUS" ]; then
            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ERROR: Unable to parse alert ID or status for $TARGET_IP ($HOSTNAME) in close, response: $RESPONSE"
            return
        fi

        case "$STATUS" in
            "open"|"acknowledged")
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: Found $STATUS alert for $TARGET_IP ($HOSTNAME), attempting to close"
                local CLOSE_ATTEMPT=0
                while [ $CLOSE_ATTEMPT -le $MAX_RETRIES ]; do
                    local CLOSE_RESPONSE
                    CLOSE_RESPONSE=$(curl -s --connect-timeout 10 -X POST "$OPSGENIE_API_URL/$ALERT_ID/close" \
                        -H "Authorization: GenieKey $OPSGENIE_API_KEY" \
                        -H "Content-Type: application/json" \
                        -d '{
                            "note": "Alert auto-closed: Device is now reachable",
                            "source": "Ping Monitoring Script"
                        }')

                    if [ $? -eq 0 ] && ! echo "$CLOSE_RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
                        append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ✅ Alert closed for $TARGET_IP ($HOSTNAME) (was $STATUS)"
                        break
                    elif echo "$CLOSE_RESPONSE" | grep -q '"message":"You are making too many requests!"'; then
                        if [ $CLOSE_ATTEMPT -lt $MAX_RETRIES ]; then
                            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Rate limit exceeded for $TARGET_IP ($HOSTNAME) in close attempt, retrying in $((CLOSE_RETRY_DELAY * (CLOSE_ATTEMPT + 1))) seconds"
                            sleep $((CLOSE_RETRY_DELAY * (CLOSE_ATTEMPT + 1)))
                            ((CLOSE_ATTEMPT++))
                        else
                            append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Failed to close alert for $TARGET_IP ($HOSTNAME) (was $STATUS) due to rate limit after retries"
                            break
                        fi
                    else
                        append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Failed to close alert for $TARGET_IP ($HOSTNAME) (was $STATUS), response: $CLOSE_RESPONSE"
                        break
                    fi
                done
                break
                ;;
            "closed")
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: DEBUG: Alert for $TARGET_IP ($HOSTNAME) is already closed"
                return
                ;;
            *)
                append_opsgenie_message "$(date '+%Y-%m-%d %H:%M:%S') - OPSGENIE: ⚠️ Unexpected alert status '$STATUS' for $TARGET_IP ($HOSTNAME) in close, skipping"
                return
                ;;
        esac
    done
    sleep "$RATE_LIMIT_DELAY"
}

# Function to check a single device with retry logic
check_device() {
    local TARGET_IP=$1
    local HOSTNAME=${IP_HOSTS[$TARGET_IP]}
    local ATTEMPT=1
    local SUCCESS=0

    while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
        sleep $((RANDOM % 3))

        local PING_OUTPUT
        PING_OUTPUT=$(ping -c 20 -i 0.5 -W 2 "$TARGET_IP" 2>&1)

        if [[ $? -eq 0 && ! "$PING_OUTPUT" =~ "Destination Host Unreachable" && ! "$PING_OUTPUT" =~ "Request timed out" && ! "$PING_OUTPUT" =~ "Network is unreachable" ]]; then
            local PACKET_LOSS
            PACKET_LOSS=$(echo "$PING_OUTPUT" | grep -oP '\d+(?=% packet loss)' || echo "100")

            local AVG_LATENCY
            AVG_LATENCY=$(echo "$PING_OUTPUT" | awk -F'/' '/rtt|round-trip/ {print $5}' | sed 's/ms//g' || echo "0")

            local AVG_LATENCY_INT=$(printf "%.0f" "$AVG_LATENCY")
            local PACKET_LOSS_INT=$(printf "%.0f" "$PACKET_LOSS")

            if [[ $PACKET_LOSS_INT -lt 100 && $AVG_LATENCY_INT -le 2000 && $PACKET_LOSS_INT -le 20 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ✅ $TARGET_IP ($HOSTNAME) - SUCCESS: Latency $AVG_LATENCY_INT ms, Packet Loss $PACKET_LOSS_INT% (Attempt $ATTEMPT)" | tee -a "$PING_LOG_FILE"
                SUCCESS=1
                close_opsgenie_alert "$TARGET_IP" "$HOSTNAME"
                break
            fi
        fi

        echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ⚠️ $TARGET_IP ($HOSTNAME) - Temporary failure on attempt $ATTEMPT" | tee -a "$PING_LOG_FILE"

        if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: 🔄 Retrying $TARGET_IP ($HOSTNAME) in $RETRY_DELAY seconds..." | tee -a "$PING_LOG_FILE"
            sleep "$RETRY_DELAY"
        fi
        ((ATTEMPT++))
    done

    if [ $SUCCESS -eq 0 ]; then
        local LAST_PING_OUTPUT=$(ping -c 20 -i 0.5 -W 2 "$TARGET_IP" 2>&1)
        local LAST_PACKET_LOSS=$(echo "$LAST_PING_OUTPUT" | grep -oP '\d+(?=% packet loss)' || echo "100")
        local LAST_AVG_LATENCY=$(echo "$LAST_PING_OUTPUT" | awk -F'/' '/rtt|round-trip/ {print $5}' | sed 's/ms//g' || echo "0")
        local LAST_AVG_LATENCY_INT=$(printf "%.0f" "$LAST_AVG_LATENCY")
        local LAST_PACKET_LOSS_INT=$(printf "%.0f" "$LAST_PACKET_LOSS")

        if [[ $LAST_PACKET_LOSS_INT -eq 100 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ❌ $TARGET_IP ($HOSTNAME) - FAILURE: 100% Packet Loss (Unreachable) after $MAX_ATTEMPTS attempts" | tee -a "$PING_LOG_FILE"
            create_opsgenie_alert "$TARGET_IP" "$HOSTNAME" "Ping Failure: $HOSTNAME ($TARGET_IP) - 100% Packet Loss after $MAX_ATTEMPTS attempts"
        elif [[ $LAST_AVG_LATENCY_INT -gt 2000 || $LAST_PACKET_LOSS_INT -gt 20 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ❌ $TARGET_IP ($HOSTNAME) - FAILURE: High Latency ($LAST_AVG_LATENCY_INT ms) or Packet Loss ($LAST_PACKET_LOSS_INT%) after $MAX_ATTEMPTS attempts" | tee -a "$PING_LOG_FILE"
            create_opsgenie_alert "$TARGET_IP" "$HOSTNAME" "Ping Failure: $HOSTNAME ($TARGET_IP) - High Latency ($LAST_AVG_LATENCY_INT ms) or Packet Loss ($LAST_PACKET_LOSS_INT%) after $MAX_ATTEMPTS attempts"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ❌ $TARGET_IP ($HOSTNAME) - FAILURE: Unreachable or No Response after $MAX_ATTEMPTS attempts" | tee -a "$PING_LOG_FILE"
            create_opsgenie_alert "$TARGET_IP" "$HOSTNAME" "Ping Failure: $HOSTNAME ($TARGET_IP) Unreachable after $MAX_ATTEMPTS attempts"
        fi
    fi
}

# Load hosts from the configuration file
load_hosts

# Start ping tests
echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: 🔄 Running ping tests" | tee -a "$PING_LOG_FILE"

# Run pings in parallel with locking to prevent duplicate IP processing
declare -A PROCESSED_IPS
job_count=0
for IP in "${!IP_HOSTS[@]}"; do
    if [[ -z "${PROCESSED_IPS[$IP]}" ]]; then
        PROCESSED_IPS[$IP]=1
        check_device "$IP" &
        ((job_count++))

        while [[ $(jobs -p | wc -l) -ge $MAX_PARALLEL ]]; do
            wait -n
        done
    fi
done

# Wait for all ping tests to complete
wait
echo "$(date '+%Y-%m-%d %H:%M:%S') - PING: ✅ Ping tests completed" | tee -a "$PING_LOG_FILE"

# Output Opsgenie messages after a newline separator
echo ""
if [ -s "$OPSGENIE_TEMP_FILE" ]; then
    if [ $DEBUG_MODE -eq 1 ]; then
        cat "$OPSGENIE_TEMP_FILE"
    else
        grep -v "OPSGENIE: DEBUG:" "$OPSGENIE_TEMP_FILE"
    fi
fi

# Clean up temporary file
rm -f "$OPSGENIE_TEMP_FILE"
