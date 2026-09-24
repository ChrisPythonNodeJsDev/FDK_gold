#!/usr/bin/env python3
"""Robustesse : le resultat tient-il hors des parametres par defaut ?
Et que reste-t-il une fois le spread paye ?"""
import sys, statistics
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from backtest import load_yahoo, load_mt5_csv, wilder_atr, session_of, MAX_HOLD
from bt2 import simulate, score


def bias(highs, lows, idx, lb, dp):
    need = lb + dp * 2 + 2
    if idx < need - 1: return 0
    h = [highs[idx - k] for k in range(need)]
    l = [lows[idx - k] for k in range(need)]
    sh, sl = [], []
    for i in range(dp, lb + dp):
        isH = isL = True
        for k in range(1, dp + 1):
            if h[i] <= h[i-k] or h[i] <= h[i+k]: isH = False
            if l[i] >= l[i-k] or l[i] >= l[i+k]: isL = False
        if isH: sh.append(i)
        if isL: sl.append(i)
    if len(sh) < 2 or len(sl) < 2: return 0
    if h[sh[0]] > h[sh[1]] and l[sl[0]] > l[sl[1]]: return 1
    if h[sh[0]] < h[sh[1]] and l[sl[0]] < l[sl[1]]: return -1
    return 0


def run(m15, lb, dp):
    atr = wilder_atr(m15)
    hs = [b[2] for b in m15]; ls = [b[3] for b in m15]
    h4t, h4h, h4l = [], [], []
    out, prev, busy = [], 0, -1
    for i, (ts, o, h, l, c) in enumerate(m15):
        b = ts - (ts % 14400)
        if not h4t or h4t[-1] != b: h4t.append(b); h4h.append(h); h4l.append(l)
        else: h4h[-1] = max(h4h[-1], h); h4l[-1] = min(h4l[-1], l)
        if atr[i] is None or atr[i] <= 0: continue
        bm = bias(hs, ls, i, lb, dp)
        bh = bias(h4h, h4l, len(h4t) - 1, lb, dp)
        s = session_of(ts)
        ok = bm != 0 and bm == bh and s is not None
        new = ok and prev != bm
        prev = bm if ok else 0
        if not new or i <= busy: continue
        r = atr[i]
        ev = simulate(m15, i, bm, c, r, c + bm*r, c + bm*2*r)
        A, B, C = score(ev, bm, c, r)
        busy = i + ev["bars"]
        out.append((A, B, C, r))
    return out


if __name__ == "__main__":
    import os
    src=sys.argv[1]
    m15 = load_yahoo(src) if src.endswith(".json") else load_mt5_csv(src, 0)
    print("Sensibilite aux parametres de structure (scenario C, net de spread 0) :")
    print(f"  {'lookback':>8} {'depth':>6} {'n':>5} {'total C':>9} {'moy C':>8}")
    base = None
    for lb in (15, 20, 25, 30):
        for dp in (2, 3, 4):
            t = run(m15, lb, dp)
            if not t:
                print(f"  {lb:>8} {dp:>6} {0:>5}"); continue
            tot = sum(x[2] for x in t)
            mark = "   <- defaut" if (lb, dp) == (20, 3) else ""
            print(f"  {lb:>8} {dp:>6} {len(t):>5} {tot:>+9.2f} {tot/len(t):>+8.3f}{mark}")
            if (lb, dp) == (20, 3): base = t

    print("\nCout du spread (parametres par defaut, scenario C) :")
    risks = [x[3] for x in base]
    print(f"  ATR moyen au signal : {statistics.mean(risks):.2f} points")
    n = len(base); tot = sum(x[2] for x in base)
    for sp in (0.0, 0.20, 0.30, 0.50, 1.00):
        cost = sp / statistics.mean(risks)          # en R, aller-retour ~1 spread
        net = (tot - cost * n) / n
        print(f"  spread {sp:>4.2f} pt  ->  cout {cost:.3f} R/trade  ->  esperance nette {net:+.3f} R")
