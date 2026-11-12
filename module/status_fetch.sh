#!/system/bin/sh
# Fetch the keybox status (e.g. "🟢🟢🟢") from the project's keybox mirror
# and prepend it to module.prop's description line so KSU/APatch/MMRL show
# the current health at a glance.
#
# Format: "description=🟢🟢🟢 <base>"   ← status first, then a space, then base
# Base text is the canonical line from description.txt (so we don't have
# to parse-and-strip arbitrary emoji prefixes — single source of truth).
#
# Called from action.sh (every press) and service.sh (hourly + first boot).
# Idempotent: only rewrites module.prop if the prefix actually changed.

URL="${STATUS_URL:-http://evoker.qzz.io/status}"
MODPATH="${MODPATH:-/data/adb/modules/tricky_store}"
PROP="$MODPATH/module.prop"
BASE_FILE="$MODPATH/description.txt"
CONFIG_DIR=/data/adb/tricky_store
[ -f "$MODPATH/as_store.sh" ] && . "$MODPATH/as_store.sh"
TIMEOUT=10   # idle timeout per downloader; the outer cap per engine is CAP
CAP=45

# mode: "manual" (action button — always writes module.prop)
#       "auto"   (service.sh hourly — skips the write when status_indicator=0)
#       "notify" (WebUI status-notification toggle ON — fetch and post ONE
#                 notification immediately, never writing the module.prop prefix,
#                 so it works even with the indicator off)
#       "strip"  (WebUI indicator OFF — rewrite description to base, no fetch)
MODE="${1:-auto}"

[ -f "$PROP" ] || exit 1
[ -f "$BASE_FILE" ] || exit 1

# Strip mode: restore description= to the canonical base text from
# description.txt, removing any status prefix. Used by the WebUI when the
# user disables the indicator — they expect the emoji prefix to vanish from
# the module list immediately, not on the next reboot.
if [ "$MODE" = "strip" ]; then
    base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
    [ -z "$base" ] && exit 4
    want="description=${base}"
    have=$(grep -m1 '^description=' "$PROP")
    [ "$have" = "$want" ] && exit 0
    tmp="${PROP}.tmp"
    awk -v new="$want" '
        !done && /^description=/ { print new; done=1; next }
        { print }
    ' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
    exit 0
fi

# Auto path + user opted out of indicator → exit without touching module.prop.
# Hourly fp/keybox checks still happen in service.sh; only the visible 🟢
# prefix is gated. Manual action presses always update regardless.
if [ "$MODE" != "manual" ] && [ "$MODE" != "notify" ] && ! as_on status_indicator && ! as_on status_notify; then
    exit 0
fi

BB=""
for p in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -f "$p" ] && BB="$p" && break
done

# Prefer the bundled native rustls fetcher: busybox wget's TLS stalls on the
# status/keybox CDN. asfetch with no -o writes the body straight to stdout.
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="${MODPATH:-/data/adb/modules/tricky_store}"
case "$(uname -m)" in
    aarch64)       SF_ABI=arm64-v8a ;;
    armv7*|armv8l) SF_ABI=armeabi-v7a ;;
    x86_64)        SF_ABI=x86_64 ;;
    i?86)          SF_ABI=x86 ;;
    *)             SF_ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$SF_ABI/asfetch"

# bounded SECS cmd... — run cmd under a hard wall-clock cap. A fetcher that
# never returns (asfetch / wget / curl stuck on a dead route, a hung DNS, a
# TLS stall) used to freeze the whole Action: status_fetch and the first-tap
# keybox fetch called it with no bound at all, so the screen sat after the last
# row with no "done" until the user gave up. Every network step now goes through
# this; the caller falls through to the next engine when the cap trips.
# toybox timeout (Android 10+) and busybox timeout both take -k; -k SIGKILLs a
# command that ignores the SIGTERM, which a `sh` waiting on a child would defer.
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# No single downloader is reliable across devices (asfetch fails to connect on
# some, busybox wget stalls on the mirror CDN on others) — try each in turn and
# take the first non-empty body.
get_status() {
    if [ -n "$SF_ABI" ] && [ -x "$ASFETCH" ]; then
        _b=$(bounded "$CAP" "$ASFETCH" -T "$TIMEOUT" "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if [ -n "$BB" ]; then
        _b=$(bounded "$CAP" "$BB" wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v curl >/dev/null 2>&1; then
        _b=$(bounded "$CAP" curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time 40 "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    if command -v wget >/dev/null 2>&1; then
        _b=$(bounded "$CAP" wget -q -T "$TIMEOUT" -O - "$URL" 2>/dev/null | tr -d '\r\n' | head -c 64)
        [ -n "$_b" ] && { echo "$_b"; return 0; }
    fi
    return 1
}

# --- optional status notification (opt-in: status_notify, default off) -------
# Post one self-replacing notification with the current integrity level whenever
# the server status CHANGES (hourly auto) or on every Action (manual). Off unless
# the WebUI Advanced toggle turns it on, and hourly is the only timer (no extra
# polling). MUST be posted as the Shell user (uid 2000): a notification posted by
# root for com.android.shell is accepted by the command but silently never shown.
_nq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
status_notify() {   # $1 = status string (emoji dots, already validated)
    # "notify" is the explicit WebUI toggle-on trigger: post regardless of the
    # stored flag (which may not have been flushed yet when this fires).
    [ "$MODE" = "notify" ] || as_on status_notify || return 0
    command -v cmd >/dev/null 2>&1 || return 0
    _s="$1"
    _last=$(st_get status_notify_last 2>/dev/null)
    st_set status_notify_last "$_s"
    # auto (hourly): only when it changed; manual (Action) / notify (toggle): always
    [ "$MODE" = "manual" ] || [ "$MODE" = "notify" ] || [ "$_s" != "$_last" ] || return 0
    _n=$(printf '%s' "$_s" | sed 's/🟢/G/g' | tr -cd 'G' | wc -c | tr -d ' ')
    case "$_n" in
        3) _lv="STRONG" ;;
        2) _lv="DEVICE" ;;
        1) _lv="BASIC" ;;
        *) _lv="CHANGE KEY" ;;
    esac
    _title="$_s  $_lv"
    _text="AlwaysStrong · $(date '+%H:%M')"
    # fixed tag "as_status" => each post replaces the previous one
    su 2000 -c "cmd notification post -S bigtext -t $(_nq "$_title") as_status $(_nq "$_text")" \
        >/dev/null 2>&1
}

new=$(get_status)
[ -z "$new" ] && exit 3
# A captive portal / hotel Wi-Fi answers every URL with an HTML login page. That
# is not a status — never stamp it into module.prop.
case "$new" in *'<'*|*'>'*|*'{'*) exit 3 ;; esac

# only a short emoji status is a real answer; skip notifying on anything else
case "$new" in *🟢*|*🔴*|*🟡*|*🟠*) status_notify "$new" ;; esac

base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
[ -z "$base" ] && exit 4

# Write the visible 🟢 prefix into module.prop only when the indicator is on
# (a manual Action press always writes, as before). The "notify" mode never
# writes, and the auto path with the indicator off fetched purely to drive the
# notification above, so neither re-stamps the prefix the user chose to hide.
if [ "$MODE" = "manual" ] || { [ "$MODE" = "auto" ] && as_on status_indicator; }; then
    want="description=${new} ${base}"
    have=$(grep -m1 '^description=' "$PROP")

    [ "$have" = "$want" ] && exit 0

    # Atomic rewrite: produce full file in tmp, swap in.
    tmp="${PROP}.tmp"
    awk -v new="$want" '
        !done && /^description=/ { print new; done=1; next }
        { print }
    ' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
fi
