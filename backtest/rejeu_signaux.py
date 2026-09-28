import re, csv, datetime, statistics
from collections import defaultdict

M15='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/FDK_XAUUSD_M15.csv'
bars=[]
with open(M15,encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts=r['time_server']
        if '.' not in ts or ':' not in ts: continue
        bars.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                     float(r['open']),float(r['high']),float(r['low']),float(r['close'])))
bars.sort(key=lambda x:x[0])
idx={b[0]:i for i,b in enumerate(bars)}
print(f"M15 : {len(bars)} bougies  {bars[0][0]} -> {bars[-1][0]}")

# --- signaux issus du journal du Simulateur (verite terrain, .mqh partage) ---
re_sig=re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+FDK_EA: signal (LONG|SHORT) par ([A-Z+]+) \(M15=(-?\d) H4=(-?\d)')
sigs=[]
for l in open('run_final.txt',encoding='utf-8'):
    m=re_sig.search(l)
    if not m: continue
    t=datetime.datetime.strptime(m.group(1)+' '+m.group(2),'%Y.%m.%d %H:%M:%S')
    sigs.append(dict(t=t,dir=1 if m.group(3)=='LONG' else -1,mode=m.group(4),h4=int(m.group(6))))
win=[s for s in sigs if s['t'] in idx]
print(f"signaux du journal : {len(sigs)}, dont {len(win)} tombent dans la fenetre du CSV")
print(f"fenetre rejouee : {win[0]['t']} -> {win[-1]['t']}")

PIP=0.10
SPREAD=0.16   # observe dans le journal du Simulateur

def rejouer(sl_pips, tp_pips, maxbars=400):
    """chaque signal est pris, independamment des autres"""
    out=[]
    for s in win:
        i=idx[s['t']]
        if i+1>=len(bars): continue
        d=s['dir']
        entry=bars[i][1] + (SPREAD if d>0 else 0.0)      # ouverture de la bougie, cote achat
        sl=entry-d*sl_pips*PIP
        tp=entry+d*tp_pips*PIP
        mfe=0.0; res=None
        for j in range(i,min(i+maxbars,len(bars))):
            hi,lo=bars[j][2],bars[j][3]
            fav=(hi-entry) if d>0 else (entry-lo)
            mfe=max(mfe,fav/PIP)
            touch_sl=(lo<=sl) if d>0 else (hi+SPREAD>=sl)
            touch_tp=(hi>=tp) if d>0 else (lo-0+SPREAD<=tp)
            if touch_sl and touch_tp: res=-sl_pips; break      # ambigu -> on suppose le pire
            if touch_sl: res=-sl_pips; break
            if touch_tp: res=tp_pips; break
        if res is None:
            res=((bars[min(i+maxbars,len(bars))-1][4]-entry) if d>0 else (entry-bars[min(i+maxbars,len(bars))-1][4]))/PIP
        out.append(dict(sig=s,res=res,mfe=mfe))
    return out

# ---------- 1. l'affirmation : "le TP est presque touche puis le SL part" ----------
base=rejouer(200,300)
perd=[t for t in base if t['res']<0]
gagn=[t for t in base if t['res']>0]
print(f"\n=== 1. jusqu'ou va le prix AVANT de perdre ? (SL 200 / TP 300, {len(base)} signaux) ===")
print(f"perdants {len(perd)}  gagnants {len(gagn)}")
mf=[t['mfe'] for t in perd]
mf.sort()
print(f"gain maximal atteint par un trade PERDANT (pips) :")
print(f"  mediane {statistics.median(mf):.0f}   moyenne {statistics.mean(mf):.0f}   max {max(mf):.0f}")
for seuil in (100,150,200,250,280):
    n=sum(1 for x in mf if x>=seuil)
    print(f"  {n:4d} perdants ({100*n/len(perd):4.1f}%) sont montes a +{seuil} pips avant de revenir au stop")

# ---------- 2. quelle distance de cible ? ----------
print(f"\n=== 2. grille de cibles (stop fixe a 200 pips, tous les signaux pris) ===")
print(f"{'TP':>5} {'R:R':>5} {'reussite':>9} {'seuil':>7} {'total pips':>11} {'R/trade':>9} {'IC95':>18}")
import math
for tp in (80,100,120,150,180,200,250,300,400,500):
    r=rejouer(200,tp)
    v=[x['res'] for x in r]; w=sum(1 for x in v if x>0)
    rr=tp/200
    seuil=100/(1+rr)
    Rv=[x/200 for x in v]; m=statistics.mean(Rv); se=statistics.stdev(Rv)/math.sqrt(len(Rv))
    print(f"{tp:>5} {rr:>5.2f} {100*w/len(v):>8.1f}% {seuil:>6.1f}% {sum(v):>+11.0f} {m:>+9.4f} [{m-1.96*se:+.3f};{m+1.96*se:+.3f}]")

# ---------- 3. une seule position a la fois, ou toutes ? ----------
print(f"\n=== 3. effet de la limite d'une position a la fois (SL 200 / TP 300) ===")
r=rejouer(200,300)
# reconstruire la contrainte : on garde un signal seulement si le precedent est clos
def avec_limite(trades, maxpos):
    ouverts=[]; pris=[]
    for t in trades:
        i=idx[t['sig']['t']]
        ouverts=[o for o in ouverts if o>i]
        if len(ouverts)>=maxpos: continue
        # duree : on recalcule la barre de sortie
        d=t['sig']['dir']; entry=bars[i][1]+(SPREAD if d>0 else 0.0)
        sl=entry-d*200*PIP; tp=entry+d*300*PIP; fin=min(i+400,len(bars)-1)
        for j in range(i,min(i+400,len(bars))):
            hi,lo=bars[j][2],bars[j][3]
            if (lo<=sl if d>0 else hi+SPREAD>=sl) or (hi>=tp if d>0 else lo+SPREAD<=tp): fin=j; break
        ouverts.append(fin); pris.append(t)
    return pris
for mp in (1,2,3,5,10,999):
    p=avec_limite(r,mp); v=[x['res'] for x in p]
    lab='sans limite' if mp==999 else f'{mp} position(s)'
    print(f"  {lab:14s}: {len(v):4d} trades pris  {100*sum(1 for x in v if x>0)/len(v):5.1f}% reussite  {sum(v):+8.0f} pips  {sum(v)/200/len(v):+.4f} R/trade")

# ---------- 4. remonter le stop a l'equilibre ----------
print(f"\n=== 4. stop ramene a l'entree une fois X pips acquis (SL 200 / TP 300) ===")
def avec_be(be_pips, sl_pips=200, tp_pips=300, maxbars=400):
    out=[]
    for s in win:
        i=idx[s['t']]; d=s['dir']
        entry=bars[i][1]+(SPREAD if d>0 else 0.0)
        sl=entry-d*sl_pips*PIP; tp=entry+d*tp_pips*PIP; arme=False; res=None
        for j in range(i,min(i+maxbars,len(bars))):
            hi,lo=bars[j][2],bars[j][3]
            fav=(hi-entry) if d>0 else (entry-lo)
            if not arme and fav/PIP>=be_pips:
                arme=True; sl=entry
            if (lo<=sl if d>0 else hi+SPREAD>=sl): res=(sl-entry)*d/PIP; break
            if (hi>=tp if d>0 else lo+SPREAD<=tp): res=tp_pips; break
        if res is None:
            c=bars[min(i+maxbars,len(bars))-1][4]; res=((c-entry) if d>0 else (entry-c))/PIP
        out.append(res)
    return out
print(f"  {'sans':>12s}: {sum(x['res'] for x in r):+8.0f} pips  {sum(x['res'] for x in r)/200/len(r):+.4f} R/trade")
for be in (100,150,200,250):
    v=avec_be(be)
    print(f"  {'+'+str(be)+' pips':>12s}: {sum(v):+8.0f} pips  {sum(v)/200/len(v):+.4f} R/trade  ({100*sum(1 for x in v if x>0)/len(v):.1f}% positifs, {sum(1 for x in v if abs(x)<1)} a l'equilibre)")
