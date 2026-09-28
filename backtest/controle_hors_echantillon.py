exec(open('controle.py').read().split('for nom,f in')[0])
import statistics, math
s=charge('run3.txt')
print(f"=== controle hors echantillon — {len(s)} signaux, {s[0][0].date()} -> {s[-1][0].date()} ===")
print(f"    LONG {sum(1 for _,d in s if d>0)}  SHORT {sum(1 for _,d in s if d<0)}")
for lab,fo in [("direction reelle",None),("tout en ACHAT",'long'),("tout en VENTE",'short')]:
    v=rejouer(s,fo)
    R=[x/200 for x in v]; m=statistics.mean(R); se=statistics.stdev(R)/math.sqrt(len(R))
    print(f"    {lab:18s} {sum(v):+8.0f} pips  {m:+.4f} R/trade  t={m/se:+5.2f}  ({100*sum(1 for x in v if x>0)/len(v):.1f}% reussite)")
al=[sum(rejouer(s,'alea',k)) for k in range(40)]
print(f"    {'direction au hasard':18s} {statistics.mean(al):+8.0f} pips en moyenne (de {min(al):+.0f} a {max(al):+.0f})")
