# Minimal DER certificate field extractor (serial, notBefore, notAfter)
# Input : continuous lowercase hex of a DER certificate on a single line (xxd -p | tr -d '\n')
# Output: serial:<HEX> \n notBefore:<YYYYMMDDHHMMSS> \n notAfter:<YYYYMMDDHHMMSS>

function hx2d(h,   i, c, d, base) {
	d = 0; base = 1
	for (i = length(h); i >= 1; i--) {
		c = tolower(substr(h, i, 1))
		d += (index("0123456789abcdef", c) - 1) * base
		base *= 16
	}
	return d
}

# byte at 1-based position p
function gb(p) { return hx2d(substr(h, 2 * p - 1, 2)) }

# value start position of TLV at p
function vpos(p,   l) {
	l = gb(p + 1)
	if (l < 128) return p + 2
	return p + 2 + (l - 128)
}

# total TLV size (header + value) at p
function tlvsize(p,   l, n, i, vlen) {
	l = gb(p + 1)
	if (l < 128) return 2 + l
	n = l - 128
	vlen = 0
	for (i = 1; i <= n; i++) vlen = vlen * 256 + gb(p + 1 + i)
	return 2 + n + vlen
}

function nextsib(p) { return p + tlvsize(p) }

# value length of TLV at p
function vlen(p) { return tlvsize(p) - (vpos(p) - p) }

# read an ASCII time string at TLV position p, normalize to YYYYMMDDHHMMSS
function strtime(p,   tag, v, n, i, c, s, yy) {
	tag = gb(p)
	v = vpos(p)
	n = vlen(p)
	s = ""
	for (i = 0; i < n; i++) {
		c = gb(v + i)
		if (c >= 48 && c <= 57) s = s sprintf("%c", c)
	}
	if (tag == 23) {           # UTCTime YYMMDDHHMMSSZ
		yy = substr(s, 1, 2) + 0
		if (yy < 50) yy += 2000; else yy += 1900
		return yy substr(s, 3)
	}
	return s                    # GeneralizedTime YYYYMMDDHHMMSSZ
}

{
	h = tolower($0)
	p = 1
	if (gb(p) != 48) { print "parse_error:no_cert_sequence"; exit 1 }
	q = vpos(p)                                # TBSCertificate TLV
	if (gb(q) != 48) { print "parse_error:no_tbs"; exit 1 }
	q = vpos(q)                                # first field of TBS
	if (gb(q) == 160) q = nextsib(q)          # optional [0] version
	if (gb(q) != 2) { print "parse_error:no_serial"; exit 1 }
	sv = vpos(q); sl = vlen(q)
	serial = toupper(substr(h, 2 * sv - 1, 2 * sl))
	q = nextsib(q)                              # signature algorithm
	q = nextsib(q)                              # issuer
	q = nextsib(q)                              # validity
	if (gb(q) != 48) { print "parse_error:no_validity"; exit 1 }
	vb = vpos(q)
	na = nextsib(vb)
	print "serial:" serial
	print "notBefore:" strtime(vb)
	print "notAfter:" strtime(na)
}
