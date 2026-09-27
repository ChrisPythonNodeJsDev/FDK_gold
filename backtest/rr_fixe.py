import sys
sys.path.insert(0,"/home/oswalddev/FDK_gold/backtest")
from backtest import load_mt5_csv, wilder_atr
from sl_width import collect_swings, LOOKBACK, DEPTH

m15 = load_mt5_csv("/home/oswalddev/FDK_gold/donnees/FDK_XAUUSD_M15.csv", 0)
atr = wilder_atr(m15)
RISK = 20.0          # 200 pips = 20 points
rrs, atrs = [], []
for i in range(LOOKBACK+10, len(m15), 8):
    if atr[i] is None or atr[i] <= 0: continue
    price = m15[i][4]
    hi, lo = collect_swings(m15, i)
    t1 = next((p for p in lo if p < price), None)
    if t1 is None: continue
    rrs.append((price - t1) / RISK)
    atrs.append(RISK / atr[i])
rrs.sort(); atrs.sort()
n = len(rrs); q = lambda a,f: a[int(len(a)*f)]
print(f"Stop fixe de 200 pips (20 points) — {n} configurations\n")
print(f"Le stop vaut {q(atrs,.5):.1f} x ATR en median "
      f"(de {q(atrs,.1):.1f} a {q(atrs,.9):.1f})")
print(f"\nRapport gain/risque sur TP1 structurel")
print(f"  median          {q(rrs,.5):.2f}")
print(f"  9e decile       {q(rrs,.9):.2f}")
for t in (0.5, 1.0, 1.5):
    print(f"  setups a R:R >= {t} : {100*sum(1 for r in rrs if r>=t)/n:.1f} %")
