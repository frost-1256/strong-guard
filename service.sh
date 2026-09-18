#!/system/bin/sh
# Strong Guard service

MODDIR=${0%/*}
SGMOD=$MODDIR
. "$MODDIR/lib.sh"
sg_conf
sg_dirs

if [ "$1" = "daemon" ]; then
	printf '%s' "$$" > "$SG/daemon.pid"
	log "service: daemon start (pid $$)"
	until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do sleep 10; done
	sleep 90

	[ -s "$VAULT/keybox-good.xml" ] || cp -f "$OMK_KEYBOX" "$VAULT/keybox-good.xml" 2>/dev/null

	sync_omk_vbhash

	if ! keybox_check_file "$OMK_KEYBOX"; then
		log "service: current keybox failed initial checks"
		[ "$AUTO_ROTATE" = 1 ] && rotate_now
	fi

	while :; do
		sg_conf
		health_check
		sleep $((CHECK_INTERVAL_MIN * 60))
	done
fi

# service (non-daemon) invocation: start daemon once
pid=$(cat "$SG/daemon.pid" 2>/dev/null)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
	exit 0
fi

setsid /system/bin/sh "$MODDIR/service.sh" daemon </dev/null >/dev/null 2>&1 &
exit 0
