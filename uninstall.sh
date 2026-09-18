#!/system/bin/sh
# Strong Guard uninstall

SG=/data/adb/strong_guard
pid=$(cat "$SG/daemon.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
	kill "$pid" 2>/dev/null
	sleep 1
	kill -9 "$pid" 2>/dev/null
fi
rm -f "$SG/daemon.pid"
rm -rf "$SG/state/rotating"
exit 0
