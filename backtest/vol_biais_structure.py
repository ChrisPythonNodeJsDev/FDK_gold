import csv, datetime, statistics, math
from collections import Counter
D='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/'
SYMS=["Volatility 50 (1s) Index","Volatility 100 Index","Volatility 50 Index"]
def load(p):
    out=[]
    with open(p,encoding='utf-8') as f:
        for r in csv.DictReader(f):
            ts=r['time_server']
            if '.' not in ts or ':' not in ts: continue
            out.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                        float(r['open']),float(r['high']),float(r['low']),float(r['close'])))
    out.sort(); return out
def atr(H,L,C,p=14):
    tr=[H[0]-L[0]]
    for i in range(1,len(C)): tr.append(max(H[i]-L[i],abs(H[i]-C[i-1]),abs(L[i]-C[i-1])))
    a=[tr[0]]
    for i in range(1,len(tr)): a.append((a[-1]*(p-1)+tr[i])/p)
    return a
def bos(H,L,C,A,depth=3,disp=1.0):
    out=[0]*len(H); bi=0; rH=rL=None
    for i in range(len(H)):
        j=i-depth
        if j>=depth:
            if all(H[j]>H[j-k] and H[j]>H[j+k] for k in range(1,depth+1)): rH=H[j]
            if all(L[j]<L[j-k] and L[j]<L[j+k] for k in range(1,depth+1)): rL=L[j]
        m=disp*A[i]
        if rH is not None and C[i]>rH+m: bi=1; rH=None
        elif rL is not None and C[i]<rL-m: bi=-1; rL=None
        out[i]=bi
    return out
print("Biais par cassure de structure — valeur predictive, echantillons independants")
print(f"{'symbole':>26} {'UT':>4} {'n':>5} {'ecart a la derive':>19} {'t':>7}")
for sym in SYMS:
    for ut,N in (("M15",48),("H4",30)):
        try: d=load(D+f'FDK_{sym}_{ut}.csv')
        except FileNotFoundError: continue
        H=[x[2] for x in d]; L=[x[3] for x in d]; C=[x[4] for x in d]
        s=bos(H,L,C,atr(H,L,C))
        g={1:[],-1:[]}
        for e in range(40,len(d)-N,N):
            if s[e-1]!=0: g[s[e-1]].append((C[e-1+N]-C[e-1])/C[e-1]*1e4)
        tous=g[1]+g[-1]
        if len(tous)<40: continue
        dr=statistics.fmean(tous)
        adj=[x-dr for x in g[1]]+[-(x-dr) for x in g[-1]]
        m=statistics.fmean(adj); se=statistics.stdev(adj)/math.sqrt(len(adj))
        print(f"{sym:>26} {ut:>4} {len(adj):>5} {m:>+16.1f} pb {m/se:>+7.2f}")
