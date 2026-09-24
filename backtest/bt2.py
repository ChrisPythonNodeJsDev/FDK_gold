#!/usr/bin/env python3
"""Backtest FDK_Gold_Custom - version corrigee, 3 scenarios de gestion.

L'indicateur ne definit pas de stop. On en impose un a 1 x ATR, donc
TP1 = +1R et TP2 = +2R. Trois gestions coherentes sont mesurees
separement (on ne peut pas encaisser TP1 ET viser TP2 a la fois) :
  A  sortie integrale a TP1
  B  maintien jusqu'a TP2, stop fixe
  C  moitie a TP1, stop au point mort sur le reste, reste vers TP2
Ordre intra-barre toujours defavorable (stop/point mort avant TP).
"""
import sys, datetime, collections
sys.path.insert(0, __file__.rsplit("/", 1)[0])
from backtest import (load_yahoo, load_mt5_csv, compute_bias, wilder_atr,
                      session_of, SESSIONS, MAX_HOLD)


def simulate(m15, i, direction, entry, risk, tp1, tp2):
    """Renvoie les indices de premiere touche, ordre intra-barre defavorable."""
    ev = dict(stop=None, tp1=None, tp2=None, be=None, last_close=entry, bars=0)
    stop = entry - direction * risk
    for j in range(i + 1, min(i + 1 + MAX_HOLD, len(m15))):
        _, _, h, l, c = m15[j]
        ev["last_close"], ev["bars"] = c, j - i
        touch_stop = (l <= stop) if direction > 0 else (h >= stop)
        touch_be   = (l <= entry) if direction > 0 else (h >= entry)
        touch_tp1  = (h >= tp1)  if direction > 0 else (l <= tp1)
        touch_tp2  = (h >= tp2)  if direction > 0 else (l <= tp2)
        if touch_stop and ev["stop"] is None: ev["stop"] = j
        if touch_be  and ev["be"]  is None:   ev["be"]  = j
        if touch_tp1 and ev["tp1"] is None:   ev["tp1"] = j
        if touch_tp2 and ev["tp2"] is None:   ev["tp2"] = j
        if ev["stop"] is not None or ev["tp2"] is not None:
            break
    return ev


def score(ev, direction, entry, risk):
    first = lambda a, b: a is not None and (b is None or a <= b)
    tf = (ev["last_close"] - entry) * direction / risk      # sortie au temps

    # A : tout a TP1
    if first(ev["stop"], ev["tp1"]):      A = -1.0
    elif ev["tp1"] is not None:           A = +1.0
    else:                                 A = tf
    # B : viser TP2, stop fixe
    if first(ev["stop"], ev["tp2"]):      B = -1.0
    elif ev["tp2"] is not None:           B = +2.0
    else:                                 B = tf
    # C : moitie a TP1 puis point mort
    if first(ev["stop"], ev["tp1"]):
        C = -1.0
    elif ev["tp1"] is not None:
        rest_be = ev["be"] is not None and ev["be"] > ev["tp1"]
        rest_tp2 = ev["tp2"] is not None and ev["tp2"] > ev["tp1"]
        if rest_be and (not rest_tp2 or ev["be"] <= ev["tp2"]):   C = 0.5 + 0.0
        elif rest_tp2:                                            C = 0.5 + 1.0
        else:                                                     C = 0.5 + 0.5 * tf
    else:
        C = tf
    return A, B, C


def run(m15, label):
    atr = wilder_atr(m15)
    highs = [b[2] for b in m15]
    lows  = [b[3] for b in m15]
    h4_t, h4_h, h4_l = [], [], []
    trades, allowed_bars, total_bars, prev_dir = [], 0, 0, 0
    busy_until = -1

    for i, (ts, o, h, l, c) in enumerate(m15):
        bucket = ts - (ts % 14400)
        if not h4_t or h4_t[-1] != bucket:
            h4_t.append(bucket); h4_h.append(h); h4_l.append(l)
        else:
            h4_h[-1] = max(h4_h[-1], h); h4_l[-1] = min(h4_l[-1], l)

        if atr[i] is None or atr[i] <= 0:
            continue
        total_bars += 1
        bM15 = compute_bias(highs, lows, i)
        bH4  = compute_bias(h4_h, h4_l, len(h4_t) - 1)
        sess = session_of(ts)
        allowed = (bM15 != 0 and bM15 == bH4 and sess is not None)
        if allowed:
            allowed_bars += 1
        new_signal = allowed and prev_dir != bM15
        prev_dir = bM15 if allowed else 0

        if not new_signal or i <= busy_until:
            continue
        risk = atr[i]
        tp1 = c + bM15 * atr[i] * 1.0
        tp2 = c + bM15 * atr[i] * 2.0
        ev = simulate(m15, i, bM15, c, risk, tp1, tp2)
        A, B, C = score(ev, bM15, c, risk)
        busy_until = i + ev["bars"]
        trades.append(dict(ts=ts, dir=bM15, session=sess, A=A, B=B, C=C,
                           bars=ev["bars"],
                           hit_tp1=ev["tp1"] is not None,
                           stop_first=(ev["stop"] is not None and
                                       (ev["tp1"] is None or ev["stop"] <= ev["tp1"]))))
    return trades, allowed_bars, total_bars


def report(trades, allowed_bars, total_bars, m15, label):
    d0 = datetime.datetime.fromtimestamp(m15[0][0], datetime.timezone.utc)
    d1 = datetime.datetime.fromtimestamp(m15[-1][0], datetime.timezone.utc)
    px = [b[4] for b in m15]
    print("=" * 68)
    print(f"  {label}")
    print(f"  {len(m15)} bougies M15  |  {d0:%Y-%m-%d} -> {d1:%Y-%m-%d}")
    print(f"  prix {min(px):.2f} -> {max(px):.2f}  (debut {px[0]:.2f}, fin {px[-1]:.2f})")
    print("=" * 68)
    pct = 100.0 * allowed_bars / total_bars if total_bars else 0
    print(f"Barres avec entree autorisee : {allowed_bars}/{total_bars} ({pct:.1f} %)")
    n = len(trades)
    print(f"Signaux declenches           : {n}")
    if not n:
        print("Aucun trade."); return
    print(f"TP1 touche avant le stop     : {sum(t['hit_tp1'] and not t['stop_first'] for t in trades)}/{n}")
    print(f"Stoppe avant TP1             : {sum(t['stop_first'] for t in trades)}/{n}")
    print(f"Duree mediane                : {sorted(t['bars'] for t in trades)[n//2]} bougies M15")

    print("\n  Scenario                         total R   esperance/trade")
    for k, name in (("A", "A  tout a TP1 (1R)"),
                    ("B", "B  viser TP2 (2R), stop fixe"),
                    ("C", "C  moitie TP1 + point mort")):
        tot = sum(t[k] for t in trades)
        print(f"  {name:<32} {tot:+7.2f} R   {tot/n:+.3f} R")

    print("\nPar session (scenario C) :")
    for name, _, _ in SESSIONS:
        sub = [t for t in trades if t["session"] == name]
        if sub:
            r = sum(t["C"] for t in sub)
            print(f"  {name:<8} n={len(sub):>3}  {r:+7.2f} R  moy {r/len(sub):+.3f} R")
    print("\nPar sens (scenario C) :")
    for dn, dv in (("LONG", 1), ("SHORT", -1)):
        sub = [t for t in trades if t["dir"] == dv]
        if sub:
            r = sum(t["C"] for t in sub)
            print(f"  {dn:<8} n={len(sub):>3}  {r:+7.2f} R  moy {r/len(sub):+.3f} R")


if __name__ == "__main__":
    src = sys.argv[1]
    lbl = sys.argv[2] if len(sys.argv) > 2 else src
    bars = load_yahoo(src) if src.endswith(".json") else \
           load_mt5_csv(src, int(sys.argv[3]) if len(sys.argv) > 3 else 0)
    tr, ab, tb = run(bars, lbl)
    report(tr, ab, tb, bars, lbl)
