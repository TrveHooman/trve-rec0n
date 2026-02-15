#!/usr/bin/env bash
# Automated Asset Discovery & Behavioral Drift Monitoring
set -euo pipefail

# ---------------------
# Configuration
# ---------------------
ulimit -n 100000

WORKDIR="${WORKDIR:-$(pwd)}"
RESULTS_DIR="${RESULTS_DIR:-$WORKDIR/results}"
ROOTS_FILE="${ROOTS_FILE:-$WORKDIR/roots.txt}"
LOGFILE="${LOGFILE:-$WORKDIR/recon.log}"
LOCKFILE="${LOCKFILE:-/tmp/recon_monitor.lock}"

if [ -f "${WORKDIR}/.env" ]; then
  set -a; source "${WORKDIR}/.env"; set +a
fi

GOBIN="${GOBIN:-$HOME/go/bin}"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${GOBIN}"

DNS_THREADS="${DNS_THREADS:-20}"
HTTP_THREADS="${HTTP_THREADS:-30}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-10}"
HTTPX_OS_TIMEOUT="${HTTPX_OS_TIMEOUT:-60m}"
GOWITNESS_TIMEOUT="${GOWITNESS_TIMEOUT:-15}"

RUN_ID="$(date -u +%Y%m%d_%H%M%S)"
REVALIDATE_ONLY="${REVALIDATE_ONLY:-false}"

# ---------------------
# Helpers
# ---------------------
log(){ echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [recon] $*" | tee -a "${LOGFILE}"; }
safe_mkdir(){ mkdir -p "$1" || true; }
root_dir(){ echo "${RESULTS_DIR}/$1"; }

check_deps(){
  local missing=()
  for tool in subfinder dnsx httpx gowitness curl flock; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    log "CRITICAL: missing tools in PATH: ${missing[*]}"; exit 1
  fi
}

# ---------------------
# Core Stages
# ---------------------

run_discovery(){
  local root="$1"; local rd="$2"
  log "[$root] Discovery: running subfinder..."
  local out="$rd/01_subfinder.txt"
  safe_mkdir "$rd"
  subfinder -d "$root" -silent -o "$out" || true
  [ -s "$out" ] && sort -u "$out" -o "$out" || true
}

run_dnsx(){
  local root="$1"; local rd="$2"
  log "[$root] DNS resolve: dnsx..."
  local out="$rd/02_dnsx.txt"
  local c_dns="$rd/02_current_dns.txt"
  local p_dns="$rd/02_previous_dns.txt"
  safe_mkdir "$rd"
  
  dnsx -l "$rd/01_subfinder.txt" -resp -a -cname -silent -t "$DNS_THREADS" -o "$out" || true
  
  if [ -s "$out" ]; then
    awk '{print $1}' "$out" | sort -u > "${out}.tmp" && mv "${out}.tmp" "$out"
    awk '{host=$1; ip=""; if(match($0, /\[([0-9\.]+)\]/)) {ip=substr($0, RSTART+1, RLENGTH-2); print host "|" ip}}' "$out" > "$c_dns"
  else
    : > "$c_dns"
  fi

  [ -f "$p_dns" ] || : > "$p_dns"
  awk -F'|' 'NR==FNR { old[$1]=$2; next } { if ($1 in old && old[$1] != $2) print $1 "|" old[$1] "|" $2 }' "$p_dns" "$c_dns" > "$rd/02_dns_changes.txt"
  cp -f "$c_dns" "$p_dns" || true
}

run_httpx(){
  local root="$1"; local rd="$2"
  log "[$root] Probing HTTP: running httpx..."
  local in_file="$rd/03_httpx-input.txt"
  local live_file="$rd/03_httpx-live.txt"
  local prev_live="$rd/03_previous_live.txt"
  local fresh_file="$rd/03_fresh.txt"
  
  if [ "${REVALIDATE_ONLY}" = "true" ]; then
    cp -f "$prev_live" "$in_file" || { log "ERROR: No 03_previous_live.txt found for revalidation."; exit 3; }
  else
    awk '{print "https://" $0 "\nhttp://" $0}' "$rd/02_dnsx.txt" | sort -u > "$in_file"
  fi

  local out_raw="$rd/03_httpx-raw.txt"
  local c_status="$rd/03_current_status.txt"; local c_title="$rd/03_current_title.txt"

  timeout "${HTTPX_OS_TIMEOUT}" httpx -l "$in_file" -silent -no-color -sc -title \
    -threads "$HTTP_THREADS" -timeout "$HTTP_TIMEOUT" -retries 1 -max-host-error 2 -o "$out_raw" || log "WARN: httpx timed out"

  : > "$c_status"; : > "$c_title"
  if [ -s "$out_raw" ]; then
    awk -v f_stat="$c_status" -v f_title="$c_title" '{
      url = $1; status = "0"; title = "";
      for(i=2; i<=NF; i++) {
        if ($i ~ /^\[[0-9]{3}\]$/) { status = substr($i, 2, 3); }
        else { title = title (title=="" ? "" : " ") $i; }
      }
      gsub(/^\[|\]$/, "", title);
      if (status != "0" && status != "") print url "|" status > f_stat
      if (title != "") print url "|" title > f_title
    }' "$out_raw" || true
  fi

  awk -F'|' '$2 != "404" {print $1}' "$c_status" | sort -u > "$live_file" || true

  local p_status="$rd/03_previous_status.txt"; local p_title="$rd/03_previous_title.txt"
  for f in "$p_status" "$p_title"; do [ -f "$f" ] || : > "$f"; done

  awk -F'|' 'NR==FNR { old[$1]=$2; next } { if ($1 in old && old[$1] != $2) print $1 "|" old[$1] "|" $2 }' "$p_status" "$c_status" > "$rd/03_status_changes.txt"
  awk -F'|' 'NR==FNR { old[$1]=$2; next } { if ($1 in old && old[$1] != $2) print $1 "|" old[$1] "|" $2 }' "$p_title" "$c_title" > "$rd/03_title_changes.txt"

  cp -f "$c_status" "$p_status"; cp -f "$c_title" "$p_title"

  [ -f "$prev_live" ] || : > "$prev_live"
  grep -Fxv -f "$prev_live" "$live_file" | sort -u > "$fresh_file" || true
  
  if [ "${REVALIDATE_ONLY}" != "true" ] && [ -s "$fresh_file" ]; then
    run_gowitness "$root" "$rd" "$fresh_file"
  fi
  cp -f "$live_file" "$prev_live"
}

run_gowitness(){
  local root="$1"; local rd="$2"; local freshfile="$3"
  local outdir="$rd/04_gowitness-screens"
  safe_mkdir "$outdir"
  rm -rf "${outdir:?}"/* 2>/dev/null || true
  gowitness scan file -f "$freshfile" --screenshot-path "$outdir" --timeout "${GOWITNESS_TIMEOUT}" || true
}

send_telegram(){
  local root="$1"; local rd="$2"
  [ -z "${TELEGRAM_BOT_TOKEN:-}" ] && return 0
  get_count(){ [ -f "$1" ] && wc -l < "$1" | tr -d '[:space:]' || echo 0; }
  local live_total=$(get_count "$rd/03_httpx-live.txt")
  local fresh_count=$(get_count "$rd/03_fresh.txt")
  local stat_chgs=$(get_count "$rd/03_status_changes.txt")
  local title_chgs=$(get_count "$rd/03_title_changes.txt")
  local dns_chgs=$(get_count "$rd/02_dns_changes.txt")
  local high_val_chgs=$(grep -E '\|(401|403)\|200$' "$rd/03_status_changes.txt" 2>/dev/null | wc -l | tr -d '[:space:]')

  if [ "$fresh_count" -eq 0 ] && [ "$stat_chgs" -eq 0 ] && [ "$title_chgs" -eq 0 ] && [ "$dns_chgs" -eq 0 ]; then
    return 0
  fi

  local mode_icon="🚀"; local mode_text="Full Discovery"
  if [ "${REVALIDATE_ONLY}" = "true" ]; then mode_icon="🛡️"; mode_text="Revalidation"; fi

  printf -v msg "✨ *Recon Update:* \`%s\`\n%s *Mode:* %s\n\n📈 *Total Live:* %s\n🆕 *Fresh Hosts:* %s\n\n⚠️ *Changes:*\n- Status: %s\n  └─ 🔓 403/401 -> 200: %s\n- Title: %s\n- DNS: %s" \
    "${root}" "${mode_icon}" "${mode_text}" "${live_total}" "${fresh_count}" "${stat_chgs}" "${high_val_chgs}" "${title_chgs}" "${dns_chgs}"

  if [ "$high_val_chgs" -gt 0 ]; then
    msg+=$'\n\n🔥 *High-Value Status Changes:*\n'$(grep -E '\|(401|403)\|200$' "$rd/03_status_changes.txt" | head -n 5)
  fi

  curl -sS --fail "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "parse_mode=Markdown" --data-urlencode "text=${msg}" >/dev/null 2>&1 || true
}

main(){
  exec 9>"${LOCKFILE}"
  flock -n 9 || { log "Locked; exiting."; exit 0; }
  check_deps
  mapfile -t ROOTS < "${ROOTS_FILE}"
  log "=== Start Run ${RUN_ID} (Revalidate: ${REVALIDATE_ONLY}) ==="
  for root in "${ROOTS[@]}"; do
    root=$(echo "$root" | xargs); [ -z "$root" ] && continue
    rd="$(root_dir "$root")"; safe_mkdir "$rd"
    if [ "${REVALIDATE_ONLY}" != "true" ]; then run_discovery "$root" "$rd"; run_dnsx "$root" "$rd"; fi
    run_httpx "$root" "$rd"
    send_telegram "$root" "$rd"
  done
  log "=== End Run ${RUN_ID} ==="
}

main "$@"
