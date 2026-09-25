#!/usr/bin/env python3
"""La regle se tait-elle precisement les jours ou le marche bouge ?

Aujourd'hui : 613 pips d'amplitude, aucun signal. On verifie si c'est une
coincidence ou un defaut structurel, en croisant l'amplitude quotidienne
avec la presence d'un signal ce jour-la.
"""
import sys, statistics, collections
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv, compute_bias, session_of, wilder_atr

BENIN = 3600
def dayid(ts): return (ts + BENIN) // 86400


if __name__ == "__main__":
    m15 = load_mt5_csv(sys.argv[1], 0)
    highs = [b[2] for b in m15]; lows = [b[3] for b in m15]
    h4t, h4h, h4l = [], [], []
    days = collections.OrderedDict()

    for i, (ts, o, h, l, c) in enumerate(m15):
        b = ts - (ts % 14400)
        if not h4t or h4t[-1] != b:
            h4t.append(b); h4h.append(h); h4l.append(l)
        else:
            h4h[-1] = max(h4h[-1], h); h4l[-1] = min(h4l[-1], l)

        d = dayid(ts)
        if d not in days:
            days[d] = dict(hi=h, lo=l, signal=False)
        days[d]["hi"] = max(days[d]["hi"], h)
        days[d]["lo"] = min(days[d]["lo"], l)

        if days[d]["signal"]:
            continue
        bm = compute_bias(highs, lows, i)
        if bm == 0:
            continue
        if compute_bias(h4h, h4l, len(h4t)-1) != bm:
            continue
        if session_of(ts) is None:
            continue
        days[d]["signal"] = True

    rows = [(d, (v["hi"]-v["lo"])/0.1, v["signal"]) for d, v in days.items()
            if v["hi"] > v["lo"]]
    rows.sort(key=lambda r: r[1])
    n = len(rows)
    print(f"{n} journees analysees\n")
    print(f"{'quintile d amplitude':<26}{'amplitude med.':>15}{'jours avec signal':>20}")
    for q in range(5):
        part = rows[q*n//5:(q+1)*n//5]
        amp = statistics.median(r[1] for r in part)
        pct = 100.0*sum(1 for r in part if r[2])/len(part)
        tag = ["plus calmes","calmes","moyennes","agitees","plus agitees"][q]
        print(f"  {tag:<24}{amp:>11.0f} pips{pct:>17.0f} %")

    big = [r for r in rows if r[1] >= 600]
    if big:
        print(f"\nJournees a 600 pips ou plus : {len(big)}")
        print(f"  dont avec au moins un signal : {sum(1 for r in big if r[2])}"
              f" ({100.0*sum(1 for r in big if r[2])/len(big):.0f} %)")
