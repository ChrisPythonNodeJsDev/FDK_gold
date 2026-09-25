#!/usr/bin/env python3
"""Pourquoi telle zone n'a-t-elle pas ete detectee aujourd'hui ?

Pour chaque bougie de la journee on mesure son corps en multiples d'ATR et
on verifie si une base valide la precede. On voit alors exactement quelles
bougies ont frole le seuil d'impulsion, et de combien.
"""
import sys, datetime
sys.path.insert(0, "/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv, wilder_atr

IMPULSE, BASE, MAXBASE = 1.5, 0.5, 3
BENIN = 3600


def benin(ts):
    return datetime.datetime.fromtimestamp(ts + BENIN, datetime.timezone.utc)


if __name__ == "__main__":
    m15 = load_mt5_csv(sys.argv[1], 0)
    atr = wilder_atr(m15)
    # Le jeu couvre plus d'un an : sans l'annee, on attrape aussi le meme
    # quantieme de l'an dernier, a des prix sans rapport.
    last = benin(m15[-1][0])
    day, month, year = last.day, last.month, last.year
    if len(sys.argv) > 2:
        day = int(sys.argv[2])

    rows = []
    for i, (ts, o, h, l, c) in enumerate(m15):
        d = benin(ts)
        if d.day != day or d.month != month or d.year != year:
            continue
        if atr[i] is None or atr[i] <= 0:
            continue
        body = abs(c - o)
        ratio = body / atr[i]

        base = 0
        for j in range(i-1, max(i-1-MAXBASE, -1), -1):
            if atr[j] is None or atr[j] <= 0: break
            if abs(m15[j][4] - m15[j][1]) > BASE * atr[j]: break
            base += 1
        rows.append((d, ratio, base, o, c, h, l, atr[i], i))

    rows.sort(key=lambda r: -r[1])
    print(f"Journee du {day:02d}/{month:02d}/{year} — {len(rows)} bougies M15\n")
    print(f"Seuil d'impulsion actuel : corps > {IMPULSE} x ATR")
    print(f"{'heure Benin':<14}{'corps/ATR':>10}{'base':>6}{'zone ?':>9}"
          f"{'sens':>7}{'niveau':>20}")
    for d, ratio, base, o, c, h, l, a, i in rows[:14]:
        ok = "OUI" if (ratio >= IMPULSE and base > 0) else "non"
        sens = "hausse" if c > o else "baisse"
        seg = m15[i-base:i] if base else []
        niv = (f"{min(x[3] for x in seg):.2f}-{max(x[2] for x in seg):.2f}"
               if seg else "-")
        print(f"{d:%H:%M}{'':<9}{ratio:>10.2f}{base:>6}{ok:>9}{sens:>7}{niv:>20}")

    print("\nZones creees selon le seuil d'impulsion :")
    for thr in (1.5, 1.2, 1.0, 0.8):
        n = sum(1 for r in rows if r[1] >= thr and r[2] > 0)
        print(f"  seuil {thr:.1f} x ATR -> {n:2d} zone(s)")
