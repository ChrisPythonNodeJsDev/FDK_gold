#!/usr/bin/env python3
"""Test de l'hypothese : filtrer les entrees par les zones offre/demande.

Portage fidele de DetectZones() du MQL5. Une zone nait d'une "base"
(1..N bougies a petit corps) suivie d'une bougie d'impulsion ; elle reste
fraiche tant que le prix n'y est pas revenu.

Discipline : 4 variantes definies A L'AVANCE, mesurees sur les 10 premiers
mois (in-sample). Seule la meilleure est ensuite confrontee aux 5 derniers
mois, jamais regardes avant. Tester 4 variantes gonfle le risque de tomber
sur un faux positif : c'est pour ca que l'out-of-sample tranche seul.
"""
import sys, datetime, collections
sys.path.insert(0, "/home/oswalddev/FDK_backtest")
from backtest import load_mt5_csv, compute_bias, wilder_atr, session_of, SESSIONS
from bt2 import simulate, score

IMPULSE_ATR, BASE_ATR, MAX_BASE = 1.5, 0.5, 3


class Zones:
    """Cree les zones depuis une serie, suit leur fraicheur sur le prix M15."""

    def __init__(self):
        self.active = []          # dicts: hi, lo, supply(bool), born
        self.hist = []            # (o,h,l,c,atr) de la serie de creation

    def feed(self, o, h, l, c, atr, tag):
        """Ajoute une bougie de la serie de creation et detecte une zone."""
        self.hist.append((o, h, l, c, atr))
        i = len(self.hist) - 1
        if atr is None or atr <= 0 or i < MAX_BASE + 1:
            return
        body = abs(c - o)
        if body < IMPULSE_ATR * atr:
            return                                     # pas une impulsion
        bullish = c > o
        base = 0
        for j in range(i - 1, max(i - 1 - MAX_BASE, -1), -1):
            bo, bh, bl, bc, ba = self.hist[j]
            if ba is None or ba <= 0:
                break
            if abs(bc - bo) > BASE_ATR * ba:
                break
            base += 1
        if base == 0:
            return
        seg = self.hist[i - base:i]
        zhi = max(x[1] for x in seg)
        zlo = min(x[2] for x in seg)
        if zhi <= zlo:
            return
        self.active.append(dict(hi=zhi, lo=zlo, supply=not bullish, tag=tag))

    def touched(self, h, l):
        """Zones fraiches touchees par cette bougie M15 ; elles sont retirees."""
        hit, keep = [], []
        for z in self.active:
            if (l <= z["hi"]) if not z["supply"] else (h >= z["lo"]):
                hit.append(z)
            else:
                keep.append(z)
        self.active = keep
        return hit


def analyse(m15, label, variants):
    atr = wilder_atr(m15)
    highs = [b[2] for b in m15]
    lows = [b[3] for b in m15]

    # H4 progressif : bougie completee -> creation de zones H4
    h4_t, h4_h, h4_l, h4_o, h4_c = [], [], [], [], []
    zm, zh = Zones(), Zones()
    h4_atr_trs, h4_prev_atr = [], None

    state = {k: dict(prev=0, busy=-1, trades=[]) for k in variants}
    allowed_bars = 0

    for i, (ts, o, h, l, c) in enumerate(m15):
        bucket = ts - (ts % 14400)
        new_bucket = (not h4_t or h4_t[-1] != bucket)
        if new_bucket and h4_t:
            # la bougie H4 precedente vient de se cloturer -> zones H4
            k = len(h4_t) - 1
            tr = h4_h[k] - h4_l[k] if k == 0 else max(
                h4_h[k] - h4_l[k], abs(h4_h[k] - h4_c[k-1]), abs(h4_l[k] - h4_c[k-1]))
            h4_atr_trs.append(tr)
            a4 = None
            if len(h4_atr_trs) >= 14:
                if h4_prev_atr is None:
                    a4 = sum(h4_atr_trs[-14:]) / 14
                else:
                    a4 = (h4_prev_atr * 13 + tr) / 14
                h4_prev_atr = a4
            zh.feed(h4_o[k], h4_h[k], h4_l[k], h4_c[k], a4, "H4")

        if new_bucket:
            h4_t.append(bucket); h4_h.append(h); h4_l.append(l)
            h4_o.append(o); h4_c.append(c)
        else:
            h4_h[-1] = max(h4_h[-1], h); h4_l[-1] = min(h4_l[-1], l); h4_c[-1] = c

        # zones touchees par CETTE bougie (avant d'en creer de nouvelles)
        hits = zm.touched(h, l) + zh.touched(h, l)
        zm.feed(o, h, l, c, atr[i], "M15")

        if atr[i] is None or atr[i] <= 0:
            continue
        bM15 = compute_bias(highs, lows, i)
        bH4 = compute_bias(h4_h, h4_l, len(h4_t) - 1)
        sess = session_of(ts)
        aligned = (bM15 != 0 and bM15 == bH4)
        if aligned and sess:
            allowed_bars += 1

        demand_hit = any(not z["supply"] for z in hits)
        supply_hit = any(z["supply"] for z in hits)

        for name, fn in variants.items():
            d = fn(bM15, bH4, aligned, sess, demand_hit, supply_hit)
            st = state[name]
            new = d != 0 and st["prev"] != d
            st["prev"] = d
            if not new or i <= st["busy"]:
                continue
            r = atr[i]
            ev = simulate(m15, i, d, c, r, c + d * r, c + d * 2 * r)
            A, B, C = score(ev, d, c, r)
            st["busy"] = i + ev["bars"]
            st["trades"].append(dict(dir=d, session=sess, A=A, B=B, C=C,
                                     hit_tp1=ev["tp1"] is not None,
                                     stop_first=(ev["stop"] is not None and
                                                 (ev["tp1"] is None or ev["stop"] <= ev["tp1"]))))
    return state, allowed_bars


# ----------------------------------------------------- variantes (a priori)
def V1(bm, bh, aligned, sess, dh, sh):      # regle actuelle + zone alignee
    if not aligned or not sess: return 0
    if bm > 0 and dh: return 1
    if bm < 0 and sh: return -1
    return 0

def V2(bm, bh, aligned, sess, dh, sh):      # sans filtre de session
    if not aligned: return 0
    if bm > 0 and dh: return 1
    if bm < 0 and sh: return -1
    return 0

def V3(bm, bh, aligned, sess, dh, sh):      # zone seule, sens = cote de la zone
    if dh and not sh: return 1
    if sh and not dh: return -1
    return 0

def V4(bm, bh, aligned, sess, dh, sh):      # reference : regle actuelle
    return bm if (aligned and sess) else 0

VARIANTS = {"V1 biais+session+zone": V1, "V2 biais+zone": V2,
            "V3 zone seule": V3, "V4 reference actuelle": V4}


def show(state, label, n_bars):
    print(f"\n--- {label} ({n_bars} bougies) ---")
    print(f"  {'variante':<24} {'n':>5} {'TP1>stop':>9} {'espA':>8} {'espB':>8} {'espC':>8}")
    for name in VARIANTS:
        t = state[name]["trades"]
        if not t:
            print(f"  {name:<24} {0:>5}"); continue
        n = len(t)
        w = sum(1 for x in t if x["hit_tp1"] and not x["stop_first"])
        eA = sum(x["A"] for x in t) / n
        eB = sum(x["B"] for x in t) / n
        eC = sum(x["C"] for x in t) / n
        print(f"  {name:<24} {n:>5} {100.0*w/n:>8.1f}% {eA:>+8.3f} {eB:>+8.3f} {eC:>+8.3f}")


if __name__ == "__main__":
    csv = sys.argv[1]
    bars = load_mt5_csv(csv, 0)
    split = datetime.datetime(2026, 5, 1, tzinfo=datetime.timezone.utc).timestamp()
    ins = [b for b in bars if b[0] < split]
    oos = [b for b in bars if b[0] >= split]
    d = lambda x: datetime.datetime.fromtimestamp(x, datetime.timezone.utc).strftime("%Y-%m-%d")
    print("=" * 74)
    print(f"IN-SAMPLE  {d(ins[0][0])} -> {d(ins[-1][0])}   ({len(ins)} bougies)")
    print(f"OUT-SAMPLE {d(oos[0][0])} -> {d(oos[-1][0])}   ({len(oos)} bougies)")
    print("=" * 74)
    s1, a1 = analyse(ins, "in", VARIANTS)
    show(s1, "IN-SAMPLE (calibration)", len(ins))
    s2, a2 = analyse(oos, "oos", VARIANTS)
    show(s2, "OUT-OF-SAMPLE (validation)", len(oos))
