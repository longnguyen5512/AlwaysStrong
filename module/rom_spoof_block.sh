#!/system/bin/sh
# Block ROM-level Play Integrity spoof engines.
#
# Custom ROMs (LineageOS, EvolutionX, PixelOS, ...) ship their own pixel-prop /
# pihook / entryhook spoofers that fight ours: they re-set Build.* every boot,
# corrupt the attestation chain, and on STRONG checks the leaked extra hooks
# get flagged. We disable the ROM engines so AlwaysStrong is the single
# source of truth for the spoofed fingerprint.
#
# Opt-out:  rom_spoof_block=0 in alwaysstrong/config (WebUI Advanced tab).
# Called from post-fs-data.sh (early, before GMS starts).

CONFIG_DIR=/data/adb/tricky_store
MODPATH="${MODPATH:-${0%/*}}"
[ -f "$MODPATH/as_store.sh" ] && . "$MODPATH/as_store.sh"
as_on rom_spoof_block || exit 0

# Phase selector: "props" (default, post-fs-data) disables the prop-based ROM
# spoofers with resetprop; "settings" (after sys.boot_completed, from service.sh)
# clears ProjectInfinity-X's newer Settings.Secure spoof config, which resetprop
# cannot reach. The detection gate below applies to both.
MODE="${1:-props}"

GMS_PROPS_FILE="/data/system/gms_certified_props.json"

# Detection — only act if a ROM spoof engine (or a spoofing custom ROM) is
# present. The prop/version list mirrors PlayIntegrityFork's common_setup.sh
# (osm0sis), which tracks the current AOSPA / PixelOS / Afterlife / EvolutionX /
# crDroid PropImitationHooks / PixelPropsUtils engines.
gate=0
resetprop 2>/dev/null | grep -qE 'persist\.sys\.(pihooks|entryhooks|spoof|pixelprops|pp)' && gate=1
[ -n "$(resetprop ro.aospa.version 2>/dev/null)" ] && gate=1
[ -n "$(resetprop net.pixelos.version 2>/dev/null)" ] && gate=1
[ -n "$(resetprop ro.afterlife.version 2>/dev/null)" ] && gate=1
[ -f "$GMS_PROPS_FILE" ] && gate=1
# ProjectInfinity-X bakes its PixelPropsUtils into the framework and its
# switches (persist.sys.pixelprops / .gms) default to ON when the prop is
# ABSENT, so a fresh boot shows no spoof prop to match on line 25. Detect the
# ROM by its own identity instead (ro.build.display.id carries the ROM name).
for _rp in ro.build.display.id ro.build.version.incremental ro.infinity.version; do
    case "$(resetprop "$_rp" 2>/dev/null)" in *[Ii]nfinity*) gate=1; break ;; esac
done
[ "$gate" = "0" ] && exit 0

# ---- Phase: Settings.Secure (ProjectInfinity-X Android 16 / 17) --------------
# Current Infinity-X builds (Android 16 since Sept 2026, Android 17) dropped the
# persist.sys.pixelprops scheme for a Settings.Secure system service
# (PlayIntegritySpoofService / AxSpoofManagerService). The spoof is OFF unless
# spoof_pif_config is populated, and resetprop cannot see these, so the prop phase
# below is a no-op on those builds. Clear the ROM's spoof config so AlwaysStrong is
# the only spoofer. Back up each non-empty value once (one file per key) so
# uninstall.sh can restore it; a key already absent is left untouched. These keys
# are Infinity-specific, so on any other ROM every get returns null and this is a
# no-op. Runs from service.sh after boot_completed, where `settings` works.
if [ "$MODE" = "settings" ]; then
    command -v settings >/dev/null 2>&1 || exit 0
    BKDIR="$CONFIG_DIR/alwaysstrong/rom_secure_backup"
    for k in spoof_pif_config spoof_pif_vending spoof_pif_photos spoof_pif_netflix \
             spoof_pif_snapchat spoof_gameprops_config spoof_trickystore_target \
             spoof_trickystore_keybox spoof_trickystore_patch keybox_data; do
        v=$(settings get secure "$k" 2>/dev/null)
        [ "$v" = "null" ] && v=""
        [ -n "$v" ] || continue
        mkdir -p "$BKDIR" 2>/dev/null
        [ -f "$BKDIR/$k" ] || printf '%s' "$v" > "$BKDIR/$k"
        settings delete secure "$k" 2>/dev/null
    done
    exit 0
fi

set_persist() {
    resetprop -n -p "$1" "$2" 2>/dev/null
}

# Seed empty values for hooks that PihookGMS/EntryHooks read at startup, so
# the engine sees the slot already occupied and bails instead of writing its
# own. Skip if already set (don't clobber whatever the ROM has).
for hook in persist.sys.pihooks.first_api_level persist.sys.pihooks.security_patch; do
    resetprop 2>/dev/null | grep -q "$hook" || set_persist "$hook" ""
done

# Hard-disable the known ROM spoof toggles. The list + values mirror
# PlayIntegrityFork's common_setup.sh (osm0sis), plus ProjectInfinity-X's own
# PixelPropsUtils / KeyboxImitationHooks switches.
#
# IMPORTANT: on Infinity-X these read with a default of TRUE, so an ABSENT prop
# means the ROM spoof is ON. persist.sys.pixelprops.gms is the master switch:
# false turns off both the GMS Build spoof and the keybox attestation hooks;
# persist.sys.pixelprops turns off the general Pixel-props spoof. They must be
# SET to false, never deleted (see the keep-list below).
set_persist persist.sys.pihooks.disable.gms_props                 true
set_persist persist.sys.pihooks.disable.gms_key_attestation_block true
set_persist persist.sys.entryhooks_enabled                        false
set_persist persist.sys.spoof.gms                                 false
set_persist persist.sys.pixelprops                                false
set_persist persist.sys.pixelprops.gms                            false
set_persist persist.sys.pixelprops.gapps                          false
set_persist persist.sys.pixelprops.google                         false
set_persist persist.sys.pixelprops.pi                             false
set_persist persist.sys.pixelprops.qsb                            false
# ProjectInfinity-X Android 15 (PropsHooksUtils) extras. persist.sys.pixelprops.all
# is that branch's MASTER switch (default TRUE when absent) and gates the Pixel-5a
# Build spoof on GMS processes that .gms alone does NOT stop; .gphotos defaults TRUE
# too. Both are in the wipe KEEP-list below, or deleting them would revert to on.
set_persist persist.sys.pixelprops.all                           false
set_persist persist.sys.pixelprops.gphotos                       false
set_persist persist.sys.gameprops.enabled                        false
set_persist persist.sys.pixelprops.vending                        false
set_persist persist.sys.pp.gms                                    false
set_persist persist.sys.pp.finsky                                 false

# Wipe any LEFTOVER pihook/pixelprops props we did not explicitly set, to keep
# the prop table clean of spoof-engine identity markers that PI could
# fingerprint on (e.g. persist.sys.pihooks_MODEL holding a spoofed value).
#
# The toggles we just set are skipped. Deleting them would drop them back to
# their enabled-by-default state: that was the Infinity-X bug where our own
# post-fs-data pass set persist.sys.pixelprops.gms=false and then this wipe
# removed it, so the ROM spoof silently came back after every reboot.
KEEP=" persist.sys.pihooks.disable.gms_props persist.sys.pihooks.disable.gms_key_attestation_block persist.sys.pixelprops persist.sys.pixelprops.all persist.sys.pixelprops.gms persist.sys.pixelprops.gapps persist.sys.pixelprops.google persist.sys.pixelprops.gphotos persist.sys.pixelprops.pi persist.sys.pixelprops.qsb persist.sys.pixelprops.vending "
getprop 2>/dev/null | grep -E '(pihook|pixelprops)' | sed 's/^\[\(.*\)\]:.*/\1/' | \
while IFS= read -r prop; do
    [ -z "$prop" ] && continue
    case "$KEEP" in *" $prop "*) continue ;; esac
    resetprop -p --delete "$prop" 2>/dev/null || true
done

exit 0
