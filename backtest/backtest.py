#!/usr/bin/env python3
"""Backtest de la logique FDK_Gold_Custom.

Reproduit fidelement les regles de l'indicateur :
  bias  = structure des swings (StructureLookback=20, SwingDepth=3)
  entry = session active ET biasM15 != 0 ET biasM15 == biasH4
  TP1/TP2 = entree +/- 1 et 2 x ATR(14) M15

L'indicateur ne definit AUCUN stop-loss : le backtest en impose un
(1 x ATR) pour pouvoir mesurer quoi que ce soit. Hypothese explicite.
"""
import json, sys, csv, datetime, collections

LOOKBACK, DEPTH, ATR_P = 20, 3, 14
BENIN_OFFSET = 3600          # WAT = UTC+1
SESSIONS = [("ASIE", 0, 4*3600), ("LONDRES", 8*3600, 11*3600),
            ("NY_AM", 13*3600+1800, 16*3600), ("NY_PM", 16*3600, 19*3600)]
TP1_M, TP2_M, STOP_M = 1.0, 2.0, 1.0
MAX_HOLD = 96                # 24 h en M15


# ---------------------------------------------------------------- data
def load_yahoo(path):
    d = json.load(open(path))["chart"]["result"][0]
    ts, q = d["timestamp"], d["indicators"]["quote"][0]
    out = []
    for i, t in enumerate(ts):
        o, h, l, c = q["open"][i], q["high"][i], q["low"][i], q["close"][i]
        if None in (o, h, l, c):
            continue
        out.append((int(t), o, h, l, c))
    return out


def load_mt5_csv(path, server_to_utc=0):
    out = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        for row in csv.DictReader(f):
            try:
                dt = datetime.datetime.strptime(row["time_server"].strip(),
                                                "%Y.%m.%d %H:%M:%S")
            except ValueError:
                continue
            ts = int(dt.replace(tzinfo=datetime.timezone.utc).timestamp()) + server_to_utc
            out.append((ts, float(row["open"]), float(row["high"]),
                        float(row["low"]), float(row["close"])))
    out.sort()
    return out


# ---------------------------------------------------------------- logic
def compute_bias(highs, lows, idx):
    """Port direct de ComputeBias(). highs/lows en ordre chronologique,
    idx = barre courante. Indexation serie : s[0] = idx, s[k] = idx-k."""
    need = LOOKBACK + DEPTH * 2 + 2          # 28
    if idx < need - 1:
        return 0
    h = [highs[idx - k] for k in range(need)]
    l = [lows[idx - k] for k in range(need)]
    sh, sl = [], []
    for i in range(DEPTH, LOOKBACK + DEPTH):
        isH = isL = True
        for k in range(1, DEPTH + 1):
            if h[i] <= h[i - k] or h[i] <= h[i + k]:
                isH = False
            if l[i] >= l[i - k] or l[i] >= l[i + k]:
                isL = False
        if isH:
            sh.append(i)
        if isL:
            sl.append(i)
    if len(sh) < 2 or len(sl) < 2:
        return 0
    h1, h2 = h[sh[0]], h[sh[1]]
    l1, l2 = l[sl[0]], l[sl[1]]
    if h1 > h2 and l1 > l2:
        return 1
    if h1 < h2 and l1 < l2:
        return -1
    return 0


def wilder_atr(bars, period=ATR_P):
    """ATR de Wilder, aligne sur l'indice des barres (None si indisponible)."""
    atr = [None] * len(bars)
    trs = []
    for i, (_, o, h, l, c) in enumerate(bars):
        if i == 0:
            trs.append(h - l)
            continue
        pc = bars[i - 1][4]
        trs.append(max(h - l, abs(h - pc), abs(l - pc)))
        if i == period:
            atr[i] = sum(trs[1:period + 1]) / period
        elif i > period:
            atr[i] = (atr[i - 1] * (period - 1) + trs[i]) / period
    return atr


def session_of(ts):
    sod = (ts + BENIN_OFFSET) % 86400
    for name, a, b in SESSIONS:
        if a <= sod < b:
            return name
    return None


def build_h4_progressive(m15):
    """Serie H4 reconstruite barre par barre, la derniere pouvant etre
    partielle - exactement ce que MT5 voit en temps reel (pas de look-ahead).
    Retourne, pour chaque indice M15, l'etat (highs, lows, idx) du H4."""
    h4_t, h4_h, h4_l = [], [], []
    mapping = []
    for ts, o, h, l, c in m15:
        bucket = ts - (ts % 14400)
        if not h4_t or h4_t[-1] != bucket:
            h4_t.append(bucket); h4_h.append(h); h4_l.append(l)
        else:
            h4_h[-1] = max(h4_h[-1], h); h4_l[-1] = min(h4_l[-1], l)
        mapping.append(len(h4_t) - 1)
    return h4_h, h4_l, mapping


# ---------------------------------------------------------------- backtest
def run(m15, label):
    atr = wilder_atr(m15)
    highs = [b[2] for b in m15]
    lows = [b[3] for b in m15]

    # Le H4 doit etre reconstruit progressivement pour rester honnete,
    # mais le bias H4 se calcule sur l'etat FIGE a chaque barre M15.
    h4_t, h4_h, h4_l = [], [], []
    trades, allowed_bars, total_bars = [], 0, 0
    prev_allowed_dir = 0
    open_trade = None

    for i, (ts, o, h, l, c) in enumerate(m15):
        bucket = ts - (ts % 14400)
        if not h4_t or h4_t[-1] != bucket:
            h4_t.append(bucket); h4_h.append(h); h4_l.append(l)
        else:
            h4_h[-1] = max(h4_h[-1], h); h4_l[-1] = min(h4_l[-1], l)

        # --- gestion d'une position ouverte
        if open_trade is not None:
            t = open_trade
            t["bars"] += 1
            hit_stop = (l <= t["stop"]) if t["dir"] > 0 else (h >= t["stop"])
            hit_tp1 = (h >= t["tp1"]) if t["dir"] > 0 else (l <= t["tp1"])
            hit_tp2 = (h >= t["tp2"]) if t["dir"] > 0 else (l <= t["tp2"])
            if hit_tp1:
                t["tp1_done"] = True
            if hit_stop:                      # prudent : stop prioritaire
                t["result"] = "TP1_puis_stop" if t["tp1_done"] else "stop"
                t["R"] = 1.0 if t["tp1_done"] else -1.0
                trades.append(t); open_trade = None
            elif hit_tp2:
                t["result"] = "TP2"; t["R"] = 2.0
                trades.append(t); open_trade = None
            elif t["bars"] >= MAX_HOLD:
                t["result"] = "timeout"
                t["R"] = ((c - t["entry"]) * t["dir"]) / t["risk"]
                trades.append(t); open_trade = None

        # --- evaluation du signal
        if atr[i] is None or atr[i] <= 0:
            continue
        total_bars += 1
        bM15 = compute_bias(highs, lows, i)
        bH4 = compute_bias(h4_h, h4_l, len(h4_t) - 1)
        sess = session_of(ts)
        aligned = (bM15 != 0 and bM15 == bH4)
        allowed = aligned and sess is not None
        if allowed:
            allowed_bars += 1

        new_signal = allowed and (prev_allowed_dir != bM15)
        prev_allowed_dir = bM15 if allowed else 0

        if new_signal and open_trade is None:
            risk = atr[i] * STOP_M
            open_trade = dict(
                ts=ts, dir=bM15, entry=c, risk=risk, session=sess, bars=0,
                tp1_done=False,
                tp1=c + bM15 * atr[i] * TP1_M,
                tp2=c + bM15 * atr[i] * TP2_M,
                stop=c - bM15 * risk)

    report(trades, allowed_bars, total_bars, m15, label)
    return trades


def report(trades, allowed_bars, total_bars, m15, label):
    d0 = datetime.datetime.utcfromtimestamp(m15[0][0])
    d1 = datetime.datetime.utcfromtimestamp(m15[-1][0])
    print("=" * 66)
    print(f"  {label}")
    print(f"  {len(m15)} bougies M15   du {d0:%Y-%m-%d} au {d1:%Y-%m-%d}")
    print("=" * 66)
    pct = 100.0 * allowed_bars / total_bars if total_bars else 0
    print(f"Barres ou l'entree est autorisee : {allowed_bars}/{total_bars} ({pct:.1f}%)")
    print(f"Signaux (transitions) declenches : {len(trades)}")
    if not trades:
        print("Aucun trade -> rien a mesurer.")
        return

    cnt = collections.Counter(t["result"] for t in trades)
    tot = len(trades)
    print("\nIssues :")
    for k in ("TP2", "TP1_puis_stop", "stop", "timeout"):
        if cnt[k]:
            print(f"  {k:<16} {cnt[k]:>4}  ({100.0*cnt[k]/tot:5.1f} %)")
    tp1_rate = sum(1 for t in trades if t["tp1_done"]) / tot
    totR = sum(t["R"] for t in trades)
    print(f"\nTP1 atteint (meme si stoppe apres) : {100*tp1_rate:.1f} %")
    print(f"Total          : {totR:+.2f} R")
    print(f"Esperance/trade: {totR/tot:+.3f} R")

    print("\nPar session :")
    for name, _, _ in SESSIONS:
        sub = [t for t in trades if t["session"] == name]
        if not sub:
            continue
        r = sum(t["R"] for t in sub)
        print(f"  {name:<8} n={len(sub):>3}  total={r:+7.2f} R  moy={r/len(sub):+.3f} R")

    print("\nPar sens :")
    for dname, dv in (("LONG", 1), ("SHORT", -1)):
        sub = [t for t in trades if t["dir"] == dv]
        if not sub:
            continue
        r = sum(t["R"] for t in sub)
        print(f"  {dname:<8} n={len(sub):>3}  total={r:+7.2f} R  moy={r/len(sub):+.3f} R")


if __name__ == "__main__":
    src = sys.argv[1]
    if src.endswith(".json"):
        bars = load_yahoo(src)
        lbl = sys.argv[2] if len(sys.argv) > 2 else src
    else:
        off = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        bars = load_mt5_csv(src, off)
        lbl = sys.argv[2] if len(sys.argv) > 2 else src
    run(bars, lbl)
