import re, statistics
from collections import defaultdict

lines = open('run_final.txt', encoding='utf-8').read().splitlines()

# entrees : date + ticket + sens + prix
entries = {}   # ticket -> (datetime, side, price)
re_deal = re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+deal #(\d+) (buy|sell) 0\.1 XAUUSD at ([\d.]+) done')
re_trig = re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+(take profit|stop loss) triggered #(\d+) (buy|sell) 0\.1 XAUUSD ([\d.]+) sl: ([\d.]+) tp: ([\d.]+) \[#(\d+) (?:buy|sell) 0\.1 XAUUSD at ([\d.]+)\]')

deals = {}
for l in lines:
    m = re_deal.search(l)
    if m:
        d,t,tk,side,px = m.groups()
        deals[int(tk)] = (d,t,side,float(px))

trades = []
for l in lines:
    m = re_trig.search(l)
    if m:
        d,t,kind,tk,side,entry,sl,tp,ctk,cpx = m.groups()
        tk=int(tk); entry=float(entry); cpx=float(cpx)
        pips = (cpx-entry)*10 if side=='buy' else (entry-cpx)*10
        ed = deals.get(tk,(d,t,side,entry))
        trades.append(dict(ticket=tk, side=side, entry_date=ed[0], entry_time=ed[1],
                           exit_date=d, exit_time=t, kind=kind, entry=entry,
                           exitp=cpx, pips=pips))

print(f"trades cloturees : {len(trades)}")
wins=[t for t in trades if t['pips']>0]; losses=[t for t in trades if t['pips']<=0]
tot=sum(t['pips'] for t in trades)
print(f"gagnantes {len(wins)} ({100*len(wins)/len(trades):.1f}%)  perdantes {len(losses)}")
print(f"total {tot:+.1f} pips   moyenne {tot/len(trades):+.2f} pips/trade")
print(f"gain moyen {statistics.mean(t['pips'] for t in wins):+.1f}   perte moyenne {statistics.mean(t['pips'] for t in losses):+.1f}")
gp=sum(t['pips'] for t in wins); gl=-sum(t['pips'] for t in losses)
print(f"profit factor {gp/gl:.3f}   (seuil rentabilite = 40.0% de reussite)")

# R = risque moyen ~ 200 pips + spread
R = statistics.mean(-t['pips'] for t in losses)
print(f"1 R mesure = {R:.1f} pips -> resultat = {tot/R:+.1f} R  ({tot/R/len(trades):+.4f} R/trade)")

# equity + drawdown
eq=0; peak=0; mdd=0
curve=[]
for t in sorted(trades, key=lambda x:(x['exit_date'],x['exit_time'])):
    eq+=t['pips']; peak=max(peak,eq); mdd=max(mdd,peak-eq); curve.append((t['exit_date'],eq))
print(f"drawdown max {mdd:.0f} pips ({mdd/R:.1f} R)   equity finale {eq:+.0f} pips")

# par annee
byyear=defaultdict(list)
for t in trades: byyear[t['exit_date'][:4]].append(t['pips'])
print("\n-- par annee --")
for y in sorted(byyear):
    v=byyear[y]; w=sum(1 for x in v if x>0)
    print(f"{y}: {len(v):4d} trades  {100*w/len(v):5.1f}% reussite  {sum(v):+9.0f} pips  ({sum(v)/R:+6.1f} R)")

# par sens
print("\n-- par sens --")
for s in ('buy','sell'):
    v=[t['pips'] for t in trades if t['side']==s]; w=sum(1 for x in v if x>0)
    print(f"{s:4s}: {len(v):4d} trades  {100*w/len(v):5.1f}% reussite  {sum(v):+9.0f} pips")

# duree
import datetime
def dt(d,t): return datetime.datetime.strptime(d+' '+t,'%Y.%m.%d %H:%M:%S')
durs=[(dt(t['exit_date'],t['exit_time'])-dt(t['entry_date'],t['entry_time'])).total_seconds()/3600 for t in trades]
print(f"\nduree mediane {statistics.median(durs):.1f} h   moyenne {statistics.mean(durs):.1f} h")
