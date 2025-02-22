Ping Monitoring Script with Opsgenie Integration
Overview

This Bash script is designed to monitor the availability of network devices by pinging their IP addresses and integrating with Opsgenie for alert management. It checks device responsiveness, logs the results, and creates or closes alerts in Opsgenie based on the ping outcomes. The script supports parallel execution for efficiency and includes retry logic to handle temporary failures and API rate limits.
Features

    Device Monitoring: Pings a list of IP addresses to check availability, latency, and packet loss.
    Opsgenie Integration: Creates P3 priority alerts for unreachable devices and auto-closes them when devices recover.
    Parallel Processing: Runs up to 20 ping tests concurrently to optimize performance.
    Retry Logic: Retries failed pings up to 4 times and handles Opsgenie API rate limits with delays.
    Logging: Maintains detailed logs for ping results and Opsgenie actions with timestamps and status emojis.
    Debug Mode: Optional --debug flag to display detailed Opsgenie alert state information.
    Configuration: Loads IP-to-hostname mappings from a hosts.conf file.

How It Works

    Initialization:
        Loads IP-to-hostname mappings from hosts.conf into an associative array.
        Sets constants for ping attempts (4), parallel jobs (20), retry delays, and Opsgenie API details.
    Ping Testing:
        For each IP:
            Sends 20 ping packets with a 0.5s interval and 2s timeout.
            Evaluates success based on:
                Packet loss < 100%
                Average latency ≤ 2000ms
                Packet loss ≤ 20%
            Retries up to 4 times with a 10s delay between attempts if initial checks fail.
    Opsgenie Alert Management:
        Alert Creation: If a device fails all ping attempts, creates a P3 priority alert in Opsgenie with details of the failure (e.g., 100% packet loss or high latency).
        Alert Closure: If a previously failed device responds successfully, closes the corresponding Opsgenie alert.
        Checks existing alert status to avoid duplicates and respects API rate limits with retries.
    Logging and Output:
        Logs ping results to ping_results.log with success (✅), failure (❌), or warning (⚠️) indicators.
        Logs Opsgenie actions to opsgenie_alerts.log with success (🚨, ✅), warning (⚠️), or debug (DEBUG:) messages.
        Displays a summary of Opsgenie actions at the end, filtering out debug messages unless --debug is used.

Configuration

    hosts.conf: A file containing IP-to-hostname mappings in the format IP=HOSTNAME. Example:
    text

    192.168.1.1=router
    192.168.1.2=server1
    Constants: Hardcoded in the script (e.g., MAX_ATTEMPTS, OPSGENIE_API_KEY). Modify these directly in the script if needed.

Dependencies

    bash: Script interpreter
    ping: For network testing
    curl: For Opsgenie API calls
    jq (optional): For cleaner JSON parsing of Opsgenie responses (falls back to grep if unavailable)

Usage

    Prepare the Environment:
        Ensure hosts.conf exists in the same directory as the script.
        Verify network access to the target IPs and the Opsgenie API (https://api.eu.opsgenie.com).
    Run the Script:
        Normal mode:
        bash

chmod +x ping_monitor.sh
./ping_monitor.sh
Debug mode (shows detailed Opsgenie alert state info):
bash

        ./ping_monitor.sh --debug
    Output:
        Logs are written to ping_results.log and opsgenie_alerts.log.
        Console output shows real-time ping results and a summary of Opsgenie actions.

Example Output

    Normal Mode:
    text

2025-02-22 10:00:00 - INFO: Loaded 2 hosts from 'hosts.conf'
2025-02-22 10:00:00 - PING: 🔄 Running ping tests
2025-02-22 10:00:05 - PING: ✅ 192.168.1.1 (router) - SUCCESS: Latency 5 ms, Packet Loss 0% (Attempt 1)
2025-02-22 10:00:20 - PING: ❌ 192.168.1.2 (server1) - FAILURE: 100% Packet Loss (Unreachable) after 4 attempts
2025-02-22 10:00:20 - OPSGENIE: 🚨 Alert sent to Opsgenie for 192.168.1.2 (server1)
2025-02-22 10:00:25 - PING: ✅ Ping tests completed
Debug Mode:
text

    2025-02-22 10:00:00 - INFO: Loaded 2 hosts from 'hosts.conf'
    2025-02-22 10:00:00 - PING: 🔄 Running ping tests
    2025-02-22 10:00:05 - PING: ✅ 192.168.1.1 (router) - SUCCESS: Latency 5 ms, Packet Loss 0% (Attempt 1)
    2025-02-22 10:00:05 - OPSGENIE: DEBUG: No alerts found for 192.168.1.1 (router) in close
    2025-02-22 10:00:20 - PING: ❌ 192.168.1.2 (server1) - FAILURE: 100% Packet Loss (Unreachable) after 4 attempts
    2025-02-22 10:00:20 - OPSGENIE: DEBUG: No active alert for 192.168.1.2 (server1), proceeding with creation
    2025-02-22 10:00:20 - OPSGENIE: 🚨 Alert sent to Opsgenie for 192.168.1.2 (server1)
    2025-02-22 10:00:25 - PING: ✅ Ping tests completed

Notes

    Security: The Opsgenie API key is hardcoded. For production use, consider storing it in an environment variable or secure file.
    Customization: Adjust thresholds (e.g., latency, packet loss) or ping parameters by editing the script.
    Scalability: The script handles up to 20 parallel jobs; increase MAX_PARALLEL for larger host lists, but beware of system resource limits.

License

[Specify your license here, e.g., MIT, GPL, etc.]
