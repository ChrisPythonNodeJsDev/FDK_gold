#!/usr/bin/env python3
"""Hypothese des points numerotes : dans une fenetre quotidienne, on numerote
les swings. Un HIGH #2 plus bas que le HIGH #1 confirme une structure
baissiere ; un LOW #2 plus haut que le LOW #1 confirme la hausse.

Interpretation la plus simple :
  - la numerotation repart chaque jour
  - la confirmation se joue au #2, on ne regarde pas au-dela
  - entree a la cloture de la bougie qui CONFIRME le swing, soit `depth`
    bougies apres le sommet lui-meme (aucune anticipation)
  - SL et TP suivent la regle de structure : stop sur le swing oppose,
    cibles sur les deux swings precedents dans le sens du trade
"""
import sys, math, datetime, statistics, collections
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv

BENIN = 3600
WIN_START, WIN_END = 11*3600, 13*3600 + 1800      # 11h00 - 13h30 heure Benin
LEVEL_DEPTH = 3                                    # swings servant aux SL/TP


def sod(ts):
    return (ts + BENIN) % 86400


def day_id(ts):
    return (ts + BENIN) // 86400


def find_swings(m15, depth):
    """(confirm_idx, bar_idx, prix) ; confirme `depth` bougies apres le sommet."""
    hi, lo = [], []
    n = len(m15)
    for i in range(depth, n - depth):
        h, l = m15[i][2], m15[i][3]
        isH = isL = True
        for k in range(1, depth + 1):
            if h <= m15[i-k][2] or h <= m15[i+k][2]: isH = False
            if l >= m15[i-k][3] or l >= m15[i+k][3]: isL = False
        if isH: hi.append((i + depth, i, h))
        if isL: lo.append((i + depth, i, l))
    return hi, lo


def levels(short, entry, lvl_hi, lvl_lo, j):
    """Regle de l'utilisateur : stop sur le dernier swing oppose,
    cibles sur les deux swings precedents. None si la structure manque."""
    avail_h = [p for (c, b, p) in lvl_hi if c <= j]
    avail_l = [p for (c, b, p) in lvl_lo if c <= j]
    if short:
        sl = next((p for p in reversed(avail_h) if p > entry), None)
        t1 = next((p for p in reversed(avail_l) if p < entry), None)
        t2 = next((p for p in reversed(avail_l) if t1 is not None and p < t1), None)
    else:
        sl = next((p for p in reversed(avail_l) if p < entry), None)
        t1 = next((p for p in reversed(avail_h) if p > entry), None)
        t2 = next((p for p in reversed(avail_h) if t1 is not None and p > t1), None)
    return sl, t1, t2


def simulate(m15, j, d, entry, sl, t1, t2):
    """Ordre intra-barre toujours defavorable. Sortie en fin de journee Benin."""
    risk = abs(entry - sl)
    if risk <= 0:
        return None
    ev = dict(sl=None, t1=None, t2=None, be=None, close=entry)
    dj = day_id(m15[j][0])
    for k in range(j + 1, len(m15)):
        if day_id(m15[k][0]) != dj:
            break
        _, _, h, l, c = m15[k]
        ev["close"] = c
        hit_sl = (h >= sl) if d < 0 else (l <= sl)
        hit_be = (h >= entry) if d < 0 else (l <= entry)
        hit_t1 = (l <= t1) if d < 0 else (h >= t1)
        hit_t2 = (t2 is not None) and ((l <= t2) if d < 0 else (h >= t2))
        if hit_sl and ev["sl"] is None: ev["sl"] = k
        if hit_be and ev["be"] is None: ev["be"] = k
        if hit_t1 and ev["t1"] is None: ev["t1"] = k
        if hit_t2 and ev["t2"] is None: ev["t2"] = k
        if ev["sl"] is not None or ev["t2"] is not None:
            break
    tf = (ev["close"] - entry) * d / risk
    first = lambda a, b: a is not None and (b is None or a <= b)
    A = -1.0 if first(ev["sl"], ev["t1"]) else (+1.0 * abs(t1-entry)/risk if ev["t1"] else tf)
    if t2 is None:
        B = A
    elif first(ev["sl"], ev["t2"]):
        B = -1.0
    elif ev["t2"] is not None:
        B = abs(t2 - entry) / risk
    else:
        B = tf
    if first(ev["sl"], ev["t1"]):
        C = -1.0
    elif ev["t1"] is not None:
        g1 = abs(t1 - entry) / risk
        rest_be = ev["be"] is not None and ev["be"] > ev["t1"]
        rest_t2 = ev["t2"] is not None and ev["t2"] > ev["t1"]
        if rest_t2 and (not rest_be or ev["t2"] <= ev["be"]):
            C = 0.5*g1 + 0.5*(abs(t2-entry)/risk)
        elif rest_be:
            C = 0.5*g1
        else:
            C = 0.5*g1 + 0.5*tf
    else:
        C = tf
    return dict(A=A, B=B, C=C, risk=risk,
                win=(ev["t1"] is not None and not first(ev["sl"], ev["t1"])))


def run(m15, depth, scope):
    win_hi, win_lo = find_swings(m15, depth)
    lvl_hi, lvl_lo = find_swings(m15, LEVEL_DEPTH)
    by_confirm = collections.defaultdict(list)
    for (c, b, p) in win_hi: by_confirm[c].append(("H", b, p))
    for (c, b, p) in win_lo: by_confirm[c].append(("L", b, p))

    trades, cur_day, highs, lows, done = [], None, [], [], False
    for j in range(len(m15)):
        ts = m15[j][0]
        d_id = day_id(ts)
        if d_id != cur_day:
            cur_day, highs, lows, done = d_id, [], [], False
        if done or j not in by_confirm:
            continue
        for kind, b, p in by_confirm[j]:
            s = sod(m15[b][0])
            if scope == "window" and not (WIN_START <= s < WIN_END):
                continue
            if not (WIN_START <= sod(ts) < WIN_END):     # confirmation dans la fenetre
                continue
            lst = highs if kind == "H" else lows
            lst.append(p)
            if len(lst) == 2:
                short = (kind == "H" and lst[1] < lst[0])
                long_ = (kind == "L" and lst[1] > lst[0])
                if not (short or long_):
                    continue
                d = -1 if short else 1
                entry = m15[j][4]
                sl, t1, t2 = levels(short, entry, lvl_hi, lvl_lo, j)
                if sl is None or t1 is None:
                    continue
                r = simulate(m15, j, d, entry, sl, t1, t2)
                if r:
                    r["dir"] = d
                    trades.append(r)
                    done = True
                break
    return trades


def stats(tr, label):
    n = len(tr)
    if n < 2:
        print(f"  {label:<26} n={n:<4} insuffisant"); return
    w = sum(1 for t in tr if t["win"]) / n
    out = [f"  {label:<26} n={n:<4} TP1 {100*w:4.0f}%"]
    for k in "ABC":
        v = [t[k] for t in tr]
        m = statistics.mean(v)
        se = statistics.stdev(v)/math.sqrt(n)
        out.append(f"{k} {m:+.3f}(t{m/se if se else 0:+.1f})")
    print("  ".join(out))


if __name__ == "__main__":
    bars = load_mt5_csv(sys.argv[1], 0)
    split = datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    print("Confirmation par points numerotes — fenetre 11h00-13h30 Benin")
    print("A = sortie TP1 | B = vise TP2 | C = moitie TP1 + point mort")
    print("|t| < 2 => indistinguable de zero\n")
    for scope in ("window", "day"):
        for depth in (1, 2, 3):
            lab = f"swings {scope}, depth {depth}"
            print(f"-- {lab}")
            stats(run(ins, depth, scope), "  in-sample")
            stats(run(oos, depth, scope), "  out-of-sample")
