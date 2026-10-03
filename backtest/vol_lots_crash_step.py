import csv, statistics
D="/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/"
SYM=["C 600 Idx.prop","C 300 Idx.prop","STP Idx 200.prop","STP Idx 300.prop","STP Idx 500.prop"]
def spec(p): return {r["champ"]:r["valeur"] for r in csv.DictReader(open(p))}

print("%-18s %8s %8s %10s %8s %8s %9s" %
      ("symbole","lot 2500","lot 10k","stop (pts)","risque","spread","% du stop"))
print("-"*78)
out=[]
for sym in SYM:
    s=spec(D+"FDK_"+sym+"_spec.csv")
    tv=float(s["tick_value"]); ts=float(s["tick_size"]); pt=float(s["point"])
    mn=float(s["volume_min"]); st=float(s["volume_step"])
    lvl=float(s["stops_level"])*pt; spr=float(s["spread_points"])*pt
    rows=[(r["time_server"],float(r["high"]),float(r["low"]),float(r["close"]))
          for r in csv.DictReader(open(D+"FDK_"+sym+"_M15.csv"))]
    tr=[]
    for i,(t,h,l,c) in enumerate(rows):
        tr.append(h-l if i==0 else max(h-l,abs(h-rows[i-1][3]),abs(l-rows[i-1][3])))
    a=sum(tr[:14])/14.0; atr=[None]*13+[a]
    for i in range(14,len(rows)):
        a=(a*13+tr[i])/14.0; atr.append(a)
    jour={}
    for (t,h,l,c),x in zip(rows,atr):
        if x: jour.setdefault(t[:10],x)
    amed=statistics.median(jour.values()); stop=max(1.5*amed,lvl)
    def lot(sol):
        return int(((sol*0.005)*ts/(stop*tv))/st)*st
    l25=lot(2500.0); l10=lot(10000.0)
    cout=l25*spr*tv/ts
    print("%-18s %8.2f %8.2f %10.2f %7.2f $ %7.2f $ %8.1f %%" %
          (sym,l25,l10,stop,l25*stop*tv/ts,cout,100*cout/(l25*stop*tv/ts)))

print("\nAmplitude du lot jour par jour (compte 2500) et bande de consistance 0,5x-2x")
print("%-18s %8s %8s %8s %8s %10s" % ("symbole","lot min","lot med","lot max","max/min","verdict"))
print("-"*70)
for sym in SYM:
    s=spec(D+"FDK_"+sym+"_spec.csv")
    tv=float(s["tick_value"]); ts=float(s["tick_size"]); pt=float(s["point"])
    mn=float(s["volume_min"]); st=float(s["volume_step"]); lvl=float(s["stops_level"])*pt
    rows=[(r["time_server"],float(r["high"]),float(r["low"]),float(r["close"]))
          for r in csv.DictReader(open(D+"FDK_"+sym+"_M15.csv"))]
    tr=[]
    for i,(t,h,l,c) in enumerate(rows):
        tr.append(h-l if i==0 else max(h-l,abs(h-rows[i-1][3]),abs(l-rows[i-1][3])))
    a=sum(tr[:14])/14.0; atr=[None]*13+[a]
    for i in range(14,len(rows)):
        a=(a*13+tr[i])/14.0; atr.append(a)
    jour={}
    for (t,h,l,c),x in zip(rows,atr):
        if x: jour.setdefault(t[:10],x)
    lots=[]
    for d,x in sorted(jour.items()):
        stop=max(1.5*x,lvl)
        v=int(((2500*0.005)*ts/(stop*tv))/st)*st
        lots.append(max(v,mn))
    r=max(lots)/min(lots)
    print("%-18s %8.2f %8.2f %8.2f %8.2f %10s" %
          (sym,min(lots),statistics.median(lots),max(lots),r,
           "OK" if r<=2.0 else "HORS BANDE"))
