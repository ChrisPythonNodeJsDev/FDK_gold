import re, csv, datetime, statistics, math, random
M15='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/FDK_XAUUSD_M15.csv'
bars=[]
with open(M15,encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts=r['time_server']
        if '.' not in ts or ':' not in ts: continue
        bars.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                     float(r['open']),float(r['high']),float(r['low']),float(r['close'])))
bars.sort(key=lambda x:x[0]); idx={b[0]:i for i,b in enumerate(bars)}
PIP=0.10; SPREAD=0.16

re_sig=re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+FDK_EA: signal (LONG|SHORT) par')
def charge(f):
    out=[]
    for l in open(f,encoding='utf-8'):
        m=re_sig.search(l)
        if not m: continue
        t=datetime.datetime.strptime(m.group(1)+' '+m.group(2),'%Y.%m.%d %H:%M:%S')
        if t in idx: out.append((t, 1 if m.group(3)=='LONG' else -1))
    return out

def rejouer(sigs, force=None, seed=None):
    rnd=random.Random(seed); tot=[]
    for t,d in sigs:
        if force=='long': d=1
        elif force=='short': d=-1
        elif force=='alea': d=rnd.choice([1,-1])
        i=idx[t]
        entry=bars[i][1]+(SPREAD if d>0 else 0.0)
        sl=entry-d*200*PIP; tp=entry+d*300*PIP; res=None
        for j in range(i,min(i+400,len(bars))):
            hi,lo=bars[j][2],bars[j][3]
            if (lo<=sl if d>0 else hi+SPREAD>=sl): res=-200; break
            if (hi>=tp if d>0 else lo+SPREAD<=tp): res=300; break
        if res is None:
            c=bars[min(i+400,len(bars))-1][4]; res=((c-entry) if d>0 else (entry-c))/PIP
        tot.append(res)
    return tot

for nom,f in [("ancien detecteur (fractales)","run1.txt"),("nouveau (cassure + 1 ATR)","run2.txt")]:
    s=charge(f)
    print(f"\n=== {nom} — {len(s)} signaux dans la fenetre M15 disponible ===")
    print(f"    {s[0][0].date()} -> {s[-1][0].date()}   LONG {sum(1 for _,d in s if d>0)}  SHORT {sum(1 for _,d in s if d<0)}")
    for lab,fo in [("direction reelle",None),("tout en ACHAT",'long'),("tout en VENTE",'short')]:
        v=rejouer(s,fo)
        R=[x/200 for x in v]; m=statistics.mean(R); se=statistics.stdev(R)/math.sqrt(len(R))
        print(f"    {lab:18s} {sum(v):+8.0f} pips  {m:+.4f} R/trade  t={m/se:+5.2f}  ({100*sum(1 for x in v if x>0)/len(v):.1f}% reussite)")
    al=[sum(rejouer(s,'alea',k)) for k in range(40)]
    print(f"    {'direction au hasard':18s} {statistics.mean(al):+8.0f} pips en moyenne sur 40 tirages "
          f"(de {min(al):+.0f} a {max(al):+.0f})")
