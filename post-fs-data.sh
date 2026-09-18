#!/system/bin/sh
# Strong Guard - post-fs-data

MODDIR=${0%/*}
SG=/data/adb/strong_guard
mkdir -p "$SG/work" "$SG/vault" "$SG/state" "$SG/logs" "$SG/custom" 2>/dev/null

if [ ! -f "$SG/config.conf" ]; then
	cat > "$SG/config.conf" <<'EOF'
# Strong Guard configuration
CHECK_INTERVAL_MIN=60
FETCH_INTERVAL_H=12
VERDICT_INTERVAL_H=24
EXPIRY_WARN_DAYS=5
AUTO_ROTATE=1
NOTIFY=1
SYNC_VBHASH=1
SOURCES="meow yuri custom"
# Drop a private keybox at /data/adb/strong_guard/custom/keybox.xml
# to have it preferred over all public sources.
EOF
fi
