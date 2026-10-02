import csv, datetime, statistics, math
D='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/'
SYMBOLES=[("Volatility 50 (1s) Index", 5175*0.01, "origine (heures choisies ici)"),
          ("Volatility 100 Index",       27*0.01, "HORS ECHANTILLON"),
          ("Volatility 50 Index",       230*0.0001,"HORS ECHANTILLON")]

def load(sym):
    out=[]
    with open(D+f'FDK_{sym}_M15.csv',encoding='utf-8') as f:
        for r in csv.DictReader(f):
            ts=r['time_server']
            if '.' not in ts or ':' not in ts: continue
            out.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                        float(r['open']),float(r['close'])))
    out.sort(); return out

def regle(b, heures, spread):
    pj={}
    for t,o,c in b:
        if t.hour not in heures: continue
        k=(t.date(),t.hour)
        g=pj.setdefault(k,[o,c,t,t])
        if t<g[2]: g[0]=o; g[2]=t
        if t>g[3]: g[1]=c; g[3]=t
    return [(c-o)-spread for o,c,_,_ in pj.values()]

def stat(v, px):
    m=statistics.fmean(v); se=statistics.stdev(v)/math.sqrt(len(v))
    # ramene en points de base pour comparer des symboles d'echelles differentes
    return len(v), m/px*1e4, m/se, statistics.median(v)/px*1e4

for sym, spread, etiq in SYMBOLES:
    b=load(sym)
    px=statistics.fmean([o for _,o,_ in b])
    print(f"\n=== {sym} — {etiq} ===")
    print(f"    {len(b)} bougies, du {b[0][0].date()} au {b[-1][0].date()}, prix moyen {px:,.2f}".replace(',',' '))
    print(f"    spread {spread:.4f} en prix")
    n,m,t,med = stat(regle(b,{6,21},spread), px)
    print(f"  heures 6 et 21  : n={n:>4}  {m:>+8.2f} pb  mediane {med:>+7.2f} pb  t={t:>+5.2f}")
    autres={h for h in range(24) if h not in (6,21)}
    n,m,t,med = stat(regle(b,autres,spread), px)
    print(f"  les 22 autres   : n={n:>4}  {m:>+8.2f} pb  mediane {med:>+7.2f} pb  t={t:>+5.2f}  (reference)")
    # et quelles heures sortent sur CE symbole ?
    best=[]
    for hh in range(24):
        v=regle(b,{hh},spread)
        mm=statistics.fmean(v); ss=statistics.stdev(v)/math.sqrt(len(v))
        best.append((mm/ss, hh))
    best.sort(reverse=True)
    print(f"  les 3 meilleures heures de CE symbole : " +
          ", ".join(f"{h}h (t={t:+.2f})" for t,h in best[:3]))
