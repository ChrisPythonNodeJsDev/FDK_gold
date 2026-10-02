import csv, datetime, statistics, math
from collections import defaultdict
F='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/FDK_Volatility 50 (1s) Index_M15.csv'
b=[]
with open(F,encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts=r['time_server']
        if '.' not in ts or ':' not in ts: continue
        b.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                  float(r['open']),float(r['high']),float(r['low']),float(r['close'])))
b.sort(key=lambda x:x[0])
print(f"{len(b)} bougies M15, du {b[0][0]} au {b[-1][0]}")
print(f"prix de {min(x[3] for x in b):,.0f} a {max(x[2] for x in b):,.0f}".replace(',',' '))
jours=len({x[0].date() for x in b})
print(f"{jours} jours distincts, {len(b)/jours:.1f} bougies par jour  (96 = 24h/24)\n")

# --- effet d'heure : rendement et amplitude par heure serveur (= GMT) ---
rend=defaultdict(list); ampl=defaultdict(list)
for t,o,h,l,c in b:
    rend[t.hour].append((c-o)/o*1e4)      # points de base
    ampl[t.hour].append((h-l)/o*1e4)
glob_r=[x for v in rend.values() for x in v]
glob_a=[x for v in ampl.values() for x in v]
mr=statistics.mean(glob_r); ma=statistics.mean(glob_a)
print(f"ensemble : rendement moyen {mr:+.2f} pb par bougie, amplitude moyenne {ma:.1f} pb\n")
print(f"{'h':>3} {'n':>6} {'rendement':>12} {'t':>7} {'amplitude':>11} {'ecart':>8}")
pires_r=0; pires_a=0
for hh in range(24):
    v=rend[hh]; a=ampl[hh]
    m=statistics.mean(v); se=statistics.stdev(v)/math.sqrt(len(v)); t=m/se
    am=statistics.mean(a)
    print(f"{hh:>3} {len(v):>6} {m:>+11.2f} {t:>+7.2f} {am:>10.1f} {100*(am-ma)/ma:>+7.1f}%")
    pires_r=max(pires_r,abs(t)); pires_a=max(pires_a,abs(100*(am-ma)/ma))
print(f"\n|t| maximal sur les 24 heures : {pires_r:.2f}")
print(f"ecart d'amplitude maximal     : {pires_a:.1f} %")
# seuil de Bonferroni pour 24 tests
print(f"seuil a 5 % corrige pour 24 tests (Bonferroni) : |t| > {2.87:.2f}")
