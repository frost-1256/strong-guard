#!/system/bin/sh
# hex -> decimal (exact, arbitrary length)
{ h = tolower($0); n = 0; delete d
  for (i = 1; i <= length(h); i++) {
    c = index("0123456789abcdef", substr(h, i, 1)) - 1
    for (j = 1; j <= n || c; j++) {
      x = (d[j] + 0) * 16 + c
      d[j] = x % 10
      c = int(x / 10)
      if (j > n) n = j
    }
  }
  s = ""
  for (i = n; i >= 1; i--) s = s d[i]
  print (n ? s : "0")
}
