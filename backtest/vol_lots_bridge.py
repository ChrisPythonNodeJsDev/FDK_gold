import csv, glob, os, statistics

D="/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/"
SOLDE=2500.0; R=SOLDE*0.005

def spec(p):
    d={}
    for r in csv.DictReader(open(p)):
        d[r["champ"]]=r["valeur"]
    return d

print("compte %.0f $  -  risque par trade %.2f $  (0,5 %%)\n" % (SOLDE,R))
print("%-20s %8s %8s %9s %9s %7s  %s" % ("symbole","lot min","pas","lot med","risque","jours","verdict"))
print("-"*86)
lignes=[]
for sp in sorted(glob.glob(D+"FDK_V *_spec.csv")):
    s=spec(sp); sym=s["symbole"]
    m15=sp.replace("_spec.csv","_M15.csv")
    if not os.path.exists(m15): continue
    tv=float(s["tick_value"]); ts=float(s["tick_size"])
    mn=float(s["volume_min"]); st=float(s["volume_step"])
    lvl=float(s["stops_level"])*float(s["point"])
    rows=[]
    for r in csv.DictReader(open(m15)):
        rows.append((r["time_server"],float(r["high"]),float(r["low"]),float(r["close"])))
    tr=[]
    for i,(t,h,l,c) in enumerate(rows):
        tr.append(h-l if i==0 else max(h-l,abs(h-rows[i-1][3]),abs(l-rows[i-1][3])))
    a=sum(tr[:14])/14.0; atr=[None]*13+[a]
    for i in range(14,len(rows)):
        a=(a*13+tr[i])/14.0; atr.append(a)
    jour={}
    for (t,h,l,c),x in zip(rows,atr):
        if x: jour.setdefault(t[:10],x)
    lots=[]; ko=0; risq=[]
    for d,x in sorted(jour.items()):
        stop=max(1.5*x,lvl)
        lot=int((R*ts/(stop*tv))/st)*st
        if lot<mn-1e-12: ko+=1; lot=mn
        lots.append(lot); risq.append(lot*stop*tv/ts)
    med=statistics.median(lots); rmed=statistics.median(risq)
    pct=100.0*ko/len(lots)
    verdict = "OK" if ko==0 else ("exclu  (%.0f %% des jours)"%pct if pct>20 else "limite (%.0f %% des jours)"%pct)
    print("%-20s %8.3f %8.3f %9.3f %8.2f $ %7d  %s" % (sym,mn,st,med,rmed,len(lots),verdict))
