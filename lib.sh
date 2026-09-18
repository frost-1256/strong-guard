#!/system/bin/sh
# Strong Guard - shared library

SG=/data/adb/strong_guard
SGMOD=${SGMOD:-/data/adb/modules/strong_guard}
WORK=$SG/work
VAULT=$SG/vault
STATE=$SG/state
LOGDIR=$SG/logs
LOG=$LOGDIR/strong_guard.log
CONF=$SG/config.conf

OMK_KEYBOX=/data/misc/keystore/omk/keybox.xml
OMK_MOD_KEYBOX=/data/adb/modules/oh_my_keymint/keybox.xml
OMK_LOG=/data/misc/keystore/omk/keymint.log
TS_KEYBOX=/data/adb/tricky_store/keybox.xml
CHECKER=gr.nikolasspyr.integritycheck

CRL_URL=https://android.googleapis.com/attestation/status
CRL_FILE=$STATE/status.json
CRL_TS=$STATE/status.ts

MEOW_URL=https://raw.githubusercontent.com/MeowDump/MeowDump/refs/heads/main/Megatron
YURI_URL=https://raw.githubusercontent.com/Yurii0307/yurikey/main/key
CUSTOM_KEYBOX=$SG/custom/keybox.xml

BB=/data/adb/ksu/bin/busybox
[ -x "$BB" ] || BB=""

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

sg_conf() {
	CHECK_INTERVAL_MIN=60
	FETCH_INTERVAL_H=12
	VERDICT_INTERVAL_H=24
	EXPIRY_WARN_DAYS=5
	AUTO_ROTATE=1
	NOTIFY=1
	SOURCES="meow yuri custom"
	# shellcheck disable=SC1090
	[ -f "$CONF" ] && . "$CONF"
}

sg_dirs() { mkdir -p "$SG" "$WORK" "$VAULT" "$STATE" "$LOGDIR" "$SG/custom"; }

now() { date +%s; }

notify() {
	[ "$NOTIFY" = 1 ] || return 0
	cmd notification post -S bigtext -t "Strong Guard" sg_status "$1" >/dev/null 2>&1
}

# ---------- network / decoding ----------

fetch_url() { # url out
	local url=$1 out=$2
	rm -f "$out"
	if curl -fsSL --connect-timeout 15 --max-time 180 "$url" -o "$out" 2>/dev/null && [ -s "$out" ]; then
		return 0
	fi
	if [ -n "$BB" ] && $BB wget -q --no-check-certificate -T 20 -O "$out" "$url" 2>/dev/null && [ -s "$out" ]; then
		return 0
	fi
	return 1
}

decode_meow() { # in out  (base64 x10 -> hex -> rot13)
	local in=$1 out=$2 cur next i
	cur=$WORK/.dec.$$
	cp -f "$in" "$cur" || return 1
	i=0
	while [ "$i" -lt 10 ]; do
		next=$cur.$i
		base64 -d "$cur" > "$next" 2>/dev/null || { rm -f "$cur" "$next"; return 1; }
		rm -f "$cur"
		cur=$next
		i=$((i + 1))
	done
	if ! xxd -r -p "$cur" > "$cur.hex" 2>/dev/null; then
		[ -n "$BB" ] && $BB xxd -r -p "$cur" > "$cur.hex" 2>/dev/null
	fi
	rm -f "$cur"
	if [ ! -s "$cur.hex" ]; then rm -f "$cur.hex"; return 1; fi
	tr 'A-Za-z' 'N-ZA-Mn-za-m' < "$cur.hex" > "$out" 2>/dev/null
	rm -f "$cur.hex"
	[ -s "$out" ]
}

decode_b64() { # in out
	base64 -d "$1" > "$2" 2>/dev/null && [ -s "$2" ]
}

# ---------- keybox inspection ----------

# per-cert "SERIAL NOTAFTER" lines (hex serial uppercase, UTC YYYYMMDDHHMMSS)
keybox_certinfo() { # keybox
	local f=$1 tmp b line ser after
	tmp=$WORK/.cb.$$
	rm -rf "$tmp"; mkdir -p "$tmp"
	awk -v d="$tmp" '
		/-----BEGIN CERTIFICATE-----/ {n++; f=d"/c" n ".b64"; inb=1; next}
		inb && /-----END CERTIFICATE-----/ {inb=0; next}
		inb {
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/[ \t\r]+$/, "", line)
			if (length(line)) print line > f
		}
	' "$f"
	for b in "$tmp"/c*.b64; do
		[ -f "$b" ] || continue
		base64 -d "$b" > "$b.der" 2>/dev/null || continue
		line=$(xxd -p "$b.der" 2>/dev/null | tr -d '\n' | awk -f "$SGMOD/bin/derparse.awk")
		case "$line" in *parse_error*) continue;; esac
		ser=$(printf '%s\n' "$line" | sed -n 's/^serial://p')
		before=$(printf '%s\n' "$line" | sed -n 's/^notBefore://p')
		after=$(printf '%s\n' "$line" | sed -n 's/^notAfter://p')
		[ -n "$ser" ] && [ -n "$after" ] && printf '%s %s %s\n' "$ser" "$before" "$after"
	done
	rm -rf "$tmp"
}

ymd2epoch() { printf '%s\n' "$1" | awk -f "$SGMOD/bin/ymd2epoch.awk"; }
hex2dec() { printf '%s\n' "$1" | awk -f "$SGMOD/bin/hex2dec.awk"; }

keybox_min_expiry() { # keybox -> epoch of earliest notAfter
	local f=$1 min="" e ser before after
	while read -r ser before after; do
		[ -n "$after" ] || continue
		e=$(ymd2epoch "$after")
		[ -n "$e" ] || continue
		if [ -z "$min" ] || [ "$e" -lt "$min" ]; then min=$e; fi
	done <<-EOF
	$(keybox_certinfo "$f")
	EOF
	printf '%s' "$min"
}

refresh_crl() {
	local n t
	n=$(now)
	t=$(cat "$CRL_TS" 2>/dev/null || echo 0)
	if [ -s "$CRL_FILE" ] && [ $((n - t)) -lt 21600 ]; then return 0; fi
	if fetch_url "$CRL_URL" "$CRL_FILE.new"; then
		mv -f "$CRL_FILE.new" "$CRL_FILE"
		printf '%s' "$n" > "$CRL_TS"
		return 0
	fi
	[ -s "$CRL_FILE" ]
}

serial_revoked() { # hexserial
	local h dec up hs decs ups
	[ -s "$CRL_FILE" ] || return 1
	h=$(printf '%s' "$1" | tr 'A-F' 'a-f')
	hs=$h
	while [ "${hs#00}" != "$hs" ] && [ "${#hs}" -gt 2 ]; do hs=${hs#00}; done
	dec=$(hex2dec "$hs")
	up=$(printf '%s' "$hs" | tr 'a-f' 'A-F')
	grep -q "\"$dec\"" "$CRL_FILE" && return 0
	grep -q "\"$hs\"" "$CRL_FILE" && return 0
	grep -q "\"$up\"" "$CRL_FILE" && return 0
	return 1
}

keybox_check_file() { # keybox: structure + parse + expiry + revocation
	local f=$1 nowts cnt=0
	[ -s "$f" ] || return 1
	grep -q '<AndroidAttestation' "$f" || return 1
	grep -q '<Key algorithm="ecdsa"' "$f" || return 1
	grep -q 'BEGIN EC PRIVATE KEY' "$f" || return 1
	nowts=$(now)
	while read -r ser before after; do
		cnt=$((cnt + 1))
		e=$(ymd2epoch "$after")
		[ -n "$e" ] || return 1
		[ "$e" -gt $((nowts + 86400)) ] || return 1
		serial_revoked "$ser" && return 1
	done <<-EOF
	$(keybox_certinfo "$f")
	EOF
	[ "$cnt" -ge 1 ]
}

has_block() { grep -q "<Key algorithm=\"$2\">" "$1"; }

extract_block() { # file algo
	awk -v algo="$2" '
		index($0, "<Key algorithm=\"" algo "\">") {inb=1}
		inb {print}
		inb && /<\/Key>/ {exit}
	' "$1"
}

merge_keybox() { # cand rsasrc out
	local cand=$1 rsa=$2 out=$3
	if has_block "$cand" rsa; then cp -f "$cand" "$out"; return 0; fi
	has_block "$cand" ecdsa || return 1
	has_block "$rsa" rsa || return 1
	{
		echo '<?xml version="1.0"?>'
		echo '<AndroidAttestation>'
		echo '<NumberOfKeyboxes>2</NumberOfKeyboxes>'
		echo '<Keybox DeviceID="strong_guard">'
		extract_block "$cand" ecdsa
		extract_block "$rsa" rsa
		echo '</Keybox>'
		echo '</AndroidAttestation>'
	} > "$out"
}

# ---------- install / OMK feedback ----------

omk_running() { pidof keymint >/dev/null 2>&1; }
omk_log_marker() { wc -c < "$OMK_LOG" 2>/dev/null | tr -d ' '; }

omk_wait_result() { # marker -> prints ok|fallback|timeout
	local marker=$1 i=0 new
	while [ "$i" -lt 15 ]; do
		sleep 1
		if [ -n "$BB" ]; then
			new=$($BB tail -c +"$((marker + 1))" "$OMK_LOG" 2>/dev/null)
		else
			new=$(tail -c +"$((marker + 1))" "$OMK_LOG" 2>/dev/null)
		fi
		case "$new" in
			*"fallback=false"*) printf 'ok'; return 0;;
			*"rewriting bundled template"*|*"fallback=true"*) printf 'fallback'; return 1;;
		esac
		i=$((i + 1))
	done
	printf 'timeout'
	return 2
}

install_keybox() { # src
	local src=$1 b
	b=$VAULT/backup-$(date '+%Y%m%d-%H%M%S').xml
	[ -f "$OMK_KEYBOX" ] && cp -f "$OMK_KEYBOX" "$b"
	cp -f "$src" "$WORK/.install.$$"
	chown keystore:keystore "$WORK/.install.$$" 2>/dev/null
	chmod 0600 "$WORK/.install.$$"
	mv -f "$WORK/.install.$$" "$OMK_KEYBOX"
	sync
	cp -f "$src" "$OMK_MOD_KEYBOX" 2>/dev/null && chmod 0644 "$OMK_MOD_KEYBOX" 2>/dev/null
	if [ -f "$TS_KEYBOX" ]; then
		cp -f "$src" "$TS_KEYBOX"
		chmod 0600 "$TS_KEYBOX"
	fi
}

restore_last_good() {
	if [ -s "$VAULT/keybox-good.xml" ]; then
		log "restore: installing last good keybox"
		install_keybox "$VAULT/keybox-good.xml"
		clear_gms
		return 0
	fi
	local b
	b=$(ls -t "$VAULT"/backup-*.xml 2>/dev/null | head -n1)
	if [ -n "$b" ]; then
		log "restore: installing backup $b"
		install_keybox "$b"
		clear_gms
		return 0
	fi
	return 1
}

clear_gms() {
	rm -rf /data/data/com.google.android.gms/app_dg_cache/* 2>/dev/null
	rm -rf /data/data/com.google.android.gms/app_dgp/* 2>/dev/null
	am force-stop com.google.android.gms >/dev/null 2>&1
	am force-stop com.android.vending >/dev/null 2>&1
}

# ---------- sources ----------

fetch_source() { # name
	local name=$1 raw=$WORK/cand_$1.raw out=$WORK/cand_$1.xml
	rm -f "$out" "$raw"
	case "$name" in
		meow)
			fetch_url "$MEOW_URL" "$raw" || { log "fetch: meow failed"; return 1; }
			decode_meow "$raw" "$out" || { log "decode: meow failed"; return 1; }
			;;
		yuri)
			fetch_url "$YURI_URL" "$raw" || { log "fetch: yuri failed"; return 1; }
			decode_b64 "$raw" "$out" || { log "decode: yuri failed"; return 1; }
			;;
		custom)
			[ -s "$CUSTOM_KEYBOX" ] || return 1
			cp -f "$CUSTOM_KEYBOX" "$out" || return 1
			;;
		*)
			return 1
			;;
	esac
	[ -s "$out" ]
}

fetch_all() { # [force]
	local force=$1 last src
	last=$(cat "$STATE/last_fetch.ts" 2>/dev/null || echo 0)
	if [ "$force" != "force" ] && [ $(( $(now) - last )) -lt $((FETCH_INTERVAL_H * 3600)) ]; then
		return 0
	fi
	for src in $SOURCES; do
		fetch_source "$src" || true
	done
	if validate_any_candidate; then
		printf '%s' "$(now)" > "$STATE/last_fetch.ts"
	fi
}

validate_any_candidate() {
	local c
	for c in "$WORK"/cand_*.xml; do
		[ -s "$c" ] || continue
		return 0
	done
	return 1
}

candidate_is_new() { # candidate: freshly minted EC leaf (later notBefore) than current
	local c=$1 cur new
	cur=$(keybox_certinfo "$OMK_KEYBOX" 2>/dev/null | head -n1 | awk '{print $2}')
	new=$(keybox_certinfo "$c" 2>/dev/null | head -n1 | awk '{print $2}')
	[ -n "$cur" ] && [ -n "$new" ] && [ "$new" \> "$cur" ]
}

# ---------- verdict check (UI automation) ----------

screen_ready() {
	local st
	st=$(dumpsys power 2>/dev/null | sed -n 's/.*mWakefulness=//p' | head -n1)
	[ "$st" = "Awake" ] || return 1
	dumpsys window 2>/dev/null | grep -q 'mDreamingLockscreen=true' && return 1
	return 0
}

ui_dump() { uiautomator dump "$1" >/dev/null 2>&1; [ -s "$1" ]; }

icon_state() { # dump id
	awk -v id="$2" 'BEGIN{RS="<node"} $0 ~ id { if (match($0, /content-desc="[^"]*"/)) { s=substr($0, RSTART+14, RLENGTH-15); print s; exit } }' "$1"
}

field_bounds() { # dump resource-id-fragment
	awk -v id="$2" 'BEGIN{RS="<node"} $0 ~ id { if (match($0, /bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"/)) { print substr($0, RSTART+8, RLENGTH-9); exit } }' "$1"
}

bounds_center() { # "[x1,y1][x2,y2]" -> "cx cy"
	printf '%s\n' "$1" | awk -F'[][,]' '{print int(($2+$5)/2), int(($3+$6)/2)}'
}

run_verdict_check() { # 0=strong pass, 1=strong fail, 2=unknown
	local b c basic device strong
	rm -f "$STATE/last_verdict" "$STATE/last_verdict.ts"
	screen_ready || return 2
	am force-stop "$CHECKER" >/dev/null 2>&1
	monkey -p "$CHECKER" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
	sleep 5
	ui_dump "$WORK/ui1.xml" || return 2
	b=$(field_bounds "$WORK/ui1.xml" check_btn)
	[ -n "$b" ] || return 2
	c=$(bounds_center "$b")
	[ -n "$c" ] || return 2
	set -- $c
	input tap "$1" "$2"
	sleep 15
	ui_dump "$WORK/ui2.xml" || return 2
	basic=$(icon_state "$WORK/ui2.xml" basic_integrity_icon)
	device=$(icon_state "$WORK/ui2.xml" device_integrity_icon)
	strong=$(icon_state "$WORK/ui2.xml" strong_integrity_icon)
	printf 'basic=%s device=%s strong=%s\n' "$basic" "$device" "$strong" > "$STATE/last_verdict"
	printf '%s' "$(now)" > "$STATE/last_verdict.ts"
	[ "$strong" = "Pass" ] && return 0
	[ "$strong" = "Fail" ] && return 1
	return 2
}

# ---------- rotation ----------

rotate_now() {
	local c rsa_src m marker res rc cands
	if [ -d "$STATE/rotating" ]; then
		local lockts
		lockts=$(cat "$STATE/rotating/ts" 2>/dev/null || echo 0)
		if [ $(( $(now) - lockts )) -gt 1800 ]; then
			log "rotate: clearing stale lock"
			rm -rf "$STATE/rotating"
		else
			log "rotate: already running"
			return 2
		fi
	fi
	mkdir -p "$STATE/rotating"
	printf '%s' "$(now)" > "$STATE/rotating/ts"
	log "rotate: start"
	refresh_crl
	fetch_all force

	rsa_src=""
	if has_block "$WORK/cand_yuri.xml" rsa 2>/dev/null; then
		rsa_src=$WORK/cand_yuri.xml
	elif [ -s "$VAULT/rsa-block.xml" ]; then
		rsa_src=$VAULT/rsa-block.xml
	elif has_block "$OMK_KEYBOX" rsa 2>/dev/null; then
		rsa_src=$OMK_KEYBOX
	fi
	if [ -n "$rsa_src" ] && ! [ -s "$VAULT/rsa-block.xml" ]; then
		{ echo '<?xml version="1.0"?>'; echo '<AndroidAttestation>'; echo '<NumberOfKeyboxes>1</NumberOfKeyboxes>'; echo '<Keybox DeviceID="rsa-source">'; extract_block "$rsa_src" rsa; echo '</Keybox>'; echo '</AndroidAttestation>'; } > "$VAULT/rsa-block.xml"
	fi

	cands="$WORK/cand_custom.xml $WORK/cand_meow.xml $WORK/cand_yuri.xml"
	# then vaulted good candidates (newest first)
	local v
	for v in $(ls -t "$VAULT"/keybox-*.xml 2>/dev/null); do
		cands="$cands $v"
	done

	for c in $cands; do
		[ -s "$c" ] || continue
		if ! keybox_check_file "$c"; then log "rotate: invalid/expired/revoked candidate $c"; continue; fi
		m=$WORK/merged.xml
		if has_block "$c" rsa; then
			cp -f "$c" "$m"
		else
			[ -n "$rsa_src" ] || { log "rotate: no RSA source available"; continue; }
			merge_keybox "$c" "$rsa_src" "$m" || { log "rotate: merge failed for $c"; continue; }
		fi
		keybox_check_file "$m" || { log "rotate: merged candidate failed checks"; continue; }

		if omk_running; then
			marker=$(omk_log_marker)
		else
			marker=""
		fi
		install_keybox "$m"
		if [ -n "$marker" ]; then
			res=$(omk_wait_result "$marker")
			if [ "$res" != "ok" ]; then
				log "rotate: OMK rejected candidate ($res): $c"
				restore_last_good
				continue
			fi
		else
			log "rotate: OMK not running, installed for next boot: $c"
		fi
		cp -f "$m" "$VAULT/keybox-good.xml"
		cp -f "$m" "$VAULT/keybox-$(date '+%Y%m%d-%H%M%S').xml"
		clear_gms
		sleep 30
		if screen_ready; then
			local i=0 vrc=2
			while [ "$i" -lt 3 ]; do
				run_verdict_check
				vrc=$?
				[ "$vrc" -eq 0 ] && break
				[ "$vrc" -eq 2 ] && break
				i=$((i + 1))
				sleep 30
			done
			if [ "$vrc" -eq 1 ]; then
				log "rotate: verdict still failing, trying next candidate"
				continue
			elif [ "$vrc" -eq 0 ]; then
				log "rotate: SUCCESS (STRONG pass) with $c"
				notify "STRONG 回復: keybox を更新しました"
				rm -rf "$STATE/rotating"
				return 0
			fi
		fi
		# verdict unknown (screen locked etc.): treat as success, health check will verify later
		log "rotate: installed candidate (verdict unconfirmed): $c"
		notify "keybox 更新: STRONG は後で自動確認します"
		rm -rf "$STATE/rotating"
		return 0
	done

	log "rotate: FAILED - no working candidate found"
	restore_last_good
	notify "STRONG 回復失敗: 有効な keybox が見つかりません"
	rm -rf "$STATE/rotating"
	return 1
}

# ---------- health ----------

health_check() {
	local exp n
	refresh_crl
	if ! keybox_check_file "$OMK_KEYBOX"; then
		log "health: current keybox invalid/expired/revoked"
		if [ "$AUTO_ROTATE" = 1 ]; then rotate_now; fi
		return
	fi
	fetch_all
	exp=$(keybox_min_expiry "$OMK_KEYBOX")
	n=$(now)
	if [ -n "$exp" ] && [ $((exp - n)) -lt $((EXPIRY_WARN_DAYS * 86400)) ]; then
		local c
		for c in "$WORK"/cand_*.xml; do
			[ -s "$c" ] || continue
			if candidate_is_new "$c"; then
				log "health: keybox expires soon, rotating to fresh candidate"
				[ "$AUTO_ROTATE" = 1 ] && rotate_now
				return
			fi
		done
		log "health: keybox expires soon and no fresh candidate available"
	fi
	if [ $((n - $(cat "$STATE/last_verdict.ts" 2>/dev/null || echo 0))) -ge $((VERDICT_INTERVAL_H * 3600)) ]; then
		run_verdict_check
		case $? in
			1) log "health: STRONG verdict failed"
			   [ "$AUTO_ROTATE" = 1 ] && rotate_now;;
			0) log "health: STRONG verdict pass";;
			*) : ;;
		esac
	fi
}

status() {
	local exp expstr
	printf 'Strong Guard status\n'
	printf '  time           : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	if [ -f "$OMK_KEYBOX" ]; then
		exp=$(keybox_min_expiry "$OMK_KEYBOX")
		if [ -n "$exp" ]; then
			if [ -n "$BB" ]; then
				expstr=$($BB date -u -d "@$exp" '+%Y-%m-%d %H:%M UTC' 2>/dev/null)
			else
				expstr=$exp
			fi
			printf '  keybox expiry  : %s\n' "$expstr"
		fi
	fi
	printf '  last verdict   : %s\n' "$(cat "$STATE/last_verdict" 2>/dev/null || echo 'n/a')"
	printf '  last verdict ts: %s\n' "$(cat "$STATE/last_verdict.ts" 2>/dev/null || echo 'n/a')"
	printf '  last fetch ts  : %s\n' "$(cat "$STATE/last_fetch.ts" 2>/dev/null || echo 'n/a')"
	printf '  sources        : %s\n' "$SOURCES"
	printf '  auto rotate    : %s\n' "$AUTO_ROTATE"
	printf '  OMK running    : %s\n' "$(omk_running && echo yes || echo no)"
}
