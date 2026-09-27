#!/usr/bin/env python3
"""Cible par projection de la jambe de manipulation, contre cible structurelle.

Mecanique decrite dans les sources : au lieu de viser un plus bas anterieur,
on projette la jambe de manipulation — de l'extreme balaye jusqu'au sommet
qui l'a produite — et on place les cibles a des multiples de cette jambe.

On mesure ce que chaque methode produit comme rapport gain/risque, puis
son esperance. Notre defaut mesure est un R:R median de 0.58 : si la
projection le corrige, ca se verra ici.
"""
import sys, math, datetime, statistics
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv
from amd import sod, dayid, build_days, LONDON, NY
from mss import swings

MAX_HOLD = 96
LEVEL_DEPTH = 3


def setups(m15, mss_depth=2, mss_window=24):
    """Tous les setups AMD+MSS : balayage, confirmation, extreme, origine."""
    sw_hi, sw_lo = swings(m15, mss_depth)
    lvl_hi, lvl_lo = swings(m15, LEVEL_DEPTH)
    days = build_days(m15)
    out = []

    for d, info in days.items():
        if info["ahi"] is None or info["alo"] is None:
            continue
        out_up = out_dn = False
        pending = None
        taken = False
        for i in info["idx"]:
            if taken:
                break
            ts, o, h, l, c = m15[i]
            s = sod(ts)
            in_win = (LONDON[0] <= s < LONDON[1]) or (NY[0] <= s < NY[1])

            if pending is not None:
                if i - pending["bar"] > mss_window:
                    pending = None
                else:
                    lv = pending["level"]
                    if (c > lv) if pending["dir"] > 0 else (c < lv):
                        pending.update(entry=c, entry_i=i, day=d)
                        out.append(pending)
                        taken = True
                        continue

            if not in_win:
                continue
            if h > info["ahi"]: out_up = True
            if l < info["alo"]: out_dn = True
            swept = 0
            if out_up and c < info["ahi"]: swept = +1
            elif out_dn and c > info["alo"]: swept = -1
            if swept == 0 or pending is not None:
                continue

            dt = -swept
            span = [j for j in info["idx"] if j <= i]
            ext = (min(m15[j][3] for j in span) if dt > 0
                   else max(m15[j][2] for j in span))
            ext_i = next(j for j in span
                         if (m15[j][3] if dt > 0 else m15[j][2]) == ext)
            src = sw_hi if dt > 0 else sw_lo
            cand = [(b, p) for (cf, b, p) in src if b < ext_i and cf <= i]
            if not cand:
                continue
            pending = dict(bar=i, level=cand[-1][1], ext=ext, ext_i=ext_i,
                           dir=dt, lvl_hi=lvl_hi, lvl_lo=lvl_lo)
    return out


def targets(s, method, m15):
    """Renvoie (tp1, tp2) selon la methode choisie."""
    d, entry, ext, j = s["dir"], s["entry"], s["ext"], s["entry_i"]
    if method == "structure":
        av_h = [p for (cf, b, p) in s["lvl_hi"] if cf <= j]
        av_l = [p for (cf, b, p) in s["lvl_lo"] if cf <= j]
        if d > 0:
            t1 = next((p for p in reversed(av_h) if p > entry), None)
            t2 = next((p for p in reversed(av_h) if t1 and p > t1), None)
        else:
            t1 = next((p for p in reversed(av_l) if p < entry), None)
            t2 = next((p for p in reversed(av_l) if t1 and p < t1), None)
        return t1, t2
    # projection : la jambe va de l'extreme au sommet qui l'a produite
    leg = abs(s["level"] - ext)
    if leg <= 0:
        return None, None
    return ext + d * 2.5 * leg, ext + d * 4.5 * leg


def evaluate(s, tp1, tp2, m15):
    d, entry, sl, j = s["dir"], s["entry"], s["ext"], s["entry_i"]
    risk = abs(entry - sl)
    if risk <= 0 or tp1 is None:
        return None
    rr = abs(tp1 - entry) / risk
    if (tp1 - entry) * d <= 0:
        return None                      # cible du mauvais cote
    R = None
    for k in range(j + 1, min(j + 1 + MAX_HOLD, len(m15))):
        if dayid(m15[k][0]) != s["day"]:
            break
        _, _, h, l, c = m15[k]
        if (l <= sl) if d > 0 else (h >= sl):
            R = -1.0; break
        if (h >= tp1) if d > 0 else (l <= tp1):
            R = rr; break
        R = (c - entry) * d / risk
    return None if R is None else dict(R=R, rr=rr)


def report(rows, label):
    n = len(rows)
    if n < 3:
        print(f"  {label:<26} n={n} insuffisant"); return
    rrs = sorted(r["rr"] for r in rows)
    v = [r["R"] for r in rows]
    m = statistics.mean(v); se = statistics.stdev(v)/math.sqrt(n)
    print(f"  {label:<26} n={n:<4} R:R median {rrs[n//2]:5.2f}   "
          f"sous 1:1 {100*sum(1 for x in rrs if x < 1)/n:3.0f} %   "
          f"esperance {m:+.3f} R (t {m/se if se else 0:+.2f})")


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp()
    print("Cibles comparees sur la regle AMD + MSS\n")
    for lbl, data in (("IN-SAMPLE", [b for b in bars if b[0] < split]),
                      ("OUT-OF-SAMPLE", [b for b in bars if b[0] >= split])):
        print(f"-- {lbl}")
        ss = setups(data)
        for meth in ("structure", "projection"):
            rows = []
            for s in ss:
                t1, t2 = targets(s, meth, data)
                r = evaluate(s, t1, t2, data)
                if r: rows.append(r)
            report(rows, meth)
