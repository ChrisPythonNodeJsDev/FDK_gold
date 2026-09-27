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
