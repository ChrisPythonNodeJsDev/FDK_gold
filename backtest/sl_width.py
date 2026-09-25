#!/usr/bin/env python3
"""Le stop structurel est-il anormalement large ?

Affirmation a verifier : "le dernier plus haut" retenu comme stop peut se
trouver tres loin du prix, produisant un R:R inexploitable. Si c'est
systematique, le filtre R:R rejetterait presque tout et le probleme serait
le calcul du stop, pas le marche.

On reproduit StructureLevels() du MQL5 sur les 15 mois et on mesure la
largeur du stop en multiples d'ATR, ainsi que le R:R resultant.
"""
import sys, statistics
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv, wilder_atr

LOOKBACK, DEPTH = 150, 3


def collect_swings(m15, i):
    """Swings sur les LOOKBACK barres precedant i, du plus recent au plus ancien."""
    hi, lo = [], []
    start = max(DEPTH, i - LOOKBACK)
    for j in range(i - DEPTH, start - 1, -1):
        if j - DEPTH < 0 or j + DEPTH >= len(m15): continue
        h, l = m15[j][2], m15[j][3]
        isH = isL = True
        for k in range(1, DEPTH+1):
            if h <= m15[j-k][2] or h <= m15[j+k][2]: isH = False
            if l >= m15[j-k][3] or l >= m15[j+k][3]: isL = False
        if isH: hi.append(h)
        if isL: lo.append(l)
    return hi, lo


if __name__ == "__main__":
    m15 = load_mt5_csv(sys.argv[1], 0)
    atr = wilder_atr(m15)
    widths, rrs = [], []

    # un echantillon par heure suffit pour une distribution
    for i in range(LOOKBACK + 10, len(m15), 4):
        if atr[i] is None or atr[i] <= 0: continue
        price = m15[i][4]
        hi, lo = collect_swings(m15, i)
        sl = next((p for p in hi if p > price), None)
        t1 = next((p for p in lo if p < price), None)
        if sl is None or t1 is None: continue
        risk = sl - price
        if risk <= 0: continue
        widths.append(risk / atr[i])
        rrs.append((price - t1) / risk)

    widths.sort(); rrs.sort()
    n = len(widths)
    q = lambda a, f: a[int(len(a)*f)]
    print(f"Stop structurel mesure sur {n} configurations (15 mois)\n")
    print("Largeur du stop, en multiples d'ATR")
    print(f"  mediane        {q(widths,.5):5.2f} x ATR")
    print(f"  1er quartile   {q(widths,.25):5.2f}")
    print(f"  3e quartile    {q(widths,.75):5.2f}")
    print(f"  9e decile      {q(widths,.9):5.2f}")
    for t in (2, 3, 4, 5):
        print(f"  au-dela de {t} x ATR : {100*sum(1 for w in widths if w > t)/n:4.1f} %")

    print("\nRapport gain/risque sur TP1")
    print(f"  mediane        {q(rrs,.5):5.2f}")
    for t in (1.0, 1.5, 2.0):
        print(f"  signaux survivant a un filtre R:R >= {t} : {100*sum(1 for r in rrs if r >= t)/n:4.1f} %")
