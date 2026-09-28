exec(open("biais.py").read().split("h4=load(")[0])
import statistics, math
h4=load('/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/FDK_XAUUSD_H4.csv')
H=[r[2] for r in h4]; L=[r[3] for r in h4]; C=[r[4] for r in h4]
need=20+3*2+2; N=30
drift=statistics.mean(C[e-1+N]-C[e-1] for e in range(need,len(h4)-N))

# ATR de Wilder
def atr(H,L,C,p=14):
    tr=[H[0]-L[0]]
    for i in range(1,len(C)):
        tr.append(max(H[i]-L[i],abs(H[i]-C[i-1]),abs(L[i]-C[i-1])))
    a=[tr[0]]
    for i in range(1,len(tr)): a.append((a[-1]*(p-1)+tr[i])/p)
    return a
A=atr(H,L,C)

def serie(depth=3, disp=0.0, fresh=0):
    """disp : cassure exigee au-dela du niveau d'au moins disp x ATR
       fresh: si >0, le biais retombe a neutre apres 'fresh' bougies"""
    out=[0]*len(H); b=0; refH=None; refL=None; age=0
    for i in range(len(H)):
        j=i-depth
        if j>=depth:
            if all(H[j]>H[j-k] and H[j]>H[j+k] for k in range(1,depth+1)): refH=H[j]
            if all(L[j]<L[j-k] and L[j]<L[j+k] for k in range(1,depth+1)): refL=L[j]
        m=disp*A[i]
        if refH is not None and C[i]>refH+m: b=1;  refH=None; age=0
        elif refL is not None and C[i]<refL-m: b=-1; refL=None; age=0
        else: age+=1
        out[i]= 0 if (fresh>0 and age>fresh) else b
    return out

def eval(nom,s):
    g={1:[],-1:[],0:[]}
    for e in range(need,len(h4)-N): g[s[e-1]].append(C[e-1+N]-C[e-1])
    tot=sum(len(v) for v in g.values())
    parts=f"h{100*len(g[1])/tot:.0f}/b{100*len(g[-1])/tot:.0f}/n{100*len(g[0])/tot:.0f}"
    res=[]
    for k,lab in [(1,'haussier'),(-1,'baissier')]:
        v=g[k]
        if len(v)<50: res.append(f"{lab[0]}: n/a"); continue
        m=statistics.mean(v); se=statistics.stdev(v)/math.sqrt(len(v))
        res.append(f"{lab[0]} {m-drift:+6.2f}$ t={(m-drift)/se:+5.2f}")
    # score combine : ecart a la derive, signe par le biais, sur tous les etats non neutres
    allv=[(x-drift) for x in g[1]]+[-(x-drift) for x in g[-1]]
    m=statistics.mean(allv); se=statistics.stdev(allv)/math.sqrt(len(allv))
    print(f"{nom:34s} {parts:14s} {res[0]:18s} {res[1]:18s}  ensemble {m:+6.2f}$ t={m/se:+5.2f}")

print(f"derive {drift:+.2f}$ — ecart a la derive sur 30 bougies H4, par etat\n")
print(f"{'variante':34s} {'repartition':14s} {'haussier':18s} {'baissier':18s}")
anc=[0]*len(h4)
for e in range(need,len(h4)+1): anc[e-1]=biais(H,L,e)
eval("detecteur actuel (fractales)",anc)
eval("cassure de structure",serie())
for d in (0.10,0.25,0.50,1.00):
    eval(f"cassure + deplacement {d:.2f} x ATR",serie(disp=d))
for f in (3,6,12,24):
    eval(f"cassure recente (< {f} bougies)",serie(fresh=f))
eval("cassure 0.25xATR + recente (<12)",serie(disp=0.25,fresh=12))
# accord des deux
acc=[0]*len(h4); b=serie()
for i in range(len(h4)): acc[i]= b[i] if (anc[i]!=0 and anc[i]==b[i]) else 0
eval("accord fractales + cassure",acc)
