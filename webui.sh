#!/system/bin/sh
# Strong Guard WebUI backend
# usage: webui.sh {info|start-rotate|start-check|fetch|log|set key value}

MODDIR=${0%/*}
SGMOD=$MODDIR
. "$MODDIR/lib.sh"
sg_conf
sg_dirs

fmt_epoch() {
	[ -n "$1" ] || { echo "-"; return; }
	if [ -n "$BB" ]; then
		$BB date -u -d "@$1" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo "$1"
	else
		echo "$1"
	fi
}

case "$1" in
	info)
		nowts=$(now)
		exp=$(keybox_min_expiry "$OMK_KEYBOX")
		left=""
		[ -n "$exp" ] && left=$(( (exp - nowts) / 86400 ))
		ec=$(keybox_certinfo "$OMK_KEYBOX" 2>/dev/null | head -n1 | awk '{print $1}')
		ecafter=$(keybox_certinfo "$OMK_KEYBOX" 2>/dev/null | head -n1 | awk '{print $3}')
		daemonpid=$(cat "$SG/daemon.pid" 2>/dev/null)
		daemonstate=stopped
		[ -n "$daemonpid" ] && kill -0 "$daemonpid" 2>/dev/null && daemonstate=running
		echo "time=$(date '+%Y-%m-%d %H:%M:%S')"
		echo "omk=$(omk_running && echo yes || echo no)"
		echo "daemon=$daemonstate"
		echo "rotating=$([ -d "$STATE/rotating" ] && echo yes || echo no)"
		echo "checking=$([ -f "$STATE/checking" ] && echo yes || echo no)"
		echo "expiry_epoch=$exp"
		echo "expiry_str=$(fmt_epoch "$exp")"
		echo "expiry_days=$left"
		echo "ec_serial=$ec"
		echo "ec_after=$ecafter"
		echo "rsa=$(has_block "$OMK_KEYBOX" rsa && echo yes || echo no)"
		echo "verdict=$(cat "$STATE/last_verdict" 2>/dev/null)"
		echo "verdict_ts=$(cat "$STATE/last_verdict.ts" 2>/dev/null)"
		echo "fetch_ts=$(cat "$STATE/last_fetch.ts" 2>/dev/null)"
		echo "sources=$SOURCES"
		echo "auto_rotate=$AUTO_ROTATE"
		echo "notify=$NOTIFY"
		echo "ci=$CHECK_INTERVAL_MIN"
		echo "vi=$VERDICT_INTERVAL_H"
		echo "fi=$FETCH_INTERVAL_H"
		echo "ew=$EXPIRY_WARN_DAYS"
		;;
	start-rotate)
		if [ -d "$STATE/rotating" ]; then echo busy; exit 0; fi
		setsid /system/bin/sh -c "sh '$MODDIR/action.sh' rotate > '$STATE/last_rotate.out' 2>&1" </dev/null >/dev/null 2>&1 &
		echo started
		;;
	start-check)
		if [ -f "$STATE/checking" ]; then echo busy; exit 0; fi
		touch "$STATE/checking"
		setsid /system/bin/sh -c "sh '$MODDIR/action.sh' check > '$STATE/last_check.out' 2>&1; rm -f '$STATE/checking'" </dev/null >/dev/null 2>&1 &
		echo started
		;;
	fetch)
		setsid /system/bin/sh -c "cd '$SGMOD' && SGMOD='$SGMOD' . ./lib.sh && sg_conf && sg_dirs && fetch_all force" </dev/null >/dev/null 2>&1 &
		echo started
		;;
	log)
		tail -n 80 "$LOG" 2>/dev/null
		;;
	set)
		key=$2
		val=$3
		case "$key" in
			AUTO_ROTATE|NOTIFY|CHECK_INTERVAL_MIN|VERDICT_INTERVAL_H|FETCH_INTERVAL_H|EXPIRY_WARN_DAYS) ;;
			*) echo "err:unknown key"; exit 0;;
		esac
		case "$val" in
			''|*[!0-9]*) echo "err:bad value"; exit 0;;
		esac
		grep -v "^$key=" "$CONF" > "$CONF.tmp" 2>/dev/null
		mv -f "$CONF.tmp" "$CONF" 2>/dev/null
		printf '%s=%s\n' "$key" "$val" >> "$CONF"
		echo ok
		;;
	*)
		echo "usage: $0 {info|start-rotate|start-check|fetch|log|set key value}"
		;;
esac
