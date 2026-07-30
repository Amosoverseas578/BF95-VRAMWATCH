#!/usr/bin/env bash

# BF95 AMD VRAMWATCH - compact AMD-SMI + ComfyUI memory dashboard for AMD GPUs on Linux
# Uses the current amd-smi CLI (not the deprecated rocm-smi command).
#
# Examples:
#   ./BF95-AMD-VRAMWATCH.sh
#   ./BF95-AMD-VRAMWATCH.sh --gpu 1 --interval 1
#   ./BF95-AMD-VRAMWATCH.sh --once
#   NO_COLOR=1 ./BF95-AMD-VRAMWATCH.sh

set -u

GPU_ID="${VRAMWATCH_GPU:-0}"
INTERVAL="${VRAMWATCH_INTERVAL:-2}"
BAR_WIDTH="${VRAMWATCH_WIDTH:-32}"
RUN_ONCE=0
FORCE_NO_COLOR=0
ASCII_ONLY=0
PROC_ROOT="${VRAMWATCH_PROC_ROOT:-/proc}"
COMFY_PATTERN="${VRAMWATCH_COMFY_PATTERN:-[p]ython.*main.py}"
PAGE_SIZE_KIB=$(( $(getconf PAGESIZE 2>/dev/null || printf '4096') / 1024 ))
GUARD_WINDOW_SECONDS="${VRAMWATCH_GUARD_WINDOW_SECONDS:-60}"
TREND_SHORT_SECONDS="${VRAMWATCH_TREND_SHORT_SECONDS:-60}"
TREND_LONG_SECONDS="${VRAMWATCH_TREND_LONG_SECONDS:-600}"
GUARD_WARN_AVAILABLE_PCT="${VRAMWATCH_GUARD_WARN_AVAILABLE_PCT:-20}"
GUARD_CRIT_AVAILABLE_PCT="${VRAMWATCH_GUARD_CRIT_AVAILABLE_PCT:-10}"
GUARD_WARN_RSS_PCT="${VRAMWATCH_GUARD_WARN_RSS_PCT:-75}"
GUARD_CRIT_RSS_PCT="${VRAMWATCH_GUARD_CRIT_RSS_PCT:-85}"
GUARD_WARN_SWAP_KIB=$((2 * 1024 * 1024))
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || printf '100')

usage() {
    cat <<'USAGE'
Usage: BF95-AMD-VRAMWATCH.sh [options]

Options:
  -g, --gpu ID          GPU index to watch (default: 0)
  -i, --interval SEC    Refresh interval in seconds (default: 2)
  -w, --width COLS      Meter width, 10-60 (default: 32)
  -1, --once            Print one snapshot and exit
      --no-color        Disable ANSI colors
      --ascii           Use ASCII bar characters
  -h, --help            Show this help

Environment variables:
  VRAMWATCH_GPU, VRAMWATCH_INTERVAL, VRAMWATCH_WIDTH,
  VRAMWATCH_COMFY_PATTERN, VRAMWATCH_GUARD_WINDOW_SECONDS,
  VRAMWATCH_TREND_SHORT_SECONDS, VRAMWATCH_TREND_LONG_SECONDS,
  VRAMWATCH_GUARD_WARN_AVAILABLE_PCT, VRAMWATCH_GUARD_CRIT_AVAILABLE_PCT,
  VRAMWATCH_GUARD_WARN_RSS_PCT, VRAMWATCH_GUARD_CRIT_RSS_PCT, NO_COLOR
USAGE
}

die() {
    printf 'BF95 AMD VRAMWATCH: %s\n' "$*" >&2
    exit 1
}

while (($#)); do
    case "$1" in
        -g|--gpu)
            (($# >= 2)) || die "$1 requires a GPU index"
            GPU_ID=$2
            shift 2
            ;;
        -i|--interval)
            (($# >= 2)) || die "$1 requires a number of seconds"
            INTERVAL=$2
            shift 2
            ;;
        -w|--width)
            (($# >= 2)) || die "$1 requires a width"
            BAR_WIDTH=$2
            shift 2
            ;;
        -1|--once)
            RUN_ONCE=1
            shift
            ;;
        --no-color)
            FORCE_NO_COLOR=1
            shift
            ;;
        --ascii)
            ASCII_ONLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac
done

[[ "$GPU_ID" =~ ^[0-9]+$ ]] || die "GPU index must be a non-negative integer"
[[ "$INTERVAL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "interval must be a positive number"
awk -v n="$INTERVAL" 'BEGIN { exit !(n > 0) }' || die "interval must be greater than zero"
[[ "$BAR_WIDTH" =~ ^[0-9]+$ ]] || die "width must be an integer from 10 to 60"
((BAR_WIDTH >= 10 && BAR_WIDTH <= 60)) || die "width must be from 10 to 60"
[[ "$GUARD_WINDOW_SECONDS" =~ ^[0-9]+$ ]] || die "guard window must be a whole number of seconds"
((GUARD_WINDOW_SECONDS >= 20 && GUARD_WINDOW_SECONDS <= 600)) || \
    die "guard window must be from 20 to 600 seconds"
[[ "$TREND_SHORT_SECONDS" =~ ^[0-9]+$ ]] || die "short trend must be a whole number of seconds"
[[ "$TREND_LONG_SECONDS" =~ ^[0-9]+$ ]] || die "long trend must be a whole number of seconds"
((TREND_SHORT_SECONDS >= 20 && TREND_SHORT_SECONDS <= 600)) || \
    die "short trend must be from 20 to 600 seconds"
((TREND_LONG_SECONDS >= TREND_SHORT_SECONDS && TREND_LONG_SECONDS <= 3600)) || \
    die "long trend must be at least the short trend and no more than 3600 seconds"
for pct_name in GUARD_WARN_AVAILABLE_PCT GUARD_CRIT_AVAILABLE_PCT GUARD_WARN_RSS_PCT GUARD_CRIT_RSS_PCT; do
    pct_value=${!pct_name}
    [[ "$pct_value" =~ ^[0-9]+$ ]] || die "$pct_name must be a whole-number percentage"
    ((pct_value >= 1 && pct_value <= 99)) || die "$pct_name must be from 1 to 99"
done
((GUARD_CRIT_AVAILABLE_PCT < GUARD_WARN_AVAILABLE_PCT)) || \
    die "critical available-RAM percentage must be lower than warning percentage"
((GUARD_WARN_RSS_PCT < GUARD_CRIT_RSS_PCT)) || \
    die "warning RSS percentage must be lower than critical percentage"
GUARD_MAX_SAMPLES=$(awk -v sec="$GUARD_WINDOW_SECONDS" -v interval="$INTERVAL" 'BEGIN {
    n = int(sec / interval + 0.999999)
    if (n < 3) n = 3
    print n
}')
GUARD_MIN_SAMPLES=$(awk -v interval="$INTERVAL" 'BEGIN {
    n = int(20 / interval + 0.999999)
    if (n < 3) n = 3
    print n
}')
TREND_SHORT_MAX_SAMPLES=$(awk -v sec="$TREND_SHORT_SECONDS" -v interval="$INTERVAL" 'BEGIN {
    n = int(sec / interval + 0.999999) + 1
    if (n < 3) n = 3
    print n
}')
TREND_LONG_MAX_SAMPLES=$(awk -v sec="$TREND_LONG_SECONDS" -v interval="$INTERVAL" 'BEGIN {
    n = int(sec / interval + 0.999999) + 1
    if (n < 3) n = 3
    print n
}')

command -v amd-smi >/dev/null 2>&1 || die "amd-smi was not found in PATH"
command -v awk >/dev/null 2>&1 || die "awk was not found in PATH"
command -v pgrep >/dev/null 2>&1 || die "pgrep was not found in PATH"
[[ -r "$PROC_ROOT/meminfo" && -r "$PROC_ROOT/stat" ]] || \
    die "/proc memory/CPU statistics are unavailable; this script must run on Linux"

INTERACTIVE=0
[[ -t 1 ]] && INTERACTIVE=1

USE_COLOR=1
if ((FORCE_NO_COLOR)) || [[ -n "${NO_COLOR:-}" ]] || [[ "${TERM:-}" == "dumb" ]] || ((INTERACTIVE == 0)); then
    USE_COLOR=0
fi

if ((USE_COLOR)); then
    RESET=$'\033[0m'
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    BLUE=$'\033[34m'
    MAGENTA=$'\033[35m'
    CYAN=$'\033[36m'
    WHITE=$'\033[97m'
else
    RESET=''
    BOLD=''
    DIM=''
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    MAGENTA=''
    CYAN=''
    WHITE=''
fi

if ((ASCII_ONLY)) || [[ "${LC_ALL:-${LANG:-}}" == "C" ]] || [[ "${LC_ALL:-${LANG:-}}" == "POSIX" ]]; then
    BAR_FULL='#'
    BAR_EMPTY='.'
    RULE_CHAR='-'
else
    BAR_FULL='█'
    BAR_EMPTY='░'
    RULE_CHAR='─'
fi

repeat_char() {
    local count=$1 char=$2 text
    printf -v text '%*s' "$count" ''
    printf '%s' "${text// /$char}"
}

is_number() {
    [[ ${1:-} =~ ^[0-9]+([.][0-9]+)?$ ]]
}

field_value() {
    local key=$1
    awk -v wanted="${key}:" '
        $1 == wanted {
            if ($2 == "N/A") { print "N/A"; exit }
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^[0-9]+([.][0-9]+)?$/) { print $i; exit }
            }
        }
    ' <<<"$METRIC"
}

field_unit() {
    local key=$1
    awk -v wanted="${key}:" '$1 == wanted { print $3; exit }' <<<"$METRIC"
}

field_after() {
    local section=$1 key=$2
    awk -v start="${section}:" -v wanted="${key}:" '
        $1 == start {
            found = 1
            section_indent = match($0, /[^[:space:]]/) - 1
            next
        }
        found {
            current_indent = match($0, /[^[:space:]]/) - 1
            if (current_indent <= section_indent) exit
        }
        found && $1 == wanted {
            if ($2 == "N/A") { print "N/A"; exit }
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^[0-9]+([.][0-9]+)?$/) { print $i; exit }
            }
        }
    ' <<<"$METRIC"
}

field_unit_after() {
    local section=$1 key=$2
    awk -v start="${section}:" -v wanted="${key}:" '
        $1 == start {
            found = 1
            section_indent = match($0, /[^[:space:]]/) - 1
            next
        }
        found {
            current_indent = match($0, /[^[:space:]]/) - 1
            if (current_indent <= section_indent) exit
        }
        found && $1 == wanted { print $3; exit }
    ' <<<"$METRIC"
}

value_or_na() {
    local value=${1:-}
    if is_number "$value"; then
        printf '%s' "$value"
    else
        printf 'N/A'
    fi
}

calc_pct() {
    local used=${1:-} total=${2:-}
    if ! is_number "$used" || ! is_number "$total"; then
        printf 'N/A'
        return
    fi
    awk -v used="$used" -v total="$total" 'BEGIN {
        if (total <= 0) { print "N/A"; exit }
        pct = used * 100 / total
        if (pct < 0) pct = 0
        if (pct > 100) pct = 100
        printf "%.1f", pct
    }'
}

scale_pct() {
    local value=${1:-} maximum=${2:-}
    calc_pct "$value" "$maximum"
}

human_mib() {
    local value=${1:-}
    if is_number "$value"; then
        awk -v mib="$value" 'BEGIN { printf "%.2f GiB", mib / 1024 }'
    else
        printf 'N/A'
    fi
}

human_kib() {
    local value=${1:-}
    if is_number "$value"; then
        awk -v kib="$value" 'BEGIN { printf "%.2f GiB", kib / 1048576 }'
    else
        printf 'N/A'
    fi
}

human_kib_signed() {
    local value=${1:-}
    if [[ "$value" =~ ^-?[0-9]+$ ]]; then
        awk -v kib="$value" 'BEGIN {
            sign = (kib > 0 ? "+" : "")
            printf "%s%.2f GiB", sign, kib / 1048576
        }'
    else
        printf 'N/A'
    fi
}

human_mib_rate() {
    local value=${1:-}
    if is_number "$value"; then
        awk -v mib="$value" 'BEGIN { printf "%.2f MiB/s", mib }'
    else
        printf 'N/A'
    fi
}


human_fault_rate() {
    local value=${1:-}
    if is_number "$value"; then
        awk -v rate="$value" 'BEGIN { printf "%.2f faults/s", rate }'
    else
        printf 'N/A'
    fi
}

human_duration() {
    local seconds=${1:-}
    if [[ "$seconds" =~ ^[0-9]+$ ]]; then
        local days hours minutes secs
        days=$((seconds / 86400))
        hours=$(((seconds % 86400) / 3600))
        minutes=$(((seconds % 3600) / 60))
        secs=$((seconds % 60))
        if ((days > 0)); then
            printf '%dd %02d:%02d:%02d' "$days" "$hours" "$minutes" "$secs"
        else
            printf '%02d:%02d:%02d' "$hours" "$minutes" "$secs"
        fi
    else
        printf 'N/A'
    fi
}

pct_to_tenths() {
    local pct=$1 whole fraction
    if [[ "$pct" == *.* ]]; then
        whole=${pct%%.*}
        fraction=${pct#*.}
        fraction=${fraction:0:1}
        PCT_TENTHS=$((10#$whole * 10 + 10#$fraction))
    else
        PCT_TENTHS=$((10#$pct * 10))
    fi
}

memory_color() {
    local pct=${1:-} tenths
    if ! is_number "$pct"; then
        printf '%s' "$DIM"
        return
    fi
    pct_to_tenths "$pct"
    tenths=$PCT_TENTHS
    if ((tenths > 900)); then
        printf '%s' "$RED"
    elif ((tenths >= 800)); then
        printf '%s' "$YELLOW"
    else
        printf '%s' "$GREEN"
    fi
}

temperature_color() {
    local value=${1:-} whole
    if ! is_number "$value"; then
        printf '%s' "$DIM"
        return
    fi
    whole=${value%.*}
    if ((whole >= 90)); then
        printf '%s' "$RED"
    elif ((whole >= 75)); then
        printf '%s' "$YELLOW"
    else
        printf '%s' "$GREEN"
    fi
}

bar() {
    local pct=${1:-} color=${2:-$WHITE} tenths filled empty
    if ! is_number "$pct"; then
        printf '%s' "$DIM"
        repeat_char "$BAR_WIDTH" "$BAR_EMPTY"
        printf '%s' "$RESET"
        return
    fi

    pct_to_tenths "$pct"
    tenths=$PCT_TENTHS
    ((tenths < 0)) && tenths=0
    ((tenths > 1000)) && tenths=1000
    filled=$(((tenths * BAR_WIDTH + 500) / 1000))
    empty=$((BAR_WIDTH - filled))

    printf '%s' "$color"
    repeat_char "$filled" "$BAR_FULL"
    printf '%s' "$DIM"
    repeat_char "$empty" "$BAR_EMPTY"
    printf '%s' "$RESET"
}

meter() {
    local label=$1 detail=$2 pct=$3 color=$4 pct_text
    if is_number "$pct"; then
        pct_text="${pct}%"
    else
        pct_text='N/A'
    fi
    printf '  %-12s %-23s %6s  ' "$label" "$detail" "$pct_text"
    bar "$pct" "$color"
    printf '\n'
}

temperature_meter() {
    local label=$1 value=${2:-} maximum=$3 color pct detail
    pct=$(scale_pct "$value" "$maximum")
    color=$(temperature_color "$value")
    if is_number "$value"; then
        detail="${value} °C"
    else
        detail='N/A'
    fi
    printf '  %-12s %-23s %6s  ' "$label" "$detail" ''
    bar "$pct" "$color"
    printf '\n'
}

section() {
    printf '\n%s%s%s\n' "$BOLD" "$CYAN" "$1"
}

rule() {
    printf '%s' "$DIM"
    repeat_char $((BAR_WIDTH + 47)) "$RULE_CHAR"
    printf '%s\n' "$RESET"
}

load_system_ram() {
    read -r RAM_TOTAL_KIB RAM_AVAILABLE_KIB SWAP_TOTAL_KIB SWAP_FREE_KIB < <(
        awk '
            /^MemTotal:/     { total = $2 }
            /^MemAvailable:/ { available = $2 }
            /^SwapTotal:/    { swap_total = $2 }
            /^SwapFree:/     { swap_free = $2 }
            END { print total + 0, available + 0, swap_total + 0, swap_free + 0 }
        ' "$PROC_ROOT/meminfo"
    )
    RAM_USED_KIB=$((RAM_TOTAL_KIB - RAM_AVAILABLE_KIB))
    ((RAM_USED_KIB < 0)) && RAM_USED_KIB=0
    RAM_PCT=$(calc_pct "$RAM_USED_KIB" "$RAM_TOTAL_KIB")
    RAM_AVAILABLE_PCT=$(calc_pct "$RAM_AVAILABLE_KIB" "$RAM_TOTAL_KIB")

    SWAP_USED_KIB=$((SWAP_TOTAL_KIB - SWAP_FREE_KIB))
    ((SWAP_USED_KIB < 0)) && SWAP_USED_KIB=0
    SWAP_PCT=$(calc_pct "$SWAP_USED_KIB" "$SWAP_TOTAL_KIB")

    MEM_PSI_SOME='N/A'
    MEM_PSI_FULL='N/A'
    if [[ -r "$PROC_ROOT/pressure/memory" ]]; then
        read -r MEM_PSI_SOME MEM_PSI_FULL < <(
            awk '
                /^some / {
                    for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { split($i, a, "="); some = a[2] }
                }
                /^full / {
                    for (i = 1; i <= NF; i++) if ($i ~ /^avg10=/) { split($i, a, "="); full = a[2] }
                }
                END { print (some == "" ? "N/A" : some), (full == "" ? "N/A" : full) }
            ' "$PROC_ROOT/pressure/memory"
        )
    fi
}

read_swap_counters() {
    read -r SWAPIN_SAMPLE SWAPOUT_SAMPLE < <(
        awk '
            /^pswpin /  { swapin = $2 }
            /^pswpout / { swapout = $2 }
            END { print swapin + 0, swapout + 0 }
        ' "$PROC_ROOT/vmstat"
    )
}

load_swap_activity() {
    local previous_in=$SWAP_PREV_IN previous_out=$SWAP_PREV_OUT
    local delta_in delta_out

    read_swap_counters
    delta_in=$((SWAPIN_SAMPLE - previous_in))
    delta_out=$((SWAPOUT_SAMPLE - previous_out))
    ((delta_in < 0)) && delta_in=0
    ((delta_out < 0)) && delta_out=0

    SWAPIN_MIB_S=$(awk -v pages="$delta_in" -v page_kib="$PAGE_SIZE_KIB" -v sec="$INTERVAL"         'BEGIN { if (sec > 0) printf "%.2f", pages * page_kib / 1024 / sec; else print "0.00" }')
    SWAPOUT_MIB_S=$(awk -v pages="$delta_out" -v page_kib="$PAGE_SIZE_KIB" -v sec="$INTERVAL"         'BEGIN { if (sec > 0) printf "%.2f", pages * page_kib / 1024 / sec; else print "0.00" }')

    SWAP_PREV_IN=$SWAPIN_SAMPLE
    SWAP_PREV_OUT=$SWAPOUT_SAMPLE
}

load_comfy_process() {
    local pid status_file stat_file stat_line stat_rest uptime_seconds
    local majflt start_ticks
    local -a stat_fields
    pid=$(pgrep -n -f "$COMFY_PATTERN" 2>/dev/null || true)

    COMFY_PID=''
    COMFY_RSS_KIB=0
    COMFY_ANON_KIB=0
    COMFY_SWAP_KIB=0
    COMFY_TOTAL_KIB=0
    COMFY_RSS_PCT='N/A'
    COMFY_GROWTH_KIB=0
    COMFY_DELTA_KIB=0
    COMFY_VM_HWM_KIB=0
    COMFY_MAJFLT=0
    COMFY_MAJFLT_RATE='0.00'
    COMFY_UPTIME_SECONDS=0

    [[ -n "$pid" ]] || {
        COMFY_TRACK_PID=''
        COMFY_BASE_RSS_KIB=0
        COMFY_LAST_RSS_KIB=0
        COMFY_LAST_MAJFLT=0
        return
    }

    status_file="$PROC_ROOT/$pid/status"
    stat_file="$PROC_ROOT/$pid/stat"
    [[ -r "$status_file" && -r "$stat_file" ]] || return

    read -r COMFY_RSS_KIB COMFY_ANON_KIB COMFY_SWAP_KIB COMFY_VM_HWM_KIB < <(
        awk '
            /^VmRSS:/   { rss = $2 }
            /^RssAnon:/ { anon = $2 }
            /^VmSwap:/  { swap = $2 }
            /^VmHWM:/   { hwm = $2 }
            END { print rss + 0, anon + 0, swap + 0, hwm + 0 }
        ' "$status_file"
    )

    # Field 2 of /proc/PID/stat is parenthesized and may contain spaces.
    # After stripping it, majflt is field 10 and starttime is field 20.
    stat_line=$(<"$stat_file")
    stat_rest=${stat_line#*) }
    read -ra stat_fields <<<"$stat_rest"
    majflt=${stat_fields[9]:-0}
    start_ticks=${stat_fields[19]:-0}
    [[ "$majflt" =~ ^[0-9]+$ ]] || majflt=0
    [[ "$start_ticks" =~ ^[0-9]+$ ]] || start_ticks=0
    COMFY_MAJFLT=$majflt

    uptime_seconds=$(awk '{ printf "%.0f", $1 }' "$PROC_ROOT/uptime" 2>/dev/null || printf '0')
    if [[ "$uptime_seconds" =~ ^[0-9]+$ ]] && ((CLK_TCK > 0)); then
        COMFY_UPTIME_SECONDS=$((uptime_seconds - start_ticks / CLK_TCK))
        ((COMFY_UPTIME_SECONDS < 0)) && COMFY_UPTIME_SECONDS=0
    fi

    COMFY_PID=$pid
    COMFY_TOTAL_KIB=$((COMFY_RSS_KIB + COMFY_SWAP_KIB))
    COMFY_RSS_PCT=$(calc_pct "$COMFY_RSS_KIB" "$RAM_TOTAL_KIB")

    if [[ "$COMFY_TRACK_PID" != "$COMFY_PID" ]]; then
        COMFY_TRACK_PID=$COMFY_PID
        COMFY_BASE_RSS_KIB=$COMFY_RSS_KIB
        COMFY_LAST_RSS_KIB=$COMFY_RSS_KIB
        COMFY_LAST_MAJFLT=$COMFY_MAJFLT
    fi

    COMFY_GROWTH_KIB=$((COMFY_RSS_KIB - COMFY_BASE_RSS_KIB))
    COMFY_DELTA_KIB=$((COMFY_RSS_KIB - COMFY_LAST_RSS_KIB))
    COMFY_MAJFLT_DELTA=$((COMFY_MAJFLT - COMFY_LAST_MAJFLT))
    ((COMFY_MAJFLT_DELTA < 0)) && COMFY_MAJFLT_DELTA=0
    COMFY_MAJFLT_RATE=$(awk -v faults="$COMFY_MAJFLT_DELTA" -v sec="$INTERVAL" \
        'BEGIN { if (sec > 0) printf "%.2f", faults / sec; else print "0.00" }')
    COMFY_LAST_RSS_KIB=$COMFY_RSS_KIB
    COMFY_LAST_MAJFLT=$COMFY_MAJFLT
}

update_session_history() {
    local current oldest count

    if [[ -z "$COMFY_PID" ]]; then
        HISTORY_TRACK_PID=''
        RSS_SHORT_HISTORY=()
        RSS_LONG_HISTORY=()
        WATCH_PEAK_RSS_KIB=0
        WATCH_MIN_AVAILABLE_KIB=0
        RSS_SHORT_TREND_KIB=0
        RSS_LONG_TREND_KIB=0
        RSS_SHORT_SPAN_SECONDS=0
        RSS_LONG_SPAN_SECONDS=0
        return
    fi

    if [[ "$HISTORY_TRACK_PID" != "$COMFY_PID" ]]; then
        HISTORY_TRACK_PID=$COMFY_PID
        RSS_SHORT_HISTORY=()
        RSS_LONG_HISTORY=()
        WATCH_PEAK_RSS_KIB=$COMFY_RSS_KIB
        WATCH_MIN_AVAILABLE_KIB=$RAM_AVAILABLE_KIB
    fi

    ((COMFY_RSS_KIB > WATCH_PEAK_RSS_KIB)) && WATCH_PEAK_RSS_KIB=$COMFY_RSS_KIB
    if ((WATCH_MIN_AVAILABLE_KIB == 0 || RAM_AVAILABLE_KIB < WATCH_MIN_AVAILABLE_KIB)); then
        WATCH_MIN_AVAILABLE_KIB=$RAM_AVAILABLE_KIB
    fi

    RSS_SHORT_HISTORY+=("$COMFY_RSS_KIB")
    RSS_LONG_HISTORY+=("$COMFY_RSS_KIB")
    while ((${#RSS_SHORT_HISTORY[@]} > TREND_SHORT_MAX_SAMPLES)); do
        RSS_SHORT_HISTORY=("${RSS_SHORT_HISTORY[@]:1}")
    done
    while ((${#RSS_LONG_HISTORY[@]} > TREND_LONG_MAX_SAMPLES)); do
        RSS_LONG_HISTORY=("${RSS_LONG_HISTORY[@]:1}")
    done

    current=$COMFY_RSS_KIB
    oldest=${RSS_SHORT_HISTORY[0]}
    RSS_SHORT_TREND_KIB=$((current - oldest))
    count=${#RSS_SHORT_HISTORY[@]}
    RSS_SHORT_SPAN_SECONDS=$(awk -v n="$count" -v sec="$INTERVAL" 'BEGIN {
        span = (n > 1 ? (n - 1) * sec : 0)
        printf "%.0f", span
    }')

    oldest=${RSS_LONG_HISTORY[0]}
    RSS_LONG_TREND_KIB=$((current - oldest))
    count=${#RSS_LONG_HISTORY[@]}
    RSS_LONG_SPAN_SECONDS=$(awk -v n="$count" -v sec="$INTERVAL" 'BEGIN {
        span = (n > 1 ? (n - 1) * sec : 0)
        printf "%.0f", span
    }')
}

update_memory_guard() {
    local value sum_available=0 sum_rss=0 samples age_seconds

    # Convert the configured percentages to KiB for this machine. Calculate
    # these before the idle return because the footer always displays them.
    GUARD_WARN_AVAILABLE_KIB=$((RAM_TOTAL_KIB * GUARD_WARN_AVAILABLE_PCT / 100))
    GUARD_CRIT_AVAILABLE_KIB=$((RAM_TOTAL_KIB * GUARD_CRIT_AVAILABLE_PCT / 100))
    GUARD_WARN_RSS_KIB=$((RAM_TOTAL_KIB * GUARD_WARN_RSS_PCT / 100))
    GUARD_CRIT_RSS_KIB=$((RAM_TOTAL_KIB * GUARD_CRIT_RSS_PCT / 100))

    if [[ -z "$COMFY_PID" ]]; then
        GUARD_TRACK_PID=''
        GUARD_AVAILABLE_HISTORY=()
        GUARD_RSS_HISTORY=()
        GUARD_AVG_AVAILABLE_KIB=0
        GUARD_AVG_RSS_KIB=0
        MEMORY_GUARD='IDLE — no ComfyUI process found'
        MEMORY_GUARD_COLOR=$DIM
        return
    fi

    if [[ "$GUARD_TRACK_PID" != "$COMFY_PID" ]]; then
        GUARD_TRACK_PID=$COMFY_PID
        GUARD_AVAILABLE_HISTORY=()
        GUARD_RSS_HISTORY=()
    fi

    GUARD_AVAILABLE_HISTORY+=("$RAM_AVAILABLE_KIB")
    GUARD_RSS_HISTORY+=("$COMFY_RSS_KIB")

    while ((${#GUARD_AVAILABLE_HISTORY[@]} > GUARD_MAX_SAMPLES)); do
        GUARD_AVAILABLE_HISTORY=("${GUARD_AVAILABLE_HISTORY[@]:1}")
        GUARD_RSS_HISTORY=("${GUARD_RSS_HISTORY[@]:1}")
    done

    for value in "${GUARD_AVAILABLE_HISTORY[@]}"; do
        sum_available=$((sum_available + value))
    done
    for value in "${GUARD_RSS_HISTORY[@]}"; do
        sum_rss=$((sum_rss + value))
    done

    samples=${#GUARD_AVAILABLE_HISTORY[@]}
    ((samples > 0)) || samples=1
    GUARD_AVG_AVAILABLE_KIB=$((sum_available / samples))
    GUARD_AVG_RSS_KIB=$((sum_rss / samples))
    age_seconds=$(awk -v n="$samples" -v sec="$INTERVAL" 'BEGIN { printf "%.0f", n * sec }')

    if ((samples < GUARD_MIN_SAMPLES)); then
        MEMORY_GUARD="WARMING UP — collecting ${age_seconds}s of memory history"
        MEMORY_GUARD_COLOR=$CYAN
    elif ((GUARD_AVG_AVAILABLE_KIB < GUARD_CRIT_AVAILABLE_KIB || \
            GUARD_AVG_RSS_KIB >= GUARD_CRIT_RSS_KIB)); then
        MEMORY_GUARD='CRITICAL — sustained memory pressure; finish this image and restart ComfyUI'
        MEMORY_GUARD_COLOR=$RED
    elif ((GUARD_AVG_AVAILABLE_KIB < GUARD_WARN_AVAILABLE_KIB || \
            GUARD_AVG_RSS_KIB >= GUARD_WARN_RSS_KIB || \
            COMFY_SWAP_KIB >= GUARD_WARN_SWAP_KIB)); then
        MEMORY_GUARD='CAUTION — sustained memory growth; watch the next few images closely'
        MEMORY_GUARD_COLOR=$YELLOW
    elif ((RAM_AVAILABLE_KIB < GUARD_CRIT_AVAILABLE_KIB)); then
        MEMORY_GUARD='OK — transient render spike; rolling memory headroom remains healthy'
        MEMORY_GUARD_COLOR=$GREEN
    else
        MEMORY_GUARD='OK — rolling memory headroom is healthy'
        MEMORY_GUARD_COLOR=$GREEN
    fi
}

read_cpu_counters() {
    local cpu user nice system idle iowait irq softirq steal
    read -r cpu user nice system idle iowait irq softirq steal _ < "$PROC_ROOT/stat"
    CPU_SAMPLE_IDLE=$((idle + iowait))
    CPU_SAMPLE_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
}

load_cpu_util() {
    local previous_total=$CPU_PREV_TOTAL previous_idle=$CPU_PREV_IDLE
    local delta_total delta_idle delta_busy

    read_cpu_counters
    delta_total=$((CPU_SAMPLE_TOTAL - previous_total))
    delta_idle=$((CPU_SAMPLE_IDLE - previous_idle))
    delta_busy=$((delta_total - delta_idle))

    if ((delta_total > 0)); then
        CPU_UTIL=$(awk -v busy="$delta_busy" -v total="$delta_total" 'BEGIN {
            pct = busy * 100 / total
            if (pct < 0) pct = 0
            if (pct > 100) pct = 100
            printf "%.1f", pct
        }')
    else
        CPU_UTIL='N/A'
    fi

    CPU_PREV_TOTAL=$CPU_SAMPLE_TOTAL
    CPU_PREV_IDLE=$CPU_SAMPLE_IDLE
}

load_gpu_metrics() {
    local output
    if ! output=$(amd-smi metric --gpu "$GPU_ID" 2>&1); then
        METRIC_ERROR=$output
        return 1
    fi
    METRIC=$output
    METRIC_ERROR=''

    TEMP_GPU=$(value_or_na "$(field_value EDGE)")
    TEMP_HOTSPOT=$(value_or_na "$(field_value HOTSPOT)")
    TEMP_VRAM=$(value_or_na "$(field_value MEM)")

    POWER_VAL=$(value_or_na "$(field_value SOCKET_POWER)")
    POWER_UNIT=$(field_unit SOCKET_POWER)
    [[ -n "$POWER_UNIT" && "$POWER_UNIT" != "N/A" ]] || POWER_UNIT='W'

    GFXCLK_VAL=$(value_or_na "$(field_after GFX_0 CLK)")
    GFXCLK_UNIT=$(field_unit_after GFX_0 CLK)
    [[ -n "$GFXCLK_UNIT" && "$GFXCLK_UNIT" != "N/A" ]] || GFXCLK_UNIT='MHz'

    GPU_UTIL=$(value_or_na "$(field_value GFX_ACTIVITY)")
    MEM_UTIL=$(value_or_na "$(field_value UMC_ACTIVITY)")

    VRAM_USED=$(value_or_na "$(field_value USED_VRAM)")
    VRAM_TOTAL=$(value_or_na "$(field_value TOTAL_VRAM)")
    VRAM_FREE=$(value_or_na "$(field_value FREE_VRAM)")
    VRAM_PCT=$(calc_pct "$VRAM_USED" "$VRAM_TOTAL")

    FAN_SPEED_RAW=$(value_or_na "$(field_after FAN SPEED)")
    FAN_MAX_RAW=$(value_or_na "$(field_after FAN MAX)")
    FAN_RPM=$(value_or_na "$(field_after FAN RPM)")
    FAN_PCT=$(value_or_na "$(field_after FAN USAGE)")
}

draw_dashboard() {
    local now host vram_detail ram_detail swap_detail vram_color ram_color swap_color
    local comfy_detail comfy_color
    now=$(date '+%Y-%m-%d %H:%M:%S')
    host=${HOSTNAME:-$(hostname -s 2>/dev/null || printf 'linux')}

    printf '%s%sBF95 AMD VRAMWATCH%s  %sGPU %s%s  %s%s%s  %s
' \
        "$BOLD" "$WHITE" "$RESET" "$BOLD" "$GPU_ID" "$RESET" \
        "$DIM" "$host" "$RESET" "$now"
    rule

    if [[ -n "$METRIC_ERROR" ]]; then
        printf '
%s%sAMD-SMI ERROR%s
' "$BOLD" "$RED" "$RESET"
        printf '  Could not read GPU %s. amd-smi reported:

' "$GPU_ID"
        printf '  %s
' "$METRIC_ERROR"
        printf '
  Check the GPU index with: amd-smi list
'
        return
    fi

    vram_detail="$(human_mib "$VRAM_USED") / $(human_mib "$VRAM_TOTAL")"
    ram_detail="$(human_kib "$RAM_USED_KIB") / $(human_kib "$RAM_TOTAL_KIB")"
    swap_detail="$(human_kib "$SWAP_USED_KIB") / $(human_kib "$SWAP_TOTAL_KIB")"
    vram_color=$(memory_color "$VRAM_PCT")
    ram_color=$(memory_color "$RAM_PCT")
    swap_color=$(memory_color "$SWAP_PCT")

    section 'MEMORY'
    meter 'VRAM' "$vram_detail" "$VRAM_PCT" "$vram_color"
    meter 'System RAM' "$ram_detail" "$RAM_PCT" "$ram_color"
    meter 'System Swap' "$swap_detail" "$SWAP_PCT" "$swap_color"
    printf '  %-12s %-23s         %sAvailable system RAM: %s%s
' \
        'Free VRAM' "$(human_mib "$VRAM_FREE")" "$DIM" "$(human_kib "$RAM_AVAILABLE_KIB")" "$RESET"

    section 'COMFYUI PROCESS'
    if [[ -n "$COMFY_PID" ]]; then
        comfy_detail="$(human_kib "$COMFY_RSS_KIB") RAM + $(human_kib "$COMFY_SWAP_KIB") swap"
        comfy_color=$(memory_color "$COMFY_RSS_PCT")
        meter 'Comfy RSS' "$comfy_detail" "$COMFY_RSS_PCT" "$comfy_color"
        printf '  %-12s %-23s         %sAnon: %s  Total: %s%s
' \
            'PID' "$COMFY_PID" "$DIM" "$(human_kib "$COMFY_ANON_KIB")" "$(human_kib "$COMFY_TOTAL_KIB")" "$RESET"
        printf '  %-12s %-23s         %sUptime: %s%s\n' \
            'RSS growth' "$(human_kib_signed "$COMFY_GROWTH_KIB") so far" \
            "$DIM" "$(human_duration "$COMFY_UPTIME_SECONDS")" "$RESET"
        printf '  %-12s %-23s         %sKernel VmHWM: %s%s\n' \
            'Peak RSS' "$(human_kib "$WATCH_PEAK_RSS_KIB") so far" \
            "$DIM" "$(human_kib "$COMFY_VM_HWM_KIB")" "$RESET"
        printf '  %-12s %-23s         %sLong: %s over %s%s\n' \
            'RSS trend' "$(human_kib_signed "$RSS_SHORT_TREND_KIB") over $(human_duration "$RSS_SHORT_SPAN_SECONDS")" \
            "$DIM" "$(human_kib_signed "$RSS_LONG_TREND_KIB")" \
            "$(human_duration "$RSS_LONG_SPAN_SECONDS")" "$RESET"
        printf '  %-12s %-23s         %sTotal faults: %s%s\n' \
            'Major faults' "$(human_fault_rate "$COMFY_MAJFLT_RATE")" \
            "$DIM" "$COMFY_MAJFLT" "$RESET"
        printf '  %-12s %-23s         %sLast RSS delta: %s%s\n' \
            'Low Avail' "$(human_kib "$WATCH_MIN_AVAILABLE_KIB") so far" \
            "$DIM" "$(human_kib_signed "$COMFY_DELTA_KIB")" "$RESET"
    else
        printf '  %sNo matching ComfyUI process found%s
' "$DIM" "$RESET"
    fi

    section 'MEMORY PRESSURE'
    printf '  %-12s %-23s         %sSwap out: %s%s
' \
        'Swap in' "$(human_mib_rate "$SWAPIN_MIB_S")" "$DIM" "$(human_mib_rate "$SWAPOUT_MIB_S")" "$RESET"
    printf '  %-12s %-23s         %sFull avg10: %s%%%s
' \
        'PSI some' "${MEM_PSI_SOME}% avg10" "$DIM" "$MEM_PSI_FULL" "$RESET"
    printf '  %-12s %-23s         %sAvg Comfy RSS: %s%s\n' \
        "${GUARD_WINDOW_SECONDS}s average" "Avail: $(human_kib "$GUARD_AVG_AVAILABLE_KIB")" \
        "$DIM" "$(human_kib "$GUARD_AVG_RSS_KIB")" "$RESET"

    section 'ACTIVITY'
    meter 'GPU Util' '' "$GPU_UTIL" "$BLUE"
    meter 'CPU Util' '' "$CPU_UTIL" "$CYAN"
    meter 'Mem Ctrl' '' "$MEM_UTIL" "$MAGENTA"

    section 'TEMPERATURES'
    temperature_meter 'GPU Core' "$TEMP_GPU" 100
    temperature_meter 'Hotspot' "$TEMP_HOTSPOT" 110
    temperature_meter 'VRAM Temp' "$TEMP_VRAM" 110

    section 'COOLING / POWER / CLOCK'
    meter 'Fan' "${FAN_RPM} RPM" "$FAN_PCT" "$CYAN"
    printf '  %-12s %-23s         %sRaw fan: %s / %s%s
' \
        'Power' "${POWER_VAL} ${POWER_UNIT}" "$DIM" "$FAN_SPEED_RAW" "$FAN_MAX_RAW" "$RESET"
    printf '  %-12s %s %s
' 'GFX Clock' "$GFXCLK_VAL" "$GFXCLK_UNIT"

    printf '\n  %s%sMemory guard:%s %s%s\n' \
        "$BOLD" "$MEMORY_GUARD_COLOR" "$RESET" "$MEMORY_GUARD" "$RESET"
    printf '%sRefresh: %ss  •  Guard: %ss average  •  Warn/Crit: avail <%s%%/%s%%, RSS >%s%%/%s%%%s\n' \
        "$DIM" "$INTERVAL" "$GUARD_WINDOW_SECONDS" \
        "$GUARD_WARN_AVAILABLE_PCT" "$GUARD_CRIT_AVAILABLE_PCT" \
        "$GUARD_WARN_RSS_PCT" "$GUARD_CRIT_RSS_PCT" "$RESET"
}

METRIC=''
METRIC_ERROR=''
FIRST_DRAW=1
COMFY_TRACK_PID=''
COMFY_BASE_RSS_KIB=0
COMFY_LAST_RSS_KIB=0
COMFY_LAST_MAJFLT=0
HISTORY_TRACK_PID=''
RSS_SHORT_HISTORY=()
RSS_LONG_HISTORY=()
WATCH_PEAK_RSS_KIB=0
WATCH_MIN_AVAILABLE_KIB=0
RSS_SHORT_TREND_KIB=0
RSS_LONG_TREND_KIB=0
RSS_SHORT_SPAN_SECONDS=0
RSS_LONG_SPAN_SECONDS=0
GUARD_TRACK_PID=''
GUARD_AVAILABLE_HISTORY=()
GUARD_RSS_HISTORY=()
GUARD_AVG_AVAILABLE_KIB=0
GUARD_AVG_RSS_KIB=0
MEMORY_GUARD='WARMING UP'
MEMORY_GUARD_COLOR=$CYAN

# CPU utilization and swap activity are deltas between /proc samples.
read_cpu_counters
CPU_PREV_TOTAL=$CPU_SAMPLE_TOTAL
CPU_PREV_IDLE=$CPU_SAMPLE_IDLE
CPU_UTIL='N/A'
read_swap_counters
SWAP_PREV_IN=$SWAPIN_SAMPLE
SWAP_PREV_OUT=$SWAPOUT_SAMPLE
SWAPIN_MIB_S='0.00'
SWAPOUT_MIB_S='0.00'
sleep 0.1

cleanup() {
    if ((INTERACTIVE)); then
        printf '\033[?25h%s\n' "$RESET"
    fi
}

trap cleanup EXIT
trap 'exit 0' INT TERM

if ((INTERACTIVE)); then
    printf '\033[?25l'
fi

while :; do
    load_system_ram
    load_comfy_process
    update_session_history
    update_memory_guard
    load_swap_activity
    load_gpu_metrics || true
    load_cpu_util

    if ((INTERACTIVE)); then
        if ((FIRST_DRAW)); then
            printf '\033[2J\033[H'
            FIRST_DRAW=0
        else
            # Clear the old dashboard before drawing the next one so a long
            # warning cannot leave trailing text after the state changes.
            printf '\033[H\033[J'
        fi
    fi

    draw_dashboard

    ((RUN_ONCE)) && break
    sleep "$INTERVAL"
done
