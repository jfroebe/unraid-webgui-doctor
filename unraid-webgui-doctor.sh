#!/bin/bash
# Unraid WebGUI diagnosis and explicitly confirmed component repairs.
# Copyright (C) 2026 Jason Froebe
# SPDX-License-Identifier: GPL-3.0-only
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the
# Free Software Foundation, version 3.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. See the LICENSE file in this repository.
# If not, see <https://www.gnu.org/licenses/>.
#
# Diagnose first, correlate observations, then offer narrowly scoped repairs.
# A process existing is not proof of service health; likewise, an HTTP failure
# alone is not proof that restarting PHP-FPM is the right remedy.
#
# Privacy is based on omission: raw configuration, process arguments and logs
# are used locally where needed, but only selected scalars and interpretations
# reach console/report output. Never trace this script with bash -x when sharing
# output, because shell tracing bypasses that reporting boundary.
set -euo pipefail
(( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 2) )) \
  || { >&2 printf 'Requires Bash 5.2 or newer.\n'; exit 2; }
shopt -s inherit_errexit nullglob
# Use fixed system directories before invoking external programs so an inherited
# PATH cannot select a same-named tool from a writable working directory.
# A stable locale also makes command-output parsing less dependent on host settings.
declare -rx PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
declare -rx LC_ALL=C
declare -r VERSION=1.0.0 SCRIPT_NAME=unraid-webgui-doctor.sh
# Live paths are rooted at the actual host. The test suite instruments a private
# copy of this constant; there is deliberately no runtime fixture-root override.
declare -r SYSTEM_ROOT=''
# Keep configuration flags separate from observations. Observation variables are
# refreshed by component checks and later correlated before repairs are offered.
# ROWS holds structured findings; ACTIONS contains only currently eligible repairs.
declare -i VERBOSE=1 EXPANDED=0 REPORT=0 NO_REPAIR=0 INTERACTIVE=0 RESULT=0
declare -i NGINX=0 PHP=0 EMHTTP=0 CONFIG_OK=0 HTTP_OK=0 HTTP_BAD=0
declare -i NGINX_MASTER=0 NGINX_WORKERS=0 HTTP_BACKEND=0
declare -i PROCESS_KNOWN=1
declare -i RESOURCE_BAD=0
declare -- REPORT_DIR=/tmp REPORT_FILE='' WORK_DIR='' OS_VERSION=unknown
declare -- CONFIG_FILE='' SNI_HOST=localhost
declare -a ROWS=() PORTS=() SCHEMES=() ACTIONS=()
declare -A SEEN_PORTS=()

# Operational messages use stderr so stdout remains usable for help, version,
# and report-path data. Quiet mode suppresses information, not warnings or errors.
_msg() { >&2 printf '%s: %s\n' "$SCRIPT_NAME" "$*"; }
info() { ((VERBOSE)) || return 0; _msg "$@"; }
warn() { _msg "WARNING: $*"; }
error() { _msg "ERROR: $*"; }
die() { error "${@:2}"; exit "$1"; }

# Help/version paths run before host and privilege checks, allowing the interface
# to be inspected without root access or a functioning Unraid installation.
show_help() {
  cat <<'HELP'
Unraid WebGUI Doctor — diagnose first, confirm before repair.
Usage: bash unraid-webgui-doctor.sh [OPTIONS]
  --diagnose-only     Never offer repairs (also --no-fix)
  --interactive       Offer evidence-supported repairs on a terminal
  --report            Save a private TSV report; never repair
  --report-dir DIR    Report parent directory (default /tmp); implies --report
  -v, --verbose       Expanded diagnostic evidence
  -q, --quiet         Suppress nonessential output
  --no-color          Plain output (the default)
  -V, --version       Print version
  -h, --help          Print help
Default: interactive on a terminal, diagnosis only otherwise.
Examples:
  bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --diagnose-only
  bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --interactive
  bash /boot/config/custom/scripts/unraid-webgui-doctor.sh --report --verbose
Reports omit raw logs, configurations, command lines, hostnames and addresses.
Review reports privately before sharing. /tmp reports are lost at reboot.
Exit: 0 no failed checks; 1 failed checks/repair; 2 unsupported Bash;
3 unsupported host; 5 report I/O; 13 privileges; 18 required tool missing;
22 invalid arguments; 130 interrupt; 143 termination.
Unknown checks are explicitly reported; exit 0 is not full qualification.
HELP
}

# WORK_DIR can contain raw sensitive captures. Remove it on normal or trapped
# exits, preserving the caller-visible status instead of hiding a failed diagnosis.
# Reports live outside this scratch directory and intentionally survive cleanup.
cleanup() {
  local -i status=$1
  trap - EXIT INT TERM
  if [[ -n $WORK_DIR ]]; then
    rm -rf -- "$WORK_DIR" || error 'Could not remove private temporary diagnostic files.'
  fi
  exit "$status"
}

# Stop scheduling additional checks or repairs after an interrupt. Already written
# report rows provide a partial audit; this does not undo an approved service action.
# A shell trap may wait for a foreground command to return before it can execute.
interrupted() {
  local -i status=$1
  # A second signal forces termination even if cleanup is delayed by storage.
  trap 'exit 130' INT
  trap 'exit 143' TERM
  warn 'Interrupted; no further checks or repairs will run. Completed report rows are retained.'
  exit "$status"
}

# One reporting boundary serves both human interpretation and TSV records.
# Callers must supply fixed descriptions or validated scalars, never raw log lines,
# command output or configuration. FAILED changes the assessment exit status;
# WARNING and UNKNOWN remain visible without pretending to prove a failure.
finding() {
  local -- component=$1 status=$2 severity=$3 evidence=$4 cause=$5 confidence=$6 next=$7 repair=$8
  local -- stamp='' row=''
  printf -v stamp '%(%FT%T%z)T' -1
  printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$stamp" "$component" "$status" "$severity" "$evidence" "$cause" "$confidence" "$next" "$repair"
  ROWS+=("$row")
  if [[ $status == FAILED ]]; then RESULT=1; fi
  if ((VERBOSE)) || [[ $status == FAILED || $status == WARNING ]]; then
    _msg "[$status] $component: $evidence"
    if ((EXPANDED)); then _msg "Cause: $cause; confidence: $confidence; next: $next; repair: $repair"; fi
  fi
  if [[ -n $REPORT_FILE ]]; then
    printf '%s\n' "${ROWS[-1]}" >> "$REPORT_FILE" || die 5 'Cannot append private report.'
  fi
  return 0
}

# Optional tools are discovered at their point of use. Diagnosis never installs
# packages or depends on downloading a recovery tool while the WebGUI is down.
has_tool() { command -v "$1" &>/dev/null; }

# Exact process-name matching avoids treating an unrelated command containing a
# service name as evidence of health. A failed inventory is UNKNOWN, not zero:
# confusing an unavailable measurement with an absent service could justify a bad repair.
process_count() {
  local -- name=$1 text=''
  if text=$(ps -eo comm= 2>/dev/null); then
    awk -v name="$name" '$0 ~ "^[[:space:]]*" name "[[:space:]]*$" {n++} END {print n+0}' <<< "$text"
  else
    printf '%s\n' unknown
  fi
}

# Reporting is opt-in for diagnosis and mandatory before an approved repair.
# A private directory and unpredictable filename reduce accidental disclosure and
# unsafe reuse of a pre-existing path. Refuse symlink/ownership surprises rather
# than changing permissions on a directory controlled by another user.
# Only generated reports are pruned; arbitrary files in the parent are untouched.
prepare_report() {
  local -- directory='' old='' owner=''
  local -a reports=()
  ((REPORT || ${1:-0})) || return 0
  [[ $REPORT_DIR == /* && $REPORT_DIR != *$'\n'* && $REPORT_DIR != *$'\t'* ]] \
    || die 22 'Report directory must be an absolute path without tabs or newlines.'
  directory=$REPORT_DIR/unraid-webgui-doctor
  [[ ! -L $directory ]] || die 13 'Report directory must not be a symbolic link.'
  mkdir -p -- "$directory" || die 5 'Cannot create private report directory.'
  owner=$(stat -c '%u' -- "$directory") || die 5 'Cannot verify report directory ownership.'
  [[ $owner == "$EUID" ]] || die 13 'Report directory must be owned by the current administrator.'
  chmod -- 700 "$directory" || die 5 'Cannot secure report directory.'
  REPORT_FILE=$(mktemp "$directory/report.XXXXXXXX.tsv") || die 5 'Cannot create report.'
  printf 'timestamp\tcomponent\tstatus\tseverity\tevidence\tcause\tconfidence\tnext_action\trepair\n' \
    > "$REPORT_FILE" || die 5 'Cannot write report header.'
  if ((${#ROWS[@]})); then
    printf '%s\n' "${ROWS[@]}" >> "$REPORT_FILE" || die 5 'Cannot write earlier findings.'
  fi
  # Keep at most ten reports, newest first; directory is private and names are generated.
  mapfile -t reports < <(find "$directory" -maxdepth 1 -type f -name 'report.*.tsv' -printf '%T@ %p\n' | sort -nr)
  for old in "${reports[@]:10}"; do
    old=${old#* }
    rm -- "$old" || die 5 'Cannot prune old diagnostic report.'
  done
  warn 'Report contains operational information. Review privately before public sharing.'
  # The path is intentionally not echoed: a custom parent can identify the deployment.
  printf '%s\n' "$REPORT_FILE"
  return 0
}

# Resource pressure can mimic broken services: exhausted log space, inodes or
# memory may prevent workers from starting or replying. Observe before restarting.
# Parse only numeric version/resource fields so identifiers from system output
# cannot accidentally enter a public diagnostic report. Thresholds are heuristics.
system_checks() {
  local -- version='' kernel='' uptime='' memory='' path='' capacity='' inodes=''
  if [[ -r $SYSTEM_ROOT/etc/unraid-version ]]; then
    version=$(< "$SYSTEM_ROOT/etc/unraid-version")
    if [[ $version =~ version=[\"\']?([0-9]+\.[0-9]+(\.[0-9]+)?) ]]; then
      OS_VERSION=${BASH_REMATCH[1]}
    fi
  fi
  kernel=$(uname -r) || kernel=unknown
  [[ $kernel =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] && kernel=${BASH_REMATCH[0]} || kernel=unknown
  uptime=$(awk '{printf "%d",$1}' "$SYSTEM_ROOT/proc/uptime") || uptime=unknown
  [[ $uptime =~ ^[0-9]+$ ]] || uptime=unknown
  version="Unraid=$OS_VERSION kernel=$kernel uptime_seconds=$uptime"
  finding system HEALTHY info "$version Bash=${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}" \
    'System identification excludes hostname and network identity' high 'Continue component diagnosis' no
  memory=$(awk '/^MemAvailable:/ {print $2}' "$SYSTEM_ROOT/proc/meminfo") || memory=''
  if [[ $memory =~ ^[0-9]{1,12}$ ]]; then
    if ((10#$memory < 131072)); then
      RESOURCE_BAD=1
      finding memory WARNING high "Available_KiB=$memory" 'Memory pressure may stall management services' \
        medium 'Investigate memory consumers privately; do not reboot automatically' no
    else
      finding memory HEALTHY info "Available_KiB=$memory" 'No low-memory threshold crossed' medium 'None' no
    fi
  else
    finding memory UNKNOWN warning 'Memory availability could not be parsed' unknown low 'Inspect memory privately' no
  fi
  for path in / /run /var/log /boot; do
    capacity=$(df -Pk -- "$SYSTEM_ROOT$path" 2>/dev/null | awk 'NR==2 {print $5}') || capacity=''
    inodes=$(df -Pi -- "$SYSTEM_ROOT$path" 2>/dev/null | awk 'NR==2 {print $5}') || inodes=''
    if [[ $capacity =~ ^([0-9]{1,3})%$ ]]; then
      capacity=${BASH_REMATCH[1]}
      if ((10#$capacity >= 95)); then
        RESOURCE_BAD=1
        finding storage FAILED high "$path capacity_percent=$capacity" 'Filesystem capacity pressure' \
          high 'Free space only after identifying safe data to remove' no
      else
        finding storage HEALTHY info "$path capacity_percent=$capacity" 'No capacity threshold crossed' medium None no
      fi
    else
      finding storage UNKNOWN warning "$path capacity unavailable" unknown low 'Check mount availability' no
    fi
    if [[ $inodes =~ ^([0-9]{1,3})%$ ]]; then
      inodes=${BASH_REMATCH[1]}
      if ((10#$inodes >= 95)); then
        RESOURCE_BAD=1
        finding inodes FAILED high "$path inode_percent=$inodes" 'Inode pressure' high 'Inspect filesystem privately' no
      fi
    else
      finding inodes UNKNOWN info "$path inode measurement unavailable" 'Filesystem may not expose inodes' low None no
    fi
  done
  return 0
}

# Track nginx, PHP-FPM and management-daemon observations independently. Missing
# management processes require version-specific investigation, not an assumed
# restart command. Presence is deliberately described as a limited observation.
check_processes() {
  local -- component='' count=''
  NGINX=0 PHP=0 EMHTTP=0
  PROCESS_KNOWN=1
  for component in nginx php-fpm emhttpd; do
    count=$(process_count "$component")
    if [[ $count =~ ^[0-9]+$ ]] && ((count > 0)); then
      case $component in
        nginx) NGINX=1 ;;
        php-fpm) PHP=1 ;;
        emhttpd) EMHTTP=1 ;;
        *) return 1 ;;
      esac
      finding "$component" HEALTHY info "process_count=$count" 'Process presence only; responsiveness unproven' \
        medium 'Correlate with listeners and HTTP probes' no
    elif [[ $count == unknown ]]; then
      PROCESS_KNOWN=0
      finding "$component" UNKNOWN warning 'Process inventory unavailable' \
        unknown low 'Inspect process table privately' no
    else
      finding "$component" FAILED high 'No exact-name process detected' 'Service may be stopped or renamed' \
        medium 'Correlate with configuration and service layout' conditional
    fi
  done
  if [[ ! -r $SYSTEM_ROOT/usr/local/emhttp/webGui/template.php ]]; then
    finding management_files WARNING high 'WebGUI template missing or unreadable' \
      'Incomplete or different service layout' \
      medium 'Inspect installed Unraid files; management restart is manual' no
  fi
  return 0
}

# Master/worker titles provide more context than a single service PID, but their
# format is implementation-dependent. Compare simple pool limits with observed
# workers only as a saturation clue: this cannot distinguish busy from idle workers
# or establish which request, plugin or backend caused a delay.
worker_checks() {
  local -- inventory='' counts='' php_master='' php_workers='' config='' maximum=''
  inventory=$(ps -eo args= 2>/dev/null) || {
    finding workers UNKNOWN info 'Worker inventory unavailable' unknown low 'Inspect processes privately' no
    return 0
  }
  counts=$(awk '
    /^nginx: master process/ {nm++}
    /^nginx: worker process/ {nw++}
    /^php-fpm: master process/ {pm++}
    /^php-fpm: pool / {pw++}
    END {print nm+0,nw+0,pm+0,pw+0}' <<< "$inventory") || counts='0 0 0 0'
  read -r NGINX_MASTER NGINX_WORKERS php_master php_workers <<< "$counts"
  finding workers UNKNOWN info \
    "nginx_master=$NGINX_MASTER nginx_workers=$NGINX_WORKERS php_master=$php_master php_workers=$php_workers" \
    'Process titles are layout-dependent; worker count alone does not establish responsiveness' \
    low 'Correlate pool limits and recent max_children or timeout errors' no
  for config in /etc/php-fpm.d/www.conf /etc/php-fpm.conf; do
    [[ -r $SYSTEM_ROOT$config ]] || continue
    maximum=$(awk -F= '/^[[:space:]]*pm.max_children[[:space:]]*=/ {
      gsub(/[[:space:]]/,"",$2); print $2; exit}' "$SYSTEM_ROOT$config") || maximum=''
    if [[ $maximum =~ ^[1-9][0-9]{0,5}$ ]]; then
      if ((php_workers >= maximum)); then
        finding php_pool WARNING medium "observed_workers=$php_workers max_children=$maximum" \
          'Possible worker saturation; idle and active workers are not distinguished' \
          low 'Inspect recent pool logs and slow requests before changing limits' no
      else
        finding php_pool HEALTHY info "observed_workers=$php_workers max_children=$maximum" \
          'Observed count below configured limit; request health unproven' low None no
      fi
      break
    fi
  done
  return 0
}

# Executable versions help explain layout differences. Keep only a recognized
# numeric version; discard vendor banners and other output that may identify a host.
# Bounds prevent a broken executable from indefinitely blocking basic diagnosis.
component_versions() {
  local -- component='' output='' number=''
  for component in nginx php-fpm; do
    has_tool "$component" || continue
    if output=$(timeout -k 2 3 "$component" -v 2>&1); then
      if [[ $output =~ (nginx/|PHP[[:space:]])([0-9]+\.[0-9]+\.[0-9]+) ]]; then
        number=${BASH_REMATCH[2]}
        finding versions HEALTHY info "$component=$number" \
          'Sanitized executable version; vendor suffix omitted' high None no
      else
        finding versions UNKNOWN info "$component version not recognized" unknown low None no
      fi
    else
      finding versions UNKNOWN info "$component version query failed or timed out" unknown low None no
    fi
  done
  return 0
}

# The effective nginx configuration is more reliable than assuming ports 80/443
# or guessing include files. nginx -T also tests referenced configuration resources.
# Keep its raw output private, then extract a bounded set of numeric listeners,
# one suitable Host/SNI name and one simple FastCGI Unix socket. Unsupported layouts
# stay explicit limitations rather than prompting guessed repair commands.
nginx_config() {
  local -- line='' port='' scheme='' host='' socket='' socket_mode=''
  local -a endpoints=()
  CONFIG_OK=0
  PORTS=() SCHEMES=() SEEN_PORTS=()
  CONFIG_FILE=$WORK_DIR/nginx.conf
  if ! has_tool nginx; then
    finding nginx_config UNKNOWN warning 'nginx executable unavailable' unknown low 'Verify installed service layout' no
    return 0
  fi
  # Raw config can contain secrets; it never goes to console or report.
  if timeout -k 2 8 nginx -T > "$CONFIG_FILE" 2> "$WORK_DIR/nginx-error"; then
    CONFIG_OK=1
    finding nginx_config HEALTHY info 'nginx configuration validation passed' 'Syntax and referenced files accepted' \
      high 'Continue endpoint checks' conditional
  else

    finding nginx_config FAILED high 'nginx configuration validation failed or timed out; raw output withheld' \
      'Syntax, binding, certificate or file access problem; inspect nginx -t privately' \
      medium 'Correct configuration before reload or restart' no
    return 0
  fi
  # Only validated scalars leave the raw configuration. No shell evaluation.
  mapfile -t endpoints < <(awk '
    /^[[:space:]]*listen[[:space:]]/ {
      gsub(/;/," "); print $2, ($0 ~ /[[:space:]]ssl([[:space:]]|$)/ ? "https" : "http")
    }' "$CONFIG_FILE")
  for line in "${endpoints[@]}"; do
    read -r port scheme <<< "$line"
    port=${port##*:}
    [[ $port =~ ^[0-9]{1,5}$ ]] || continue
    ((10#$port >= 1 && 10#$port <= 65535)) || continue
    port=$((10#$port))
    [[ -z ${SEEN_PORTS[$port]:-} ]] || continue
    SEEN_PORTS[$port]=1
    PORTS+=("$port") SCHEMES+=("$scheme")
    ((${#PORTS[@]} < 8)) || break
  done
  host=$(awk '/^[[:space:]]*server_name[[:space:]]/ {gsub(/;/,""); print $2; exit}' "$CONFIG_FILE") || host=''
  if [[ $host =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ && $host != *..* ]]; then SNI_HOST=$host; fi
  socket=$(awk '/^[[:space:]]*fastcgi_pass[[:space:]]+unix:/ {gsub(/;/,""); print $2; exit}' \
    "$CONFIG_FILE") || socket=''
  if [[ $socket == unix:/* ]]; then
    socket=${socket#unix:}
    if [[ -S $SYSTEM_ROOT$socket ]]; then
      socket_mode=$(stat -c '%a' -- "$SYSTEM_ROOT$socket") || socket_mode=unknown
      [[ $socket_mode =~ ^[0-7]{3,4}$ ]] || socket_mode=unknown
      finding php_socket HEALTHY info "Configured FastCGI Unix socket exists; permissions_octal=$socket_mode" \
        'Socket presence does not prove worker response' \
        medium 'Correlate HTTP and worker logs' no
    else
      finding php_socket FAILED high 'Configured FastCGI Unix socket absent' \
        'Backend unavailable or socket path mismatch' \
        high 'Inspect PHP-FPM listener configuration and permissions privately' conditional
    fi
  else
    finding php_socket UNKNOWN info 'No simple FastCGI Unix socket discovered' \
      'TCP upstream or nonstandard configuration may be used' low 'Inspect upstream configuration privately' no
  fi
  if ((${#PORTS[@]} == 0)); then
    finding endpoints UNKNOWN warning 'No supported numeric listen directives discovered' \
      'Nonstandard nginx layout' low 'Inspect effective configuration privately' no
  fi
  return 0
}

# Separate TCP-listener evidence from HTTP behavior. A bound port may not serve
# the management application, and loopback may fail when binding excludes loopback.
# Force every request to loopback even when Host/SNI uses a discovered name. Do not
# follow redirects: a redirect can be normal authentication/TLS behavior, and its
# destination must not turn a local diagnostic probe into an external request.
probe_endpoints() {
  local -- response='' code='' elapsed='' port='' scheme='' listeners='' value=''
  local -i index=0 status=0 available=0
  local -a args=()
  HTTP_OK=0 HTTP_BAD=0 HTTP_BACKEND=0
  if ! has_tool curl; then
    finding http UNKNOWN warning 'curl unavailable; no probes run' unknown low 'Test local endpoint manually' no
    return 0
  fi
  if has_tool ss; then
    listeners=$(timeout -k 2 5 ss -lntH 2>/dev/null) || listeners=''
  fi
  for index in "${!PORTS[@]}"; do
    port=${PORTS[$index]} scheme=${SCHEMES[$index]}
    available=0
    while read -r _ _ _ value _; do
      if [[ ${value##*:} == "$port" ]]; then available=1; fi
    done <<< "$listeners"
    finding listener UNKNOWN info "$scheme port=$port observed_tcp_listener=$available" \
      'Listener ownership and interface restrictions require correlation' low 'Compare local HTTP result' no
    # --resolve prevents DNS or external traffic. Never follow redirects or use a proxy.
    # Ignore curl startup configuration; it could otherwise inject credentials,
    # proxy settings or transfer behavior before the explicit probe flags apply.
    args=(--disable --noproxy '*' --silent --output /dev/null --connect-timeout 2 --max-time 6
      --resolve "$SNI_HOST:$port:127.0.0.1" --write-out '%{http_code} %{time_total}')
    # Certificate trust is deliberately not tested here. This exception is safe
    # only within the forced-loopback probe; it is never used for internet traffic.
    if [[ $scheme == https ]]; then args+=(--insecure); fi
    status=0
    response=$(curl "${args[@]}" "$scheme://$SNI_HOST:$port/" 2>/dev/null) || status=$?
    if [[ $response =~ ^([0-9]{3})[[:space:]]([0-9]+\.[0-9]+)$ ]]; then
      code=${BASH_REMATCH[1]} elapsed=${BASH_REMATCH[2]}
    else
      code=000 elapsed=unknown
      if ((status == 0)); then status=1; fi
    fi
    if ((status)); then
      HTTP_BAD+=1
      case $status in
        7) value='Connection refused or listener bound outside loopback' ;;
        28) value='Connection or response timeout' ;;
        35|60) value='Local TLS handshake failure' ;;
        56) value='Connection reset or receive failure' ;;
        *) value='Probe failed or produced malformed output' ;;
      esac
      finding http WARNING high "$scheme port=$port curl_exit=$status; $value" \
        'Local probe inconclusive for interfaces not bound to loopback' medium 'Inspect binding and service response' no
    else
      case $code in
        2??|3??|401|403)
          HTTP_OK+=1
          finding http HEALTHY info "$scheme port=$port HTTP=$code seconds=$elapsed" \
            'HTTP service responded; authentication and TLS redirects are acceptable' \
            medium 'Browser access and redirected target remain unverified' no
          ;;
        502|503|504)
          HTTP_BAD+=1 HTTP_BACKEND+=1
          finding http FAILED high "$scheme port=$port HTTP=$code seconds=$elapsed" \
            'Backend failure, maintenance, overload or upstream timeout; PHP is not the only possible cause' \
            medium 'Correlate backend process and socket evidence' conditional
          ;;
        *)
          HTTP_BAD+=1
          finding http WARNING high "$scheme port=$port HTTP=$code seconds=$elapsed" \
            'Routing or application response needs investigation' low 'Inspect local configuration privately' no
          ;;
      esac
    fi
  done
  return 0
}

# Bound log work and report classifications instead of message contents, since
# even ordinary error lines can contain URLs, tokens, paths or user information.
# Timestamp correlation distinguishes recent patterns from stale evidence. Formats
# that cannot be dated are uncorrelated; they must not establish a current outage.
log_checks() {
  local -- path='' label='' data='' counts=''
  local -i found=0 recent=0 unknown=0
  for path in /var/log/nginx/error.log /var/log/nginx/errorlog /var/log/php-fpm.log /var/log/phplog \
    /var/log/syslog /var/log/plugins/plugin.log /var/log/emhttpd.log; do
    [[ -r $SYSTEM_ROOT$path && -f $SYSTEM_ROOT$path ]] || continue
    found+=1
    label=${path##*/}
    data=$(tail -c 65536 -- "$SYSTEM_ROOT$path") || {
      finding logs UNKNOWN warning "$label unreadable" unknown low 'Inspect file privately' no
      continue
    }
    # Messages are classified, never reproduced. Timestamp format is nginx ISO date.
    counts=$(awk -v now="$EPOCHSECONDS" '
      BEGIN {recent=0; unknown=0}
      /upstream|connect\(\) failed|timed out|Permission denied|bind\(\)|no space left|Out of memory|max_children/ {
        if (match($0,/^[0-9]{4}[\/-][0-9]{2}[\/-][0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
          stamp=substr($0,1,19); gsub(/[\/:\-]/," ",stamp); age=now-mktime(stamp)
          if (age>=0 && age<=900) recent++
        } else unknown++
      }
      END {print recent,unknown}' <<< "$data") || counts='0 0'
    read -r recent unknown <<< "$counts"
    if ((recent)); then
      finding logs WARNING high "$label recent_error_patterns=$recent window_seconds=900" \
        'Recent resource, binding, permissions or backend error pattern' medium 'Inspect matching log locally' no
    elif ((unknown)); then
      finding logs UNKNOWN info "$label uncorrelated_error_patterns=$unknown" \
        'Timestamp unavailable; historical entries do not establish current failure' \
        low 'Correlate timestamps locally' no
    else
      finding logs HEALTHY info "$label no recent classified patterns in bounded tail" \
        'Only selected error patterns inspected' low 'Other errors may exist' no
    fi
  done
  if ((found == 0)); then
    finding logs UNKNOWN info 'No supported readable log files found' 'Different layout or unavailable logs' \
      low 'Inspect service log locations privately' no
  fi
  return 0
}

# Updaters may legitimately wait on child processes, network I/O or a package lock.
# Combine elapsed time with a short metadata/I/O sample, retaining only safe process
# identifiers and wait-state fields. An unchanged sample is not proof of a hang;
# descendants can still make progress. This function never sends process signals.
plugin_checks() {
  local -- table='' row='' pid='' parent='' elapsed='' state='' wait_channel='' command=''
  local -- before='' after='' cpu='' io=''
  local -- state_pattern='^[A-Za-z+<]{1,8}$'
  local -i candidates=0
  local -a sampled=()
  table=$(ps -eo pid=,ppid=,etimes=,stat=,wchan:32=,args= 2>/dev/null) || {
    finding plugin_updates UNKNOWN warning 'Process inventory unavailable' \
      unknown low 'Inspect process tree privately' no
    return 0
  }
  while read -r pid parent elapsed state wait_channel command; do
    [[ $command == *updateApplications.php* || $command == *'multiplugin update'* \
      || $command == *'/plugin update '* ]] || continue
    [[ $pid =~ ^[0-9]+$ && $parent =~ ^[0-9]+$ && $elapsed =~ ^[0-9]{1,9}$ ]] || continue
    candidates+=1
    if ((candidates > 16)); then break; fi
    before=''
    if [[ -r $SYSTEM_ROOT/proc/$pid/stat && -r $SYSTEM_ROOT/proc/$pid/io ]]; then
      cpu=$(< "$SYSTEM_ROOT/proc/$pid/stat")
      io=$(< "$SYSTEM_ROOT/proc/$pid/io")
      before=$(printf '%s' "$cpu$io" | cksum) || before=''
    fi
    sampled+=("$pid|$parent|$elapsed|$state|$wait_channel|$before")
  done <<< "$table"
  if ((${#sampled[@]} == 0)); then
    finding plugin_updates 'NOT APPLICABLE' info 'No matching updater processes observed' None medium None no
    return 0
  fi
  sleep 1
  for row in "${sampled[@]}"; do
    IFS='|' read -r pid parent elapsed state wait_channel before <<< "$row"
    [[ $state =~ $state_pattern ]] || state=unknown
    [[ $wait_channel =~ ^[A-Za-z0-9_.:-]{1,32}$ ]] || wait_channel=unknown
    after=''
    if [[ -r $SYSTEM_ROOT/proc/$pid/stat && -r $SYSTEM_ROOT/proc/$pid/io ]]; then
      cpu=$(< "$SYSTEM_ROOT/proc/$pid/stat")
      io=$(< "$SYSTEM_ROOT/proc/$pid/io")
      after=$(printf '%s' "$cpu$io" | cksum) || after=''
    fi
    if [[ -n $before && $before == "$after" ]] && ((elapsed >= 900)); then
      row="pid=$pid parent=$parent elapsed_seconds=$elapsed state=$state wait=$wait_channel"
      finding plugin_updates WARNING medium "$row; no sampled activity" \
        'Potentially stalled; short sampling cannot prove a hang or exclude child progress' low \
        'Inspect complete tree, wait channel and log progress privately; termination is manual only' no
    else
      row="pid=$pid parent=$parent elapsed_seconds=$elapsed state=$state wait=$wait_channel"
      finding plugin_updates UNKNOWN info "$row; progress not disproved" \
        'Active or insufficient evidence; elapsed time alone is not a hang' \
        low 'Observe child and log activity locally' no
    fi
  done
  return 0
}

# Restrict automation to known component paths and candidate version families.
# Require an executable regular helper, root ownership, no group/other write access,
# and an explicit operation label in its dispatch. These are eligibility checks,
# not a complete audit of customized helper behavior or live release qualification.
# No management-daemon or arbitrary user-supplied helper is dispatched here.
service_safe() {
  local -- component=$1 operation=$2 service='' owner='' mode='' content=''
  case $component in
    nginx) service=$SYSTEM_ROOT/etc/rc.d/rc.nginx ;;
    php-fpm) service=$SYSTEM_ROOT/etc/rc.d/rc.php-fpm ;;
    *) return 1 ;;
  esac
  # No management-daemon operations; unknown version families require manual recovery.
  [[ $OS_VERSION =~ ^(6\.12\.|7\.) ]] || return 1
  [[ -f $service && -x $service && ! -L $service ]] || return 1
  owner=$(stat -c '%u' -- "$service") || return 1
  mode=$(stat -c '%a' -- "$service") || return 1
  [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$mode & 022) == 0 )) || return 1
  content=$(< "$service")
  # Require an explicit dispatch label, not an arbitrary occurrence in a comment.
  grep -Eq -- "^[[:space:]]*['\"]?${operation}['\"]?[[:space:]]*\\)" <<< "$content" || return 1
  return 0
}

# Build recommendations from combinations of observations, not isolated symptoms.
# Rebuild ACTIONS each time so old eligibility cannot survive a fresh diagnosis.
# Resource pressure or an unavailable process inventory blocks service changes.
# A PHP restart needs an absent PHP process plus nginx/backend-error evidence;
# nginx reload needs a master without observed workers, not merely an HTTP error.
correlate() {
  ACTIONS=()
  if ((HTTP_BAD && ! PHP && NGINX)); then
    finding diagnosis FAILED high 'HTTP failure with nginx present and PHP-FPM absent' \
      'Probable PHP backend failure; routing may also contribute' \
      high 'Inspect PHP-FPM then consider a restart' conditional
  elif ((HTTP_BAD && PHP && NGINX)); then
    finding diagnosis WARNING high 'HTTP failure despite frontend and backend process presence' \
      'Worker saturation, backend sockets, plugins or routing need investigation' medium \
      'Inspect sockets and recent logs; do not assume a PHP restart is justified' no
  elif ((HTTP_OK)); then
    finding diagnosis HEALTHY info 'At least one local management listener responded' \
      'Local HTTP response only; remote network, TLS identity and application behavior unverified' \
      medium 'If browser access fails inspect DNS, TLS and network path privately' no
  else
    finding diagnosis UNKNOWN warning 'No confirmed healthy local endpoint' \
      'Configuration discovery or interface binding may limit probing' \
      low 'Inspect listeners and configuration locally' no
  fi
  if ((RESOURCE_BAD == 0 && PROCESS_KNOWN)); then
    if ((CONFIG_OK)); then
      if ((NGINX == 0)) && service_safe nginx restart; then ACTIONS+=(nginx:restart); fi
      if ((NGINX_MASTER && NGINX_WORKERS == 0)) && service_safe nginx reload; then
        ACTIONS+=(nginx:reload)
      fi
    fi
    if ((CONFIG_OK && PHP == 0 && HTTP_BACKEND && NGINX)) && service_safe php-fpm restart; then
      ACTIONS+=(php-fpm:restart)
    fi
  fi
  if ((EMHTTP == 0)); then
    finding recovery WARNING high 'No automated emhttpd restart offered' \
      'Management-daemon side effects are not qualified' high 'Use version-specific Unraid support guidance' no
  fi
  return 0
}

# Run sequentially to avoid adding parallel load to an already degraded host.
# Discovery precedes probes; raw observations precede interpretation and repair
# eligibility. This same sequence supports independent post-repair verification.
diagnose() {
  system_checks
  check_processes
  worker_checks
  component_versions
  nginx_config
  probe_endpoints
  log_checks
  plugin_checks
  correlate
  return 0
}

# Diagnosis-only/report modes take precedence over an interactive request. A real
# terminal, a numbered selection and a separate exact YES are all required.
# Snapshot the offered actions for selection, but revalidate after confirmation:
# the service, configuration or resource situation may change while the user reads.
# One approved action is attempted; failures never trigger cascading restarts.
repair_menu() {
  local -- selection='' answer='' action='' component='' operation='' service=''
  local -i index=0 status=0 permitted=0 lock_fd=0
  local -a original=("${ACTIONS[@]}")
  if ((NO_REPAIR || ! INTERACTIVE)); then return 0; fi
  [[ -t 0 && -t 1 && -t 2 ]] || { info 'No terminal; diagnosis only.'; return 0; }
  if ((${#original[@]} == 0)); then info 'No evidence-supported automated repair available.'; return 0; fi
  warn 'Service operations can interrupt WebGUI sessions and active management requests.'
  warn 'Installed service dispatch is inspected; live Unraid release qualification remains pending.'
  for action in "${original[@]}"; do
    index+=1
    _msg "$index) $action via installed service helper"
  done
  _msg '0) Leave without changes. Select one number (60-second timeout):'
  read -r -t 60 selection || selection=0
  [[ $selection =~ ^[0-9]{1,2}$ ]] || { warn 'Invalid selection; no changes.'; return 0; }
  index=$((10#$selection))
  ((index >= 1 && index <= ${#original[@]})) || { info 'No changes requested.'; return 0; }
  action=${original[$((index - 1))]}
  component=${action%:*} operation=${action#*:}
  _msg "Selected $component $operation. Type exactly YES to approve this operation (60 seconds):"
  read -r -t 60 answer || answer=''
  [[ $answer == YES ]] || { info 'Repair declined; no changes.'; return 0; }
  # Repairs get a local audit report even when diagnosis reporting was not requested.
  prepare_report 1
  has_tool flock || die 18 'flock is required for a repair; diagnosis remains available.'
  service=$SYSTEM_ROOT/run/unraid-webgui-doctor.lock
  [[ ! -L $service && (! -e $service || -f $service) ]] || die 13 'Unsafe repair lock path.'
  exec {lock_fd}> "$service" || die 5 'Cannot open repair lock.'
  # Serialize repair attempts requested through this utility, without waiting behind
  # another attempt. The lock does not prevent independent administrator actions.
  flock -n "$lock_fd" || die 1 'Another WebGUI Doctor repair is in progress.'
  # Revalidate after the user confirms: service state/config may have changed while waiting.
  RESULT=0 RESOURCE_BAD=0
  system_checks
  check_processes
  worker_checks
  nginx_config
  probe_endpoints
  correlate
  for selection in "${ACTIONS[@]}"; do
    if [[ $selection == "$action" ]]; then permitted=1; fi
  done
  if ((permitted == 0)) || ! service_safe "$component" "$operation"; then
    finding repair UNKNOWN warning 'Approved repair no longer justified or service helper changed' \
      'Revalidation blocked execution' high 'Investigate current findings' no
    return 0
  fi
  service=$SYSTEM_ROOT/etc/rc.d/rc.$component
  finding repair WARNING info "$action approved; executing installed helper with 30-second bound" \
    'Explicit terminal confirmation and fresh diagnosis completed' high 'Wait for post-repair verification' no
  # A clean environment prevents inherited interpreter/loader/proxy settings affecting service control.
  status=0
  # Bound helper execution and capture its output privately. A timeout can leave
  # an operation incomplete; do not retry blindly or infer recovery from exit alone.
  timeout --foreground -k 5 30 env -i PATH="$PATH" LC_ALL=C /bin/bash "$service" "$operation" \
    > "$WORK_DIR/repair-output" 2>&1 || status=$?
  if ((status)); then
    finding repair FAILED high "$action exit=$status; output withheld for privacy" \
      'Service helper failed' high 'Inspect service privately; no repeated repair attempted' no
    return 0
  fi
  sleep 2
  RESULT=0 RESOURCE_BAD=0
  diagnose
  # Require observed HTTP recovery and no remaining FAILED assessment. A helper
  # returning success by itself does not prove that the application is usable.
  if ((HTTP_OK && HTTP_BAD == 0 && RESULT == 0)); then
    finding repair HEALTHY info "$action completed; post-repair local checks passed" \
      'Observed local recovery; browser behavior unverified' medium 'Confirm WebGUI access manually' no
  else
    finding repair FAILED high "$action completed but post-repair verification failed or is inconclusive" \
      'Service command success does not establish recovery' high 'Inspect remaining findings; no further changes' no
  fi
  return 0
}

# Parse options before acquiring resources. Freeze configuration after parsing
# so later diagnostics cannot silently switch operating modes or reporting policy.
# Install cleanup/signal traps before creating any sensitive scratch captures.
main() {
  local -- tool='' mode=auto
  umask 077
  while (($#)); do
    case $1 in
      --diagnose-only|--no-fix) NO_REPAIR=1 ;;
      --interactive) INTERACTIVE=1 ;;
      --report) REPORT=1 NO_REPAIR=1 ;;
      --report-dir)
        (($# > 1)) || die 22 'Option --report-dir requires an argument.'
        shift
        REPORT_DIR=$1 REPORT=1 NO_REPAIR=1
        ;;
      -v|--verbose) EXPANDED=1 VERBOSE=1 ;;
      -q|--quiet) VERBOSE=0 ;;
      --no-color) ;;
      -h|--help) show_help; return 0 ;;
      -V|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; return 0 ;;
      -[vqhV]?*) set -- "${1:0:2}" "-${1:2}" "${@:2}"; continue ;;
      *) die 22 'Unknown option or positional argument; see --help.' ;;
    esac
    shift
  done
  if [[ -t 0 && -t 1 && -t 2 ]] && ((NO_REPAIR == 0)); then INTERACTIVE=1; fi
  if ((NO_REPAIR)); then mode=diagnose-only; else mode=interactive-if-terminal; fi
  readonly VERBOSE EXPANDED REPORT NO_REPAIR INTERACTIVE REPORT_DIR
  ((EUID == 0)) || die 13 'Run as root through the Unraid terminal or SSH.'
  [[ -d $SYSTEM_ROOT/boot/config && -d $SYSTEM_ROOT/usr/local/emhttp ]] \
    || die 3 'Unraid host layout not detected; no operations performed.'
  for tool in timeout ps; do
    has_tool "$tool" || die 18 "Required tool unavailable: ${tool@Q}"
  done
  trap 'cleanup $?' EXIT
  trap 'interrupted 130' INT
  trap 'interrupted 143' TERM
  WORK_DIR=$(mktemp -d /tmp/unraid-webgui-doctor.XXXXXXXX) || die 5 'Cannot allocate private working directory.'
  prepare_report
  info "$SCRIPT_NAME $VERSION; mode=$mode; sequential checks; local services only; no raw logs printed."
  diagnose
  repair_menu
  info "Diagnosis complete; exit=$RESULT. UNKNOWN checks require manual investigation."
  return "$RESULT"
}

main "$@"
#fin
