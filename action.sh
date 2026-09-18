#!/system/bin/sh
# Strong Guard action / CLI
# usage: action.sh [status|check|rotate|fetch|forcestrong]

MODDIR=${0%/*}
SGMOD=$MODDIR
. "$MODDIR/lib.sh"
sg_conf
sg_dirs

case "$1" in
	status|"")
		status
		;;
	check)
		run_verdict_check
		rc=$?
		echo "verdict check rc=$rc (0=strong pass, 1=strong fail, 2=unknown)"
		cat "$STATE/last_verdict" 2>/dev/null
		;;
	rotate)
		rotate_now
		echo "rotate rc=$?"
		;;
	fetch)
		fetch_all force
		ls -la "$WORK"/cand_*.xml 2>/dev/null
		;;
	forcestrong)
		printf '1' > "$STATE/force_rotate"
		echo "force flag set; service will rotate on next cycle"
		;;
	*)
		echo "usage: $0 [status|check|rotate|fetch]"
		;;
esac
