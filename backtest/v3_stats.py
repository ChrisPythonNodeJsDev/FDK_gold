#!/usr/bin/env python3
"""V3 (entree sur simple retour dans une zone fraiche) est-il reellement
different de zero, ou compatible avec du bruit ? Et survit-il au spread ?"""
import sys, math, datetime, statistics
sys.path.insert(0, "/home/oswalddev/FDK_backtest")
from backtest import load_mt5_csv, wilder_atr
from bt2 import simulate, score
from zones import Zones


def collect(m15):
    atr = wilder_atr(m15)
    h4_t, h4_h, h4_l, h4_o, h4_c = [], [], [], [], []
    zm, zh = Zones(), Zones()
    trs, prev = [], None
    out, pd_, busy = [], 0, -1

    for i, (ts, o, h, l, c) in enumerate(m15):
        b = ts - (ts % 14400)
        nb = (not h4_t or h4_t[-1] != b)
        if nb and h4_t:
            k = len(h4_t) - 1
            tr = h4_h[k]-h4_l[k] if k == 0 else max(h4_h[k]-h4_l[k],
                 abs(h4_h[k]-h4_c[k-1]), abs(h4_l[k]-h4_c[k-1]))
            trs.append(tr); a4 = None
            if len(trs) >= 14:
                a4 = sum(trs[-14:])/14 if prev is None else (prev*13+tr)/14
                prev = a4
            zh.feed(h4_o[k], h4_h[k], h4_l[k], h4_c[k], a4, "H4")
        if nb:
            h4_t.append(b); h4_h.append(h); h4_l.append(l); h4_o.append(o); h4_c.append(c)
        else:
            h4_h[-1]=max(h4_h[-1],h); h4_l[-1]=min(h4_l[-1],l); h4_c[-1]=c

        hits = zm.touched(h, l) + zh.touched(h, l)
        zm.feed(o, h, l, c, atr[i], "M15")
        if atr[i] is None or atr[i] <= 0:
            continue
        dh = any(not z["supply"] for z in hits)
        sh = any(z["supply"] for z in hits)
        d = 1 if (dh and not sh) else (-1 if (sh and not dh) else 0)
        new = d != 0 and pd_ != d
        pd_ = d
        if not new or i <= busy:
            continue
        r = atr[i]
        ev = simulate(m15, i, d, c, r, c + d*r, c + d*2*r)
        A, B, C = score(ev, d, c, r)
        busy = i + ev["bars"]
        out.append((A, B, C, r))
    return out


def stats(tr, name):
    n = len(tr)
    if n < 2:
        print(f"  {name}: n={n}, insuffisant"); return
    print(f"\n  {name}  (n={n})")
    print(f"    {'scenario':<10} {'moyenne':>9} {'SE':>7} {'t':>6} {'IC 95%':>20} {'net 0.30':>10}")
    avg_r = statistics.mean(x[3] for x in tr)
    cost = 0.30 / avg_r
    for idx, lab in ((0, "A TP1"), (1, "B TP2"), (2, "C mixte")):
        v = [x[idx] for x in tr]
        m = statistics.mean(v)
        se = statistics.stdev(v) / math.sqrt(n)
        t = m / se if se else 0
        lo, hi = m - 1.96*se, m + 1.96*se
        print(f"    {lab:<10} {m:>+9.3f} {se:>7.3f} {t:>6.2f}   [{lo:+.3f} ; {hi:+.3f}] {m-cost:>+10.3f}")
    print(f"    ATR moyen {avg_r:.2f} pt -> spread 0.30 pt = {cost:.3f} R/trade")


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    print("Significativite de V3 (zone seule)")
    print("Un |t| < 2 signifie : indistinguable de zero.")
    a = collect(ins); stats(a, "IN-SAMPLE")
    b = collect(oos); stats(b, "OUT-OF-SAMPLE")
    stats(a + b, "TOTAL 15 mois")
