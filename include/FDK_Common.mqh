//+------------------------------------------------------------------+
//| FDK_Common.mqh                                                   |
//| Logique partagée par l'indicateur et l'Expert Advisor.           |
//|                                                                   |
//| Raison d'être : un EA qui réimplémenterait la règle produirait    |
//| des résultats ne correspondant pas à ce que l'indicateur affiche. |
//| On aurait deux vérités et aucun moyen de savoir laquelle vaut.    |
//| Toute logique servant à DÉCIDER vit ici, et nulle part ailleurs.  |
//|                                                                   |
//| Les fonctions prennent leurs réglages en paramètres plutôt que de |
//| lire des `input` : un .mqh qui dépend des entrées du programme    |
//| hôte casse dès qu'on l'inclut ailleurs.                           |
//+------------------------------------------------------------------+
#property copyright "Custom"

//--- Une fenêtre de session, en secondes depuis minuit (heure Bénin)
struct FDK_Session
  {
   string name;
   int    from;
   int    to;
  };

//+------------------------------------------------------------------+
//| Un pip. L'or cote à 2 décimales, où un pip vaut 0.10, pas 0.01.  |
//+------------------------------------------------------------------+
double FDK_PipSize(const int digits, const double point)
  {
   if(digits == 2 || digits == 3 || digits == 5)
      return(point * 10);
   return(point);
  }

//+------------------------------------------------------------------+
//| Heures à ajouter à l'heure serveur pour obtenir l'heure Bénin.   |
//| Le Bénin (WAT) est à UTC+1 toute l'année, sans heure d'été.      |
//+------------------------------------------------------------------+
int FDK_BeninOffset(const bool autoDetect, const int manual)
  {
   if(!autoDetect)
      return(manual);
   datetime gmt = TimeGMT();
   if(gmt <= 0)
      return(manual);
   double diff = ((double)(gmt + 3600) - (double)TimeCurrent()) / 3600.0;
   return((int)MathRound(diff));
  }

//+------------------------------------------------------------------+
int FDK_HHMMToSec(const int hhmm)
  {
   return((hhmm / 100) * 3600 + (hhmm % 100) * 60);
  }

//+------------------------------------------------------------------+
int FDK_SecOfDay(const datetime t)
  {
   MqlDateTime d;
   TimeToStruct(t, d);
   return(d.hour * 3600 + d.min * 60 + d.sec);
  }

//+------------------------------------------------------------------+
//| Nom de la session active, "" si aucune.                          |
//+------------------------------------------------------------------+
string FDK_ActiveSession(const int secOfDay, const FDK_Session &sessions[])
  {
   for(int i = 0; i < ArraySize(sessions); i++)
      if(secOfDay >= sessions[i].from && secOfDay < sessions[i].to)
         return(sessions[i].name);
   return("");
  }

//+------------------------------------------------------------------+
//| Biais de structure : deux derniers swings hauts et bas comparés.  |
//| startShift > 0 évalue le biais tel qu'il était à cette barre.     |
//+------------------------------------------------------------------+
int FDK_Bias(const string sym, const ENUM_TIMEFRAMES tf,
             const int lookback, const int depth, int startShift = 0)
  {
   int bars = lookback + depth * 2 + 2;
   if(startShift < 0)
      startShift = 0;

   double highs[], lows[];
   if(CopyHigh(sym, tf, startShift, bars, highs) < bars) return(0);
   if(CopyLow (sym, tf, startShift, bars, lows)  < bars) return(0);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   int sh[], sl[];
   for(int i = depth; i < lookback + depth; i++)
     {
      bool isH = true, isL = true;
      for(int k = 1; k <= depth; k++)
        {
         if(highs[i] <= highs[i-k] || highs[i] <= highs[i+k]) isH = false;
         if(lows[i]  >= lows[i-k]  || lows[i]  >= lows[i+k])  isL = false;
        }
      if(isH) { int n = ArraySize(sh); ArrayResize(sh, n+1); sh[n] = i; }
      if(isL) { int n = ArraySize(sl); ArrayResize(sl, n+1); sl[n] = i; }
     }
   if(ArraySize(sh) < 2 || ArraySize(sl) < 2)
      return(0);

   double h1 = highs[sh[0]], h2 = highs[sh[1]];
   double l1 = lows[sl[0]],  l2 = lows[sl[1]];
   if(h1 > h2 && l1 > l2) return(1);
   if(h1 < h2 && l1 < l2) return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Plus haut et plus bas entre deux instants.                        |
//+------------------------------------------------------------------+
bool FDK_RangeHiLo(const string sym, const ENUM_TIMEFRAMES tf,
                   const datetime from, const datetime to,
                   double &hi, double &lo)
  {
   int b1 = iBarShift(sym, tf, from, false);
   int b2 = iBarShift(sym, tf, to,   false);
   if(b1 < 0 || b2 < 0)
      return(false);
   int start = MathMin(b1, b2);
   int count = MathAbs(b1 - b2) + 1;
   if(count < 1)
      return(false);
   int hiIdx = iHighest(sym, tf, MODE_HIGH, count, start);
   int loIdx = iLowest (sym, tf, MODE_LOW,  count, start);
   if(hiIdx < 0 || loIdx < 0)
      return(false);
   hi = iHigh(sym, tf, hiIdx);
   lo = iLow (sym, tf, loIdx);
   return(true);
  }

//+------------------------------------------------------------------+
//| Swings de la période, du plus récent au plus ancien.              |
//+------------------------------------------------------------------+
void FDK_CollectSwings(const string sym, const ENUM_TIMEFRAMES tf,
                       const int lookback, const int depth,
                       double &swHigh[], double &swLow[])
  {
   ArrayResize(swHigh, 0);
   ArrayResize(swLow,  0);

   int need = lookback + depth * 2 + 2;
   double h[], l[];
   if(CopyHigh(sym, tf, 0, need, h) < need) return;
   if(CopyLow (sym, tf, 0, need, l) < need) return;
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);

   for(int i = depth; i < lookback + depth; i++)
     {
      bool isH = true, isL = true;
      for(int k = 1; k <= depth; k++)
        {
         if(h[i] <= h[i-k] || h[i] <= h[i+k]) isH = false;
         if(l[i] >= l[i-k] || l[i] >= l[i+k]) isL = false;
        }
      if(isH) { int n = ArraySize(swHigh); ArrayResize(swHigh, n+1); swHigh[n] = h[i]; }
      if(isL) { int n = ArraySize(swLow);  ArrayResize(swLow,  n+1); swLow[n]  = l[i]; }
     }
  }

//+------------------------------------------------------------------+
//| VENTE : stop au-dessus du dernier plus haut, cibles sur les deux  |
//| plus bas précédents. ACHAT : l'inverse. false si la structure ne  |
//| fournit pas de niveau exploitable — mieux vaut rien qu'inventé.   |
//+------------------------------------------------------------------+
bool FDK_StructureLevels(const string sym, const ENUM_TIMEFRAMES tf,
                         const int dir, const double price,
                         const int lookback, const int depth,
                         const double buffer,
                         double &sl, double &tp1, double &tp2)
  {
   sl = 0.0; tp1 = 0.0; tp2 = 0.0;

   double swH[], swL[];
   FDK_CollectSwings(sym, tf, lookback, depth, swH, swL);

   if(dir < 0)
     {
      for(int i = 0; i < ArraySize(swH); i++)
         if(swH[i] > price) { sl = swH[i] + buffer; break; }
      for(int i = 0; i < ArraySize(swL); i++)
         if(swL[i] < price) { tp1 = swL[i]; break; }
      if(tp1 > 0.0)
         for(int i = 0; i < ArraySize(swL); i++)
            if(swL[i] < tp1) { tp2 = swL[i]; break; }
     }
   else
     {
      for(int i = 0; i < ArraySize(swL); i++)
         if(swL[i] < price) { sl = swL[i] - buffer; break; }
      for(int i = 0; i < ArraySize(swH); i++)
         if(swH[i] > price) { tp1 = swH[i]; break; }
      if(tp1 > 0.0)
         for(int i = 0; i < ArraySize(swH); i++)
            if(swH[i] > tp1) { tp2 = swH[i]; break; }
     }
   return(sl > 0.0 && tp1 > 0.0);
  }

//+------------------------------------------------------------------+
//| Rapport gain/risque sur TP1, 0 si indéterminable.                 |
//+------------------------------------------------------------------+
double FDK_RiskReward(const double price, const double sl, const double tp1)
  {
   if(sl <= 0.0 || tp1 <= 0.0)
      return(0.0);
   double risk = MathAbs(price - sl);
   if(risk <= 0.0)
      return(0.0);
   return(MathAbs(tp1 - price) / risk);
  }

//+------------------------------------------------------------------+
//| SÉQUENCE AMD ET DÉCISION D'ENTRÉE                                 |
//| Déplacé ici depuis l'indicateur : la logique qui DÉCIDE ne peut   |
//| pas vivre dans un seul des deux programmes, sinon le backtest ne  |
//| mesure pas ce que l'écran affiche.                                 |
//+------------------------------------------------------------------+

enum FDK_EntryMode { FDK_ENTRY_BIAIS, FDK_ENTRY_AMD, FDK_ENTRY_LES_DEUX };

struct FDK_Amd
  {
   int    side;        // côté balayé : +1 haut, -1 bas, 0 aucun
   double ext;         // extrême de l'excursion
   double level;       // niveau dont la cassure confirme le retournement
   bool   confirmed;
   int    dir;         // sens de la distribution attendue
  };

struct FDK_Decision
  {
   bool allowed;
   bool biasSignal;
   bool amdSignal;
   bool aligned;
   bool h4Neutral;
   int  dir;
  };

//+------------------------------------------------------------------+
bool FDK_InWindow(const int secOfDay, const FDK_Session &windows[])
  {
   for(int i = 0; i < ArraySize(windows); i++)
      if(secOfDay >= windows[i].from && secOfDay < windows[i].to)
         return(true);
   return(false);
  }

//+------------------------------------------------------------------+
//| L'Asie accumule, Londres ou New York balaye la liquidité, puis la |
//| distribution se confirme par une cassure de structure. Sans cette |
//| confirmation on parie sur un retournement au lieu d'attendre qu'il|
//| se manifeste : mesuré, l'écart est de -0.216 à -0.002 R.          |
//+------------------------------------------------------------------+
void FDK_ComputeAmd(const string sym, const ENUM_TIMEFRAMES tf,
                    const datetime from, const datetime to,
                    const double asiaHi, const double asiaLo,
                    const int beninOffset, const FDK_Session &windows[],
                    FDK_Amd &out)
  {
   out.side = 0; out.ext = 0.0; out.level = 0.0;
   out.confirmed = false; out.dir = 0;
   if(asiaHi <= asiaLo)
      return;

   int b1 = iBarShift(sym, tf, from, false);
   int b2 = iBarShift(sym, tf, to,   false);
   if(b1 < 0 || b2 < 0)
      return;
   int start = MathMax(b1, b2), end = MathMin(b1, b2);
   int count = start - end + 1;
   if(count < 3)
      return;

   double h[], l[], c[];
   datetime t[];
   if(CopyHigh (sym, tf, end, count, h) < count) return;
   if(CopyLow  (sym, tf, end, count, l) < count) return;
   if(CopyClose(sym, tf, end, count, c) < count) return;
   if(CopyTime (sym, tf, end, count, t) < count) return;

   bool outUp = false, outDn = false;
   int  sweptAt = -1;
   for(int i = 0; i < count; i++)
     {
      if(!FDK_InWindow(FDK_SecOfDay(t[i] + beninOffset * 3600), windows))
         continue;
      if(h[i] > asiaHi) outUp = true;
      if(l[i] < asiaLo) outDn = true;
      if(outUp && c[i] < asiaHi) { out.side = +1; sweptAt = i; break; }
      if(outDn && c[i] > asiaLo) { out.side = -1; sweptAt = i; break; }
     }
   if(out.side == 0)
      return;

   out.dir = -out.side;                 // la distribution part à l'opposé

   int extIdx = 0;
   out.ext = (out.dir > 0) ? l[0] : h[0];
   for(int i = 0; i <= sweptAt; i++)
     {
      if(out.dir > 0 && l[i] <= out.ext) { out.ext = l[i]; extIdx = i; }
      if(out.dir < 0 && h[i] >= out.ext) { out.ext = h[i]; extIdx = i; }
     }

   out.level = (out.dir > 0) ? h[0] : l[0];
   for(int i = 0; i <= extIdx; i++)
     {
      if(out.dir > 0) out.level = MathMax(out.level, h[i]);
      else            out.level = MathMin(out.level, l[i]);
     }

   for(int i = extIdx + 1; i < count; i++)
      if((out.dir > 0 && c[i] > out.level) || (out.dir < 0 && c[i] < out.level))
        {
         out.confirmed = true;
         break;
        }
  }

//+------------------------------------------------------------------+
//| Un H4 neutre ne contredit pas le M15. L'interdire coupait les     |
//| signaux sans discriminer : 146 ramenés à 34, sans gain d'espérance|
//+------------------------------------------------------------------+
void FDK_Decide(const FDK_EntryMode mode, const bool allowNeutralH4,
                const int biasM15, const int biasH4,
                const FDK_Amd &amd,
                const bool sessionActive, const bool asiaBlocked,
                FDK_Decision &d)
  {
   d.h4Neutral  = (biasH4 == 0);
   d.aligned    = (biasM15 != 0
                   && (biasM15 == biasH4 || (allowNeutralH4 && d.h4Neutral)));
   d.biasSignal = d.aligned && sessionActive && !asiaBlocked;
   d.amdSignal  = amd.confirmed && sessionActive && !asiaBlocked;

   if(mode == FDK_ENTRY_BIAIS)       d.allowed = d.biasSignal;
   else if(mode == FDK_ENTRY_AMD)    d.allowed = d.amdSignal;
   else                              d.allowed = (d.biasSignal || d.amdSignal);

   d.dir = d.amdSignal ? amd.dir : ((biasM15 != 0) ? biasM15 : biasH4);
  }

//+------------------------------------------------------------------+
//| Un rapport gain/risque élevé n'est pas toujours une bonne         |
//| nouvelle : il vient souvent d'un stop trop serré, collé au swing, |
//| que le marché balaie en quelques minutes. Mesuré en simulation,   |
//| un stop à 0.25 x ATR produisait un R:R de 10 et sautait aussitôt. |
//| Les deux conditions doivent donc être vérifiées ensemble.         |
//+------------------------------------------------------------------+
bool FDK_LevelsAcceptable(const double price, const double sl, const double atr,
                          const double minSlAtr, const double rr,
                          const double minRR, string &motif)
  {
   motif = "";
   double risk = MathAbs(price - sl);
   if(sl <= 0.0 || risk <= 0.0)
     {
      motif = "SL_ABSENT";
      return(false);
     }
   if(minSlAtr > 0.0 && atr > 0.0 && risk < minSlAtr * atr)
     {
      motif = StringFormat("SL_TROP_SERRE_%.2fxATR", risk / atr);
      return(false);
     }
   if(minRR > 0.0 && rr > 0.0 && rr < minRR)
     {
      motif = StringFormat("RR_INSUFFISANT_%.2f", rr);
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| Deux façons de placer le stop.                                    |
//| STRUCTURE : au-delà du dernier swing opposé. Fidèle au marché,    |
//|   mais la distance varie énormément — mesurée entre 0.2 et 5 x    |
//|   ATR — et un swing tout proche produit un stop que le bruit      |
//|   balaie en quelques minutes.                                     |
//| FIXE : un écart constant en pips. Moins fidèle à la structure,    |
//|   mais la perte maximale est connue d'avance et identique à       |
//|   chaque trade, ce qui rend le dimensionnement possible.          |
//+------------------------------------------------------------------+
enum FDK_SLMode { FDK_SL_STRUCTURE, FDK_SL_FIXE };

double FDK_StopLoss(const FDK_SLMode mode, const int dir, const double price,
                    const double structSL, const double fixedPips,
                    const double pipSize)
  {
   if(mode == FDK_SL_FIXE)
     {
      if(fixedPips <= 0.0 || pipSize <= 0.0)
         return(0.0);
      double d = fixedPips * pipSize;
      return((dir > 0) ? price - d : price + d);
     }
   return(structSL);
  }

//+------------------------------------------------------------------+
//| Cibles : structurelles ou à distance fixe.                        |
//| Un stop fixe associé à des cibles structurelles produit des       |
//| rapports ingérables — mesuré jusqu'à 0.09, soit 92 % de réussite  |
//| nécessaires — parce que le risque ne bouge pas tandis que la      |
//| cible dépend du swing le plus proche, parfois à deux points.      |
//| En mode FIXE le rapport devient constant et connu d'avance.       |
//+------------------------------------------------------------------+
enum FDK_TPMode { FDK_TP_STRUCTURE, FDK_TP_FIXE };

void FDK_Targets(const FDK_TPMode mode, const int dir, const double price,
                 const double structTP1, const double structTP2,
                 const double fixed1Pips, const double fixed2Pips,
                 const double pipSize, double &tp1, double &tp2)
  {
   if(mode != FDK_TP_FIXE || pipSize <= 0.0)
     {
      tp1 = structTP1;
      tp2 = structTP2;
      return;
     }
   tp1 = (fixed1Pips > 0.0)
         ? ((dir > 0) ? price + fixed1Pips * pipSize : price - fixed1Pips * pipSize)
         : 0.0;
   tp2 = (fixed2Pips > 0.0)
         ? ((dir > 0) ? price + fixed2Pips * pipSize : price - fixed2Pips * pipSize)
         : 0.0;
  }
