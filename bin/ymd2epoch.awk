#!/system/bin/sh
# UTC YYYYMMDDHHMMSS -> epoch seconds (civil-days algorithm)
{
	s = $0
	y = substr(s, 1, 4) + 0
	m = substr(s, 5, 2) + 0
	d = substr(s, 7, 2) + 0
	hh = substr(s, 9, 2) + 0
	mi = substr(s, 11, 2) + 0
	ss = substr(s, 13, 2) + 0
	yy = y - (m <= 2)
	era = int(yy / 400)
	yoe = yy - era * 400
	mp = m + (m > 2 ? -3 : 9)
	doy = int((153 * mp + 2) / 5) + d - 1
	doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
	days = era * 146097 + doe - 719468
	print days * 86400 + hh * 3600 + mi * 60 + ss
}
