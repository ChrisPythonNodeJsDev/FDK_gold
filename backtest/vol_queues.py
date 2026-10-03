import csv, statistics
D="/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/"
SYM=["C 600 Idx.prop","C 300 Idx.prop","STP Idx 200.prop","STP Idx 300.prop",
     "STP Idx 500.prop","V 10 Idx.prop","V 50 (1s) Idx.prop"]
print("%-18s %7s %7s %7s %7s   %s" % ("symbole","3xATR-","3xATR+","4xATR-","4xATR+","pires baisses (en ATR)"))
print("-"*94)
for sym in SYM:
    rows=[(r["time_server"],float(r["high"]),float(r["low"]),float(r["close"]))
          for r in csv.DictReader(open(D+"FDK_"+sym+"_M15.csv"))]
    tr=[]
    for i,(t,h,l,c) in enumerate(rows):
        tr.append(h-l if i==0 else max(h-l,abs(h-rows[i-1][3]),abs(l-rows[i-1][3])))
    a=sum(tr[:14])/14.0; atr=[None]*13+[a]
    for i in range(14,len(rows)):
        a=(a*13+tr[i])/14.0; atr.append(a)
    dn=[];up=[]
    for i in range(14,len(rows)):
        A=atr[i-1]; t,h,l,c=rows[i]; pc=rows[i-1][3]
        dn.append(((pc-l)/A,t)); up.append((h-pc)/A)
    n=len(dn)
    d3=sum(1 for x,_ in dn if x>3); u3=sum(1 for x in up if x>3)
    d4=sum(1 for x,_ in dn if x>4); u4=sum(1 for x in up if x>4)
    top=sorted(dn,reverse=True)[:4]
    print("%-18s %7d %7d %7d %7d   %s" % (sym,d3,u3,d4,u4,
          "  ".join("%.1f" % x for x,_ in top)))
    print("%-18s %7s %7s %7s %7s   %s" % ("","","","","",
          "  ".join(t[:10] for _,t in top)))
