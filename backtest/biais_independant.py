exec(open("bos2.py").read().split('print(f"derive {drift:+.2f}')[0])

def eval_ind(nom,s,pas,N_,Hs,Ls,Cs,label=""):
    """fenetres NON chevauchantes : on n'echantillonne qu'une bougie sur N"""
    g={1:[],-1:[],0:[]}
    idxs=range(need,len(Cs)-N_,pas)
    for e in idxs: g[s[e-1]].append(Cs[e-1+N_]-Cs[e-1])
    dr=statistics.mean([x for v in g.values() for x in v])
    allv=[(x-dr) for x in g[1]]+[-(x-dr) for x in g[-1]]
    if len(allv)<30: print(f"  {nom}: trop peu"); return
    m=statistics.mean(allv); se=statistics.stdev(allv)/math.sqrt(len(allv))
    def part(k):
        v=g[k]
        return f"{statistics.mean(v)-dr:+6.2f}$" if len(v)>=15 else "  n/a "
    print(f"  {nom:30s} n={len(allv):4d}  haussier {part(1)}  baissier {part(-1)}  "
          f"ensemble {m:+6.2f}$  IC95 [{m-1.96*se:+6.2f};{m+1.96*se:+6.2f}]  t={m/se:+5.2f}")

anc=[0]*len(h4)
for e in range(need,len(h4)+1): anc[e-1]=biais(H,L,e)
print("H4 — horizon 30 bougies, echantillons INDEPENDANTS (1 bougie sur 30)")
eval_ind("detecteur actuel",anc,30,30,H,L,C)
eval_ind("cassure + 1.0 x ATR",serie(disp=1.0),30,30,H,L,C)
eval_ind("cassure + 2.0 x ATR",serie(disp=2.0),30,30,H,L,C)

m15=load('/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/FDK_XAUUSD_M15.csv')
Hm,Lm,Cm=[r[2] for r in m15],[r[3] for r in m15],[r[4] for r in m15]
H,L,C=Hm,Lm,Cm; A=atr(Hm,Lm,Cm); h4=m15
ancm=[0]*len(m15)
for e in range(need,len(m15)+1): ancm[e-1]=biais(Hm,Lm,e)
print("\nM15 — horizon 48 bougies (12 h), echantillons INDEPENDANTS (1 bougie sur 48)")
eval_ind("detecteur actuel",ancm,48,48,Hm,Lm,Cm)
eval_ind("cassure + 1.0 x ATR",serie(disp=1.0),48,48,Hm,Lm,Cm)
print("\nM15 — horizon 16 bougies (4 h), echantillons INDEPENDANTS")
eval_ind("detecteur actuel",ancm,16,16,Hm,Lm,Cm)
eval_ind("cassure + 1.0 x ATR",serie(disp=1.0),16,16,Hm,Lm,Cm)
