import re, statistics
from collections import defaultdict
lines = open('run_final.txt', encoding='utf-8').read().splitlines()

re_sig = re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+FDK_EA: signal (LONG|SHORT) par ([A-Z+]+) \(M15=(-?\d) H4=(-?\d), AMD=(oui|non), R:R ([\d.]+)\)')
re_deal = re.compile(r'\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+deal #(\d+) (buy|sell) 0\.1 XAUUSD at ([\d.]+) done')
re_trig = re.compile(r'triggered #(\d+) (buy|sell) 0\.1 XAUUSD ([\d.]+) sl.*\[#\d+ (?:buy|sell) 0\.1 XAUUSD at ([\d.]+)\]')
re_ind = re.compile(r'FDK_Gold_Custom.*\| (\d{4}\.\d{2}\.\d{2}) (\d{2}:\d{2}:\d{2})\s+FDK: AUTORISE (LONG|SHORT) \(([^,]+),')

signals=[]; ind=[]
ticket_mode={}
last_sig=None
for l in lines:
    m=re_sig.search(l)
    if m:
        last_sig=dict(d=m.group(1),t=m.group(2),dir=m.group(3),mode=m.group(4),
                      m15=int(m.group(5)),h4=int(m.group(6)),amd=m.group(7),rr=float(m.group(8)))
        signals.append(last_sig); continue
    m=re_ind.search(l)
    if m: ind.append((m.group(1),m.group(2),m.group(3),m.group(4))); continue
    m=re_deal.search(l)
    if m and last_sig and m.group(1)==last_sig['d'] and m.group(2)==last_sig['t']:
        ticket_mode[int(m.group(3))]=last_sig

res={}
for l in lines:
    m=re_trig.search(l)
    if m:
        tk=int(m.group(1)); side=m.group(2); e=float(m.group(3)); c=float(m.group(4))
        res[tk]=(c-e)*10 if side=='buy' else (e-c)*10

print(f"signaux EA {len(signals)}   AUTORISE indicateur {len(ind)}   ordres traces {len(ticket_mode)}   resultats {len(res)}")

# 1) signaux ignores (position deja ouverte)
print(f"signaux non executes : {len(signals)-len(ticket_mode)} soit {100*(1-len(ticket_mode)/len(signals)):.0f}%")

# 2) performance par mode d'entree
by=defaultdict(list)
for tk,sig in ticket_mode.items():
    if tk in res: by[sig['mode']].append(res[tk])
print("\n-- resultat par mode d'entree (trades reellement pris) --")
for k in sorted(by, key=lambda x:-len(by[x])):
    v=by[k]; w=sum(1 for x in v if x>0)
    print(f"{k:12s}: {len(v):4d} trades  {100*w/len(v):5.1f}% reussite  {sum(v):+9.0f} pips  ({sum(v)/200.6:+6.1f} R)  moy {sum(v)/len(v):+7.2f}")

# 3) H4 neutre ou non
print("\n-- selon H4 --")
g=defaultdict(list)
for tk,sig in ticket_mode.items():
    if tk not in res: continue
    d = 1 if sig['dir']=='LONG' else -1
    lab = 'H4 neutre' if sig['h4']==0 else ('H4 aligne' if sig['h4']==d else 'H4 contre')
    g[lab].append(res[tk])
for k in sorted(g, key=lambda x:-len(g[x])):
    v=g[k]; w=sum(1 for x in v if x>0)
    print(f"{k:12s}: {len(v):4d} trades  {100*w/len(v):5.1f}% reussite  {sum(v):+9.0f} pips  moy {sum(v)/len(v):+7.2f}")

# 4) contradictions de direction dans la meme journee
byday=defaultdict(set)
for s in signals: byday[s['d']].add(s['dir'])
contra=sum(1 for d,v in byday.items() if len(v)>1)
print(f"\njours avec signaux LONG ET SHORT : {contra} / {len(byday)} jours ({100*contra/len(byday):.0f}%)")

# 5) AMD vs BIAIS en desaccord le meme jour
byday2=defaultdict(lambda: defaultdict(set))
for s in signals:
    tag = 'AMD' if 'AMD' in s['mode'] else 'BIAIS'
    byday2[s['d']][tag].add(s['dir'])
dis=0; both=0
for d,v in byday2.items():
    if 'AMD' in v and 'BIAIS' in v:
        both+=1
        if v['AMD'] != v['BIAIS'] and not (v['AMD'] & v['BIAIS']): dis+=1
print(f"jours ou AMD et BIAIS coexistent : {both}, dont directions totalement opposees : {dis}")
