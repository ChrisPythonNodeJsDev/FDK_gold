import csv, datetime
D='/home/oswalddev/.mt5/drive_c/Program Files/MetaTrader 5/MQL5/Files/'
src=D+'FDK_Volatility 50 (1s) Index_M15.csv'
dst=D+'FDK_Volatility 50 (1s) Index_H4.csv'
rows=[]
with open(src,encoding='utf-8') as f:
    for r in csv.DictReader(f):
        ts=r['time_server']
        if '.' not in ts or ':' not in ts: continue
        rows.append((datetime.datetime.strptime(ts,'%Y.%m.%d %H:%M:%S'),
                     float(r['open']),float(r['high']),float(r['low']),float(r['close']),int(r['tick_volume'])))
rows.sort(key=lambda x:x[0])
groupes={}
for t,o,h,l,c,v in rows:
    cle=t.replace(hour=(t.hour//4)*4, minute=0, second=0)
    g=groupes.setdefault(cle,[o,h,l,c,v,t,t])
    g[1]=max(g[1],h); g[2]=min(g[2],l)
    if t<g[5]: g[0]=o; g[5]=t
    if t>g[6]: g[3]=c; g[6]=t
    g[4]+=v
with open(dst,'w',encoding='utf-8',newline='') as f:
    w=csv.writer(f)
    w.writerow(['time_server','open','high','low','close','tick_volume'])
    for cle in sorted(groupes):
        o,h,l,c,v,_,_=groupes[cle]
        w.writerow([cle.strftime('%Y.%m.%d %H:%M:%S'),f"{o:.2f}",f"{h:.2f}",f"{l:.2f}",f"{c:.2f}",v])
print(f"H4 reconstruit depuis le M15 : {len(groupes)} bougies, {min(groupes)} -> {max(groupes)}")
# bougies incompletes en bord d'echantillon
import collections
tail=sorted(groupes)[-1]; head=sorted(groupes)[0]
print(f"(la premiere et la derniere peuvent etre partielles : {len([1 for t,*_ in rows if t.replace(hour=(t.hour//4)*4,minute=0,second=0)==head])} et "
      f"{len([1 for t,*_ in rows if t.replace(hour=(t.hour//4)*4,minute=0,second=0)==tail])} bougies M15 sur 16)")
