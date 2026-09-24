#!/usr/bin/env python3
"""AMD complet : balayage PUIS changement de structure avant d'entrer.

La version precedente entrait au balayage, a l'aveugle. Le modele tel
qu'il est enseigne exige une preuve que le retournement a lieu :

  1. l'Asie pose un haut et un bas de reference
  2. pendant Londres ou New York, le prix sort d'un cote puis referme
     a l'interieur  -> manipulation
  3. CONFIRMATION (MSS) : le prix cloture ensuite au-dela du dernier
     swing oppose anterieur a l'extreme du balayage
  4. entree a cette cloture, stop derriere l'extreme du balayage

Sans l'etape 3, on pariait sur un retournement. Avec elle, on attend
qu'il se manifeste.
"""
import sys, math, datetime, statistics, collections
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv
from amd import sod, dayid, bias_from, build_days, ASIA, LONDON, NY

MAX_HOLD = 96


def swings(m15, depth):
    hi, lo = [], []
    for i in range(depth, len(m15)-depth):
        h, l = m15[i][2], m15[i][3]
        isH = isL = True
        for k in range(1, depth+1):
            if h <= m15[i-k][2] or h <= m15[i+k][2]: isH = False
            if l >= m15[i-k][3] or l >= m15[i+k][3]: isL = False
        if isH: hi.append((i+depth, i, h))
        if isL: lo.append((i+depth, i, l))
    return hi, lo


def run(m15, require_asia, require_h4, use_mss, tp_mult=2.0,
        mss_depth=2, mss_window=24, asia_thr=1.0):
    sw_hi, sw_lo = swings(m15, mss_depth)
    h4t, h4h, h4l, h4_at = [], [], [], []
    for ts, o, h, l, c in m15:
        b = ts - (ts % 14400)
        if not h4t or h4t[-1] != b:
            h4t.append(b); h4h.append(h); h4l.append(l)
        else:
            h4h[-1] = max(h4h[-1], h); h4l[-1] = min(h4l[-1], l)
        h4_at.append(len(h4t)-1)

    days = build_days(m15); keys = list(days.keys())
    asia_hist, trades = [], []

    for di, d in enumerate(keys):
        info = days[d]
        if info["ahi"] is None or info["alo"] is None: continue
        arange = info["ahi"] - info["alo"]
        avg = statistics.mean(asia_hist[-10:]) if len(asia_hist) >= 3 else None
        asia_hist.append(arange)
        if avg is None: continue
        ratio = arange/avg if avg > 0 else 0
        if require_asia and ratio >= asia_thr: continue

        prev = [days[k]["close"] for k in keys[max(0,di-20):di]]
        regime = 0
        if len(prev) >= 10:
            regime = 1 if prev[-1] > statistics.mean(prev) else -1

        out_up = out_dn = False
        pending = None          # attente de confirmation
        taken = False

        for i in info["idx"]:
            if taken: break
            ts, o, h, l, c = m15[i]
            s = sod(ts)
            in_win = (LONDON[0] <= s < LONDON[1]) or (NY[0] <= s < NY[1])

            # --- surveillance d'une confirmation en attente
            if pending is not None:
                if i - pending["bar"] > mss_window:
                    pending = None
                else:
                    lvl = pending["level"]
                    ok = (c > lvl) if pending["dir"] > 0 else (c < lvl)
                    if ok:
                        d_tr = pending["dir"]
                        entry, sl = c, pending["ext"]
                        risk = abs(entry - sl)
                        if risk > 0:
                            if require_h4 and bias_from(h4h, h4l, h4_at[i]) != d_tr:
                                pending = None
                            else:
                                tp = entry + d_tr*risk*tp_mult
                                R = None
                                for k in range(i+1, min(i+1+MAX_HOLD, len(m15))):
                                    if dayid(m15[k][0]) != d: break
                                    _,_,hh,ll,cc = m15[k]
                                    if (ll <= sl) if d_tr>0 else (hh >= sl): R=-1.0; break
                                    if (hh >= tp) if d_tr>0 else (ll <= tp): R=tp_mult; break
                                    R = (cc-entry)*d_tr/risk
                                if R is not None:
                                    trades.append(dict(R=R, dir=d_tr, regime=regime))
                                    taken = True
                                    continue
                        pending = None

            if not in_win: continue
            if h > info["ahi"]: out_up = True
            if l < info["alo"]: out_dn = True

            swept = 0
            if out_up and c < info["ahi"]: swept = +1
            elif out_dn and c > info["alo"]: swept = -1
            if swept == 0 or pending is not None: continue

            d_tr = -swept                      # contre-sens du balayage
            span = [j for j in info["idx"] if j <= i]
            ext = (min(m15[j][3] for j in span) if d_tr > 0
                   else max(m15[j][2] for j in span))
            ext_i = next(j for j in span
                         if (m15[j][3] if d_tr > 0 else m15[j][2]) == ext)

            if not use_mss:
                entry, sl = c, ext
                risk = abs(entry-sl)
                if risk <= 0: continue
                if require_h4 and bias_from(h4h, h4l, h4_at[i]) != d_tr: continue
                tp = entry + d_tr*risk*tp_mult
                R = None
                for k in range(i+1, min(i+1+MAX_HOLD, len(m15))):
                    if dayid(m15[k][0]) != d: break
                    _,_,hh,ll,cc = m15[k]
                    if (ll <= sl) if d_tr>0 else (hh >= sl): R=-1.0; break
                    if (hh >= tp) if d_tr>0 else (ll <= tp): R=tp_mult; break
                    R = (cc-entry)*d_tr/risk
                if R is not None:
                    trades.append(dict(R=R, dir=d_tr, regime=regime)); taken = True
                continue

            # niveau dont la cassure confirmera le retournement
            src = sw_hi if d_tr > 0 else sw_lo
            cand = [(b, p) for (cf, b, p) in src if b < ext_i and cf <= i]
            if not cand: continue
            level = cand[-1][1]
            pending = dict(bar=i, level=level, ext=ext, dir=d_tr)

    return trades


def show(tr, lab):
    n = len(tr)
    if n < 3:
        print(f"  {lab:<32} n={n}  insuffisant"); return
    v = [t["R"] for t in tr]
    m = statistics.mean(v); se = statistics.stdev(v)/math.sqrt(n)
    print(f"  {lab:<32} n={n:<4} {m:+.3f} R  (t {m/se if se else 0:+.2f})")


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026,5,1,tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    print("AMD avec confirmation par changement de structure (MSS)")
    print("TP a 2R, SL derriere l'extreme du balayage. |t| < 2 => bruit.\n")

    for lab, asia, h4, mss in [
        ("MSS seul",                False, False, True),
        ("MSS + Asie compressee",   True,  False, True),
        ("MSS + H4",                False, True,  True),
        ("MSS + Asie + H4",         True,  True,  True),
        ("SANS MSS (reference)",    False, False, False)]:
        print(f"-- {lab}")
        show(run(ins, asia, h4, mss), "  in-sample")
        show(run(oos, asia, h4, mss), "  out-of-sample")

    print("\n" + "="*62)
    full = run(bars, False, False, True)
    show(full, "MSS seul, 15 mois")
    for v, tag in ((1,"haussiere"), (-1,"baissiere")):
        sub=[t for t in full if t["regime"]==v]
        if len(sub)>=3:
            x=[t["R"] for t in sub]; mm=statistics.mean(x)
            ss=statistics.stdev(x)/math.sqrt(len(x))
            print(f"    tendance de fond {tag:<10} n={len(sub):<4} {mm:+.3f} R  (t {mm/ss if ss else 0:+.2f})")
