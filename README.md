# Automated Asset Discovery and Behavioral Drift Monitoring

A bash-based reconnaissance pipeline designed for continuous attack surface monitoring. This tool focuses on stateful tracking, identifying deltas (changes) between scans to highlight new assets and behavioral shifts.

## Pipeline Overview

1. Subdomain Discovery (subfinder)
2. DNS Resolution and IP Tracking (dnsx)
3. HTTP Probing and State Analysis (httpx)
4. Visual Reconnaissance (gowitness)

## Key Features

* Behavioral Drift Detection: Persists historical data to detect changes in HTTP status codes, page titles, and DNS records.
* High-Value Alerts: Specifically flags transitions from restricted states (401/403) to open states (200).
* Heartbeat Mode: A rapid revalidation mode that skips discovery and focusing strictly on re-probing known live assets for status changes.
* Stability Hardening: Implements OS-level timeouts, resource limit adjustments (ulimit), and file locking to prevent process hangs and overlapping executions.
* Filtered Notifications: Telegram integration provides clean, markdown reports only when actionable changes are detected.

## Prerequisites

The following tools must be installed and accessible in your system PATH or defined in your environment configuration:

* subfinder
* dnsx
* httpx
* gowitness
* curl, awk, timeout, flock (standard Linux utilities)

## Installation and Setup

1. Clone the repository:
   ```bash
   git clone [https://github.com/yourusername/your-repo.git](https://github.com/yourusername/your-repo.git) /opt/recon
   cd /opt/recon
   chmod +x recon.sh

   ```

2. Create a .env file:
Define your Telegram credentials and optional path overrides.
```bash
TELEGRAM_BOT_TOKEN="your_bot_token"
TELEGRAM_CHAT_ID="your_chat_id"

# Optional: Set this if tools are not in your cron PATH
# GOBIN="/home/username/go/bin"

```


3. Configure Targets:
Add root domains to roots.txt (one per line).

## Usage

### Manual Execution

Run the full discovery and probing pipeline:

```bash
./recon.sh

```

### Heartbeat Mode

Run a rapid revalidation of previously discovered live hosts only:

```bash
REVALIDATE_ONLY=true ./recon.sh

```

## Automation

The script is optimized for cron execution. To run a full discovery daily and a revalidation heartbeat every three hours, you can use the following crontab entries:

```cron
# Full Discovery: Daily at 2:00 AM
0 2 * * * cd /opt/recon && ./recon.sh >> /opt/recon/cron_debug.log 2>&1

# Heartbeat Monitoring: Every 3 hours from 6:00 AM to 9:00 PM
0 6-21/3 * * * cd /opt/recon && REVALIDATE_ONLY=true ./recon.sh >> /opt/recon/cron_debug.log 2>&1

```

## Output Structure

Results are organized by domain within the results directory. Intermediate files are overwritten each run to save space, while previous state files are maintained to facilitate drift detection.

```text
results/[example.com/](https://example.com/)
├── 01_subfinder.txt         # Raw discovered subdomains
├── 02_current_dns.txt       # Current hostname|IP mapping
├── 02_dns_changes.txt       # Detected DNS/IP shifts
├── 03_httpx-live.txt        # Currently active HTTP targets
├── 03_status_changes.txt    # HTTP status code deltas
├── 03_fresh.txt             # Assets seen for the first time
└── 04_gowitness-screens/    # Screenshots of fresh assets
```
