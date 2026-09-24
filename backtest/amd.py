#!/usr/bin/env python3
"""Modele AMD / Power of 3 : Asie accumule, Londres manipule, NY distribue.

Regle testee (section 4 de l'analyse) :
  - Asie NON EXPANSEE (range < seuil x moyenne 10 jours)
  - pendant Londres ou New York, un sweep du haut ou du bas de l'asiatique
  - entree dans le sens OPPOSE au cote balaye
  - biais H4 aligne avec cette direction
  - SL au-dela de l'extreme du sweep, TP a 1R et 2R

Le SL structurel n'est pas utilise ici : son rapport gain/risque median de
0.58 masquerait l'effet qu'on cherche a mesurer. On fixe le R:R pour isoler
la question "le sens choisi est-il le bon ?".

La ventilation par regime repond a la question decisive : le modele a-t-il
un edge, ou suit-il simplement la tendance de fond ?
"""
import sys, math, datetime, statistics, collections
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv

BENIN = 3600
ASIA   = (0,            4*3600)
LONDON = (8*3600,       11*3600)
NY     = (13*3600+1800, 19*3600)
DEPTH_H4 = 28            # barres H4 pour le biais
MAX_HOLD = 96


def sod(ts):  return (ts + BENIN) % 86400
def dayid(ts): return (ts + BENIN) // 86400


def bias_from(highs, lows, idx, lookback=20, depth=3):
    need = lookback + depth*2 + 2
    if idx < need - 1: return 0
    h = [highs[idx-k] for k in range(need)]
    l = [lows[idx-k] for k in range(need)]
    sh, sl = [], []
    for i in range(depth, lookback+depth):
        isH = isL = True
        for k in range(1, depth+1):
            if h[i] <= h[i-k] or h[i] <= h[i+k]: isH = False
            if l[i] >= l[i-k] or l[i] >= l[i+k]: isL = False
        if isH: sh.append(i)
        if isL: sl.append(i)
    if len(sh) < 2 or len(sl) < 2: return 0
    if h[sh[0]] > h[sh[1]] and l[sl[0]] > l[sl[1]]: return 1
    if h[sh[0]] < h[sh[1]] and l[sl[0]] < l[sl[1]]: return -1
    return 0


def build_days(m15):
    """Par jour Benin : indices, plage asiatique, cloture, tendance."""
    days = collections.OrderedDict()
    for i, (ts, o, h, l, c) in enumerate(m15):
        d = dayid(ts)
        if d not in days:
            days[d] = dict(idx=[], ahi=None, alo=None, open=o, close=c)
        days[d]["idx"].append(i)
        days[d]["close"] = c
        s = sod(ts)
        if ASIA[0] <= s < ASIA[1]:
            days[d]["ahi"] = h if days[d]["ahi"] is None else max(days[d]["ahi"], h)
            days[d]["alo"] = l if days[d]["alo"] is None else min(days[d]["alo"], l)
    return days


def run(m15, require_h4, require_asia, reverse, tp_mult, asia_thr=1.0):
    highs = [b[2] for b in m15]; lows = [b[3] for b in m15]
    h4t, h4h, h4l = [], [], []
    h4_at = []
    for ts, o, h, l, c in m15:
        b = ts - (ts % 14400)
        if not h4t or h4t[-1] != b:
            h4t.append(b); h4h.append(h); h4l.append(l)
        else:
            h4h[-1] = max(h4h[-1], h); h4l[-1] = min(h4l[-1], l)
        h4_at.append(len(h4t)-1)

    days = build_days(m15)
    keys = list(days.keys())
    asia_hist = []
    trades = []

    for di, d in enumerate(keys):
        info = days[d]
        if info["ahi"] is None or info["alo"] is None:
            continue
        arange = info["ahi"] - info["alo"]
        avg = statistics.mean(asia_hist[-10:]) if len(asia_hist) >= 3 else None
        asia_hist.append(arange)
        if avg is None:
            continue
        ratio = arange / avg if avg > 0 else 0
        if require_asia and ratio >= asia_thr:
            continue                                   # asiatique deja expansee

        # regime : tendance de fond AVANT ce jour (pas de look-ahead)
        prev_closes = [days[k]["close"] for k in keys[max(0, di-20):di]]
        regime = 0
        if len(prev_closes) >= 10:
            regime = 1 if prev_closes[-1] > statistics.mean(prev_closes) else -1
        # issue du jour, pour diagnostic uniquement
        day_up = 1 if info["close"] > info["open"] else -1

        out_up = out_dn = False
        taken = False
        for i in info["idx"]:
            if taken: break
            ts, o, h, l, c = m15[i]
            s = sod(ts)
            if not (LONDON[0] <= s < LONDON[1] or NY[0] <= s < NY[1]):
                continue
            if h > info["ahi"]: out_up = True
            if l < info["alo"]: out_dn = True

            swept = 0
            if out_up and c < info["ahi"]: swept = +1     # balayage du haut
            elif out_dn and c > info["alo"]: swept = -1   # balayage du bas
            if swept == 0:
                continue

            d_trade = (-swept) if reverse else swept
            if require_h4:
                bh4 = bias_from(h4h, h4l, h4_at[i])
                if bh4 != d_trade:
                    continue

            entry = c
            if d_trade > 0:
                lo_ext = min(m15[j][3] for j in info["idx"] if j <= i)
                sl = min(lo_ext, info["alo"])
            else:
                hi_ext = max(m15[j][2] for j in info["idx"] if j <= i)
                sl = max(hi_ext, info["ahi"])
            risk = abs(entry - sl)
            if risk <= 0:
                continue
            tp = entry + d_trade * risk * tp_mult

            R = None
            for k in range(i+1, min(i+1+MAX_HOLD, len(m15))):
                if dayid(m15[k][0]) != d: break
                _, _, hh, ll, cc = m15[k]
                hit_sl = (ll <= sl) if d_trade > 0 else (hh >= sl)
                hit_tp = (hh >= tp) if d_trade > 0 else (ll <= tp)
                if hit_sl: R = -1.0; break
                if hit_tp: R = tp_mult; break
                R = (cc - entry) * d_trade / risk
            if R is None:
                continue
            trades.append(dict(R=R, dir=d_trade, regime=regime, day_up=day_up))
            taken = True
    return trades


def show(tr, label):
    n = len(tr)
    if n < 3:
        print(f"  {label:<34} n={n}  insuffisant"); return
    v = [t["R"] for t in tr]
    m = statistics.mean(v); se = statistics.stdev(v)/math.sqrt(n)
    print(f"  {label:<34} n={n:<4} {m:+.3f} R  (t {m/se if se else 0:+.2f})")


def regimes(tr, label):
    print(f"\n  {label} — ventilation")
    for nm, key, vals in (("tendance de fond", "regime", (1, -1)),
                          ("issue du jour",    "day_up", (1, -1))):
        for v in vals:
            sub = [t for t in tr if t[key] == v]
            tag = "haussier" if v == 1 else "baissier"
            if len(sub) >= 3:
                x = [t["R"] for t in sub]
                mm = statistics.mean(x); ss = statistics.stdev(x)/math.sqrt(len(x))
                print(f"    {nm:<18} {tag:<9} n={len(sub):<4} {mm:+.3f} R  (t {mm/ss if ss else 0:+.2f})")
            else:
                print(f"    {nm:<18} {tag:<9} n={len(sub)}  insuffisant")


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    print("Modele AMD / Power of 3 — entree a contre-sens du balayage")
    print("TP a 2R, SL au-dela de l'extreme balaye. |t| < 2 => bruit.\n")

    variants = [
        ("regle complete (Asie+sweep+H4)", True,  True,  True),
        ("sans filtre H4",                 False, True,  True),
        ("sans filtre Asie",               True,  False, True),
        ("sweep seul, contre-sens",        False, False, True),
        ("CONTROLE : sens du sweep",       False, False, False),
    ]
    for lab, h4, asia, rev in variants:
        a = run(ins, h4, asia, rev, 2.0)
        b = run(oos, h4, asia, rev, 2.0)
        print(f"-- {lab}")
        show(a, "  in-sample"); show(b, "  out-of-sample")

    print("\n" + "="*62)
    full = run(bars, False, False, True, 2.0)
    show(full, "sweep seul contre-sens, 15 mois")
    regimes(full, "sweep seul contre-sens")
