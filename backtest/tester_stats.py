import re, statistics, math
from collections import defaultdict
lines=open('run_final.txt',encoding='utf-8').read().splitlines()
re_sig=re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+FDK_EA: signal (LONG|SHORT) par ([A-Z+]+) \(M15=(-?\d) H4=(-?\d)')
re_deal=re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+deal #(\d+) (buy|sell) 0\.1 XAUUSD at ([\d.]+) done')
re_trig=re.compile(r'triggered #(\d+) (buy|sell) 0\.1 XAUUSD ([\d.]+) sl.*\[#\d+ (?:buy|sell) 0\.1 XAUUSD at ([\d.]+)\]')
tm={}; last=None
for l in lines:
    m=re_sig.search(l)
    if m: last=dict(d=m.group(1),t=m.group(2),dir=m.group(3),mode=m.group(4),h4=int(m.group(6))); continue
    m=re_deal.search(l)
    if m and last and m.group(1)==last['d'] and m.group(2)==last['t']: tm[int(m.group(3))]=last
res={}
for l in lines:
    m=re_trig.search(l)
    if m:
        tk=int(m.group(1));e=float(m.group(3));c=float(m.group(4))
        res[tk]=((c-e) if m.group(2)=='buy' else (e-c))*10
R=200.6
def tt(v,label):
    if len(v)<2: print(f"{label}: n={len(v)} trop peu"); return
    r=[x/R for x in v]; m=statistics.mean(r); sd=statistics.stdev(r); se=sd/math.sqrt(len(r))
    print(f"{label:22s} n={len(r):4d}  {m:+.4f} R/trade  IC95 [{m-1.96*se:+.3f} ; {m+1.96*se:+.3f}]  t={m/se:+.2f}")
allv=[res[t] for t in tm if t in res]
tt(allv,"ENSEMBLE")
g=defaultdict(list)
for tk,s in tm.items():
    if tk not in res: continue
    d=1 if s['dir']=='LONG' else -1
    g['H4 neutre' if s['h4']==0 else ('H4 aligne' if s['h4']==d else 'H4 contre')].append(res[tk])
    g['mode '+('AMD' if 'AMD' in s['mode'] else 'BIAIS')].append(res[tk])
    g['annee '+s['d'][:4]].append(res[tk])
for k in sorted(g): tt(g[k],k)
