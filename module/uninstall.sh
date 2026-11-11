#!/system/bin/sh
# AlwaysStrong uninstall — clean every artifact we created.

MODDIR=${0%/*}
CONFIG_DIR=/data/adb/tricky_store

# Kill all running module processes (both attestation engines)
for proc in TEESimulator supervisor daemon TrickyStoreOSS; do
    for pid in $(pidof "$proc" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null
    done
done
pkill -9 -f TEESimulator 2>/dev/null || true
pkill -9 -f org.matrix.TEESimulator 2>/dev/null || true
pkill -9 -f io.github.beakthoven.TrickyStoreOSS 2>/dev/null || true

# Kill GMS + Vending so they reload without our hooks. Vending takes a full
# force-stop (contained, clears its children). GMS takes am kill, not force-stop:
# both route through system_server so they reach the SELinux-isolated DroidGuard
# sandbox that killall cannot (killall still runs after, for ROMs where am fails),
# but force-stopping GMS would cascade through the
# package dependency graph and tear down the manager app mid-uninstall.
am force-stop com.android.vending >/dev/null 2>&1
am kill com.google.android.gms >/dev/null 2>&1
killall -9 com.google.android.gms.unstable com.android.vending com.android.vending:background com.android.vending:quick_launch >/dev/null 2>&1

# Remove the DenyList entries we added (entries only, never the enforcement
# toggle). Only on Magisk; rm by package drops all of that package's processes.
if command -v magisk >/dev/null 2>&1; then
    for p in com.android.vending com.google.android.gms com.google.android.gsf \
             com.google.android.gm com.anu.developers3k.rootchecker \
             gr.nikolasspyr.integritycheck io.github.vvb2060.keyattestation; do
        magisk --denylist rm "$p" >/dev/null 2>&1
    done
fi

# Restore any ProjectInfinity-X Settings.Secure spoof config that rom_spoof_block
# cleared (one file per key under alwaysstrong/rom_secure_backup), so removing
# AlwaysStrong frees the ROM's own PI spoofer again. Must run BEFORE the directory
# is removed below. Best-effort: needs the Settings provider (device booted).
BK_SECURE="$CONFIG_DIR/alwaysstrong/rom_secure_backup"
if [ -d "$BK_SECURE" ] && command -v settings >/dev/null 2>&1; then
    for f in "$BK_SECURE"/*; do
        [ -f "$f" ] || continue
        settings put secure "$(basename "$f")" "$(cat "$f")" 2>/dev/null
    done
fi

# Our settings, state and logs (one directory since 1.0.5)
rm -rf "$CONFIG_DIR/alwaysstrong"

# Wipe TEESimulator runtime state
rm -rf "$CONFIG_DIR/persistent_keys"
rm -f "$CONFIG_DIR/tee_status.txt"
rm -f "$CONFIG_DIR/boot_hash.bin" "$CONFIG_DIR/boot_key.bin"

# JingMatrix TEESimulator data dir: drop the config, the root-of-trust override
# and the harvested record we generated so a reinstall (or a switch to another
# engine) starts clean and re-harvests instead of reusing a stale zeroed key.
# keybox.xml there is a symlink into tricky_store and is left alone.
rm -f /data/adb/teesim/config.json /data/adb/teesim/overrides.json \
      /data/adb/teesim/harvested.json 2>/dev/null

# Global PIF prop we dropped for the TEE PatchLevelManager (sync_patch.sh)
rm -f /data/adb/pif.prop

# A stale playintegrityfix folder from a very old shim-based AlwaysStrong build
# can be cleaned up here — but this exact path is ALSO where a user's OWN
# standalone PlayIntegrityFork / Fix inject-s lives (the module id is shared, and
# the "Lite" line depends on that separate module). Never delete the user's real
# module on uninstall: on the Lite line (ENGINE=none) the folder is always theirs,
# and on any line a folder whose module.prop identifies a real Fork / Fix inject-s
# / id-squatting keystore toolkit is theirs too. Only remove a folder that is clearly not a live
# third-party module (a true leftover shim with no recognizable module.prop).
PIF_MOD=/data/adb/modules/playintegrityfix
if [ -d "$PIF_MOD" ]; then
    keep_pif=0
    [ -f "$MODDIR/engine.sh" ] && grep -q '^ENGINE=none' "$MODDIR/engine.sh" 2>/dev/null && keep_pif=1
    if [ "$keep_pif" = 0 ] && [ -f "$PIF_MOD/module.prop" ]; then
        grep -qiE 'Fork|osm0sis|PlayIntegrityFix|inject|chiteroman|KOWX712|MeowDump|ntegrity.?[Bb]ox|webuiIcon' \
            "$PIF_MOD/module.prop" 2>/dev/null && keep_pif=1
    fi
    [ "$keep_pif" = 0 ] && rm -rf "$PIF_MOD" 2>/dev/null
fi

# Restore ROM-level spoof engines that rom_spoof_block.sh disabled, so removing
# AlwaysStrong frees the ROM's own PixelProps / pihooks / entryhooks again.
# Only clear a prop if it STILL holds the exact "disabled" value we wrote — that
# way we never clobber a value the ROM set for itself. Takes effect next boot.
revert_spoof() {
    [ "$(resetprop "$1" 2>/dev/null)" = "$2" ] && resetprop -p --delete "$1" 2>/dev/null
}
revert_spoof persist.sys.pihooks.disable.gms_props                 true
revert_spoof persist.sys.pihooks.disable.gms_key_attestation_block true
revert_spoof persist.sys.entryhooks_enabled                        false
revert_spoof persist.sys.spoof.gms                                 false
revert_spoof persist.sys.pixelprops.gms                            false
revert_spoof persist.sys.pixelprops.gapps                          false
revert_spoof persist.sys.pixelprops.google                         false
revert_spoof persist.sys.pixelprops.pi                             false
revert_spoof persist.sys.pp.gms                                    false
revert_spoof persist.sys.pp.finsky                                 false
revert_spoof persist.sys.pihooks.first_api_level                   ""
revert_spoof persist.sys.pihooks.security_patch                    ""

# Keep keybox.xml and security_patch.txt — user may want them for reinstall.
