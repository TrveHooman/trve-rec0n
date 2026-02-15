# Automated Asset Discovery & Behavioral Drift Monitoring

A robust, bash-based reconnaissance pipeline built for continuous attack surface monitoring. Instead of endlessly dumping raw data, this tool focuses on **deltas**—tracking behavioral changes across your targets and alerting you only when actionable shifts occur.

## Core Pipeline
```text
roots.txt 
   │
   ├─► [01] Subdomain Discovery (subfinder)
   ├─► [02] DNS Resolution & IP Drift (dnsx)
   ├─► [03] Live Host Probing & State Tracking (httpx)
   └─► [04] Visual Recon on Fresh Hosts (gowitness)

```

## Key Features

* **Stateful Drift Detection:** Persists historical data to detect and report changes in HTTP Status Codes, Page Titles, TLS Certificates, and DNS/IP resolutions.
* **High-Value Alerts:** Explicitly flags critical transitions (e.g., a `403 Forbidden` or `401 Unauthorized` endpoint suddenly returning `200 OK`).
* **Heartbeat Mode (`REVALIDATE_ONLY`):** Bypasses heavy discovery phases to rapidly re-probe known infrastructure for immediate state changes.
* **Tarpit Resilience:** Hardened with OS-level timeouts (`timeout 30m`), file descriptor limits (`ulimit -n`), and mechanisms to easily blacklist connection-hanging IPs.
* **Zero-Spam Telegram Integration:** Delivers clean, Markdown-formatted delta reports. Fails silently if no changes or fresh hosts are detected.
* **Flat File Structure:** Overwrites intermediate files per run, keeping your `results/` directory clean while maintaining historical state via prefixed tracking files.

## Prerequisites

Ensure the following tools are installed and accessible in your system's `$PATH` (or specifically in `~/go/bin`):

* [subfinder](https://github.com/projectdiscovery/subfinder)
* [dnsx](https://github.com/projectdiscovery/dnsx)
* [httpx](https://github.com/projectdiscovery/httpx)
* [gowitness](https://github.com/sensepost/gowitness)

*Standard Linux utilities required: `curl`, `awk`, `timeout`, `flock`.*

## Installation & Setup

1. **Clone the repository:**
```bash
git clone [https://github.com/TrveHooman/trve-rec0n.git](https://github.com/TrveHooman/trve-rec0n.git) /opt/recon
cd /opt/recon
chmod +x recon.sh

```

2. **Configure Environment Variables:**
Create a `.env` file in the root directory:
```env
TELEGRAM_BOT_TOKEN="your_telegram_bot_token"
TELEGRAM_CHAT_ID="your_telegram_chat_id"

# Optional Overrides
# DNS_THREADS="20"
# HTTP_THREADS="30"

```


3. **Define Targets:**
Add your root domains to `roots.txt` (one per line):
```text
example.com
target.io

```



## Usage

### Manual Full Run

Executes the entire pipeline from discovery to screenshots.

```bash
./recon.sh

```

### Manual Revalidation (Heartbeat)

Skips `subfinder`, `dnsx`, and `gowitness`. Strictly re-probes previously discovered live hosts to detect status/title changes.

```bash
REVALIDATE_ONLY=true ./recon.sh

```

## Automation (Cron)

This script is designed for hands-off automation. Run a full discovery daily, and a fast revalidation heartbeat every few hours.

Add the following to your crontab (`crontab -e`):

```cron
# Full Discovery: Every day at 2:00 AM
0 2 * * * cd /opt/recon && ./recon.sh >> /opt/recon/cron_debug.log 2>&1

# Heartbeat Monitoring: Every 3 hours from 6:00 AM to 9:00 PM
0 6-21/3 * * * cd /opt/recon && REVALIDATE_ONLY=true ./recon.sh >> /opt/recon/cron_debug.log 2>&1

```

## Output Structure

Results are stored in `./results/<domain>/`. The directory uses stable, prefixed filenames that overwrite on each run.

```text
results/[example.com/](https://example.com/)
├── 01_subfinder.txt
├── 02_dnsx.txt
├── 02_current_dns.txt
├── 02_previous_dns.txt
├── 02_dns_changes.txt
├── 03_httpx-live.txt
├── 03_current_status.txt
├── 03_previous_status.txt
├── 03_status_changes.txt
├── 03_fresh.txt
└── 04_gowitness-screens/
    └── [screenshots...]
```
