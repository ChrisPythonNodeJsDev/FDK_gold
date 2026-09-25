#!/usr/bin/env python3
"""Quatre combinaisons sur la meilleure regle trouvee (AMD + MSS).

Le probleme mesure n'est pas le taux de reussite mais le rapport
gain/risque. Deux leviers agissent dessus :

  STOP     swing   = derriere l'extreme du balayage        (etroit)
           session = au-dela de la session precedente      (large)
  ENTREE   cassure = a la cloture qui confirme le MSS
           retrait = sur le retour dans le desequilibre (FVG) laisse
                     par le deplacement, donc a meilleur prix

Le retrait ameliore mecaniquement le R:R mais fait manquer les trades
qui ne reviennent pas. C'est l'arbitrage qu'on mesure.
"""
import sys, math, datetime, statistics
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv
from amd import sod, dayid, build_days, LONDON, NY
from mss import swings

MAX_HOLD, FVG_WAIT = 96, 24


def session_of(s):
    if LONDON[0] <= s < LONDON[1]: return "LONDRES"
    if NY[0] <= s < NY[1]:         return "NY"
    return None


def prev_session_range(m15, idx_list, upto, sess):
    """Plage de la session precedant celle du signal, meme journee."""
    win = (0, 4*3600) if sess == "LONDRES" else LONDON
    hi = lo = None
    for j in idx_list:
        if j > upto: break
        s = sod(m15[j][0])
        if win[0] <= s < win[1]:
            hi = m15[j][2] if hi is None else max(hi, m15[j][2])
            lo = m15[j][3] if lo is None else min(lo, m15[j][3])
    return hi, lo


def find_fvg(m15, a, b, direction):
    """Dernier desequilibre a trois barres dans le deplacement [a..b]."""
    best = None
    for i in range(max(a+1, 1), min(b, len(m15)-1)):
        if direction > 0 and m15[i+1][3] > m15[i-1][2]:
            best = (m15[i-1][2], m15[i+1][3])      # (bas, haut) du gap
        elif direction < 0 and m15[i+1][2] < m15[i-1][3]:
            best = (m15[i+1][2], m15[i-1][3])
    return best


def run(m15, stop_mode, entry_mode, tp_mult=2.0, mss_depth=2, mss_window=24):
    sw_hi, sw_lo = swings(m15, mss_depth)
    days = build_days(m15); keys = list(days.keys())
    trades = []

    for d in keys:
        info = days[d]
        if info["ahi"] is None or info["alo"] is None: continue
        out_up = out_dn = False
        pending = None; taken = False

        for i in info["idx"]:
            if taken: break
            ts, o, h, l, c = m15[i]
            s = sod(ts); sess = session_of(s)

            if pending is not None and pending.get("armed"):
                if i - pending["mss_bar"] > FVG_WAIT:
                    pending = None
                else:
                    d_tr = pending["dir"]; g = pending["fvg"]
                    hit = (l <= g[1]) if d_tr > 0 else (h >= g[0])
                    if hit:
                        entry = g[1] if d_tr > 0 else g[0]
                        trades.append(dict(pending=pending, entry=entry, bar=i))
                        pending["fill"] = (entry, i); taken = True
                        continue

            if pending is not None and not pending.get("armed"):
                if i - pending["bar"] > mss_window:
                    pending = None
                else:
                    lvl = pending["level"]
                    if (c > lvl) if pending["dir"] > 0 else (c < lvl):
                        d_tr = pending["dir"]
                        if entry_mode == "cassure":
                            pending["fill"] = (c, i); taken = True
                            trades.append(dict(pending=pending, entry=c, bar=i))
                            continue
                        g = find_fvg(m15, pending["ext_i"], i, d_tr)
                        if g is None:
                            pending = None
                        else:
                            pending["armed"] = True
                            pending["fvg"] = g
                            pending["mss_bar"] = i
                        continue

            if sess is None: continue
            if h > info["ahi"]: out_up = True
            if l < info["alo"]: out_dn = True
            swept = 0
            if out_up and c < info["ahi"]: swept = +1
            elif out_dn and c > info["alo"]: swept = -1
            if swept == 0 or pending is not None: continue

            d_tr = -swept
            span = [j for j in info["idx"] if j <= i]
            ext = (min(m15[j][3] for j in span) if d_tr > 0
                   else max(m15[j][2] for j in span))
            ext_i = next(j for j in span
                         if (m15[j][3] if d_tr > 0 else m15[j][2]) == ext)
            src = sw_hi if d_tr > 0 else sw_lo
            cand = [(b, p) for (cf, b, p) in src if b < ext_i and cf <= i]
            if not cand: continue
            pending = dict(bar=i, level=cand[-1][1], ext=ext, ext_i=ext_i,
                           dir=d_tr, sess=sess, idx=info["idx"], day=d)

    # --- evaluation
    out = []
    for t in trades:
        p = t["pending"]; d_tr = p["dir"]; entry = t["entry"]; j = t["bar"]
        if stop_mode == "swing":
            sl = p["ext"]
        else:
            hi, lo = prev_session_range(m15, p["idx"], p["bar"], p["sess"])
            if hi is None: continue
            sl = hi if d_tr < 0 else lo
        risk = abs(entry - sl)
        if risk <= 0: continue
        tp = entry + d_tr*risk*tp_mult
        R = None
        for k in range(j+1, min(j+1+MAX_HOLD, len(m15))):
            if dayid(m15[k][0]) != p["day"]: break
            _,_,hh,ll,cc = m15[k]
            if (ll <= sl) if d_tr > 0 else (hh >= sl): R = -1.0; break
            if (hh >= tp) if d_tr > 0 else (ll <= tp): R = tp_mult; break
            R = (cc-entry)*d_tr/risk
        if R is not None:
            out.append(dict(R=R, risk=risk, sess=p["sess"]))
    return out


def show(tr, lab):
    n = len(tr)
    if n < 3:
        print(f"  {lab:<38} n={n}  insuffisant"); return
    v = [t["R"] for t in tr]
    m = statistics.mean(v); se = statistics.stdev(v)/math.sqrt(n)
    risks = sorted(t["risk"] for t in tr)
    print(f"  {lab:<38} n={n:<4} {m:+.3f} R  (t {m/se if se else 0:+.2f})"
          f"   risque median {risks[n//2]:.2f} pts")


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026,5,1,tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    print("AMD + MSS : stop et entree croises — TP a 2R")
    print("|t| < 2 => indistinguable de zero\n")
    for sm in ("swing", "session"):
        for em in ("cassure", "retrait"):
            lab = f"stop {sm} / entree {em}"
            print(f"-- {lab}")
            show(run(ins, sm, em), "  in-sample")
            show(run(oos, sm, em), "  out-of-sample")
