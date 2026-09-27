//+------------------------------------------------------------------+
//| FDK_Gold_EA.mq5                                                  |
//| Expert Advisor appliquant la MÊME règle que FDK_Gold_Custom, via |
//| la logique partagée de FDK_Common.mqh.                            |
//|                                                                   |
//| Destiné au Simulateur de stratégie : un indicateur ne passe pas   |
//| d'ordres, donc il ne produit aucun rapport. Cet EA existe pour    |
//| obtenir des statistiques sur l'historique, et pour confronter le  |
//| moteur de MT5 au backtest Python — si les deux divergent, l'un    |
//| des deux a un défaut, et il faut le savoir.                       |
//|                                                                   |
//| AVERTISSEMENT : la règle n'a AUCUN avantage statistique démontré. |
//| Huit hypothèses mesurées sur quinze mois, la meilleure est plate. |
//| Cet EA sert à mesurer, pas à trader.                              |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include <FDK_Common.mqh>

input group "=== Fuseau horaire ==="
input bool   AutoDetectTimezone       = true;
input int    ServerToBeninOffsetHours = 0;

input group "=== Sessions (heure Bénin, HHMM) ==="
input int    AsiaStart      = 0000;
input int    AsiaEnd        = 0400;
input int    LondonStart    = 0800;
input int    LondonEnd      = 1100;
input int    NewYorkAMStart = 1330;
input int    NewYorkAMEnd   = 1600;
input int    NewYorkPMStart = 1600;
input int    NewYorkPMEnd   = 1900;
input bool   TradeAsia      = false;   // L'Asie est la phase d'accumulation

input group "=== Structure / Biais ==="
input int    StructureLookback = 20;
input int    SwingDepth        = 3;

input group "=== Niveaux SL / TP ==="
input int    LevelsLookback = 150;
input int    LevelsDepth    = 3;
input double SL_BufferPips  = 0;

input group "=== Filtre gain/risque ==="
input double MinRR = 1.5;              // 0 = filtre désactivé

input group "=== Exécution ==="
input double Lots        = 0.10;
input long   MagicNumber = 20260927;

CTrade   gTrade;
datetime gLastBar    = 0;
int      gPrevDir    = 0;

//+------------------------------------------------------------------+
void BuildSessions(FDK_Session &s[])
  {
   ArrayResize(s, 4);
   s[0].name = "ASIE";    s[0].from = FDK_HHMMToSec(AsiaStart);      s[0].to = FDK_HHMMToSec(AsiaEnd);
   s[1].name = "LONDRES"; s[1].from = FDK_HHMMToSec(LondonStart);    s[1].to = FDK_HHMMToSec(LondonEnd);
   s[2].name = "NY_AM";   s[2].from = FDK_HHMMToSec(NewYorkAMStart); s[2].to = FDK_HHMMToSec(NewYorkAMEnd);
   s[3].name = "NY_PM";   s[3].from = FDK_HHMMToSec(NewYorkPMStart); s[3].to = FDK_HHMMToSec(NewYorkPMEnd);
  }

//+------------------------------------------------------------------+
bool HasPosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   gTrade.SetExpertMagicNumber(MagicNumber);
   gTrade.SetTypeFillingBySymbol(_Symbol);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // La règle se décide à la bougie, pas au tick : évaluer plus souvent
   // ferait diverger l'EA de l'indicateur et du backtest.
   datetime cur = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur == gLastBar)
      return;
   gLastBar = cur;

   int off      = FDK_BeninOffset(AutoDetectTimezone, ServerToBeninOffsetHours);
   datetime now = TimeCurrent() + off * 3600;

   FDK_Session sess[];
   BuildSessions(sess);
   string active = FDK_ActiveSession(FDK_SecOfDay(now), sess);

   int biasM15 = FDK_Bias(_Symbol, PERIOD_M15, StructureLookback, SwingDepth);
   int biasH4  = FDK_Bias(_Symbol, PERIOD_H4,  StructureLookback, SwingDepth);

   bool aligned     = (biasM15 != 0 && biasM15 == biasH4);
   bool asiaBlocked = (!TradeAsia && active == "ASIE");
   bool allowed     = aligned && active != "" && !asiaBlocked;

   int dir = biasM15;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp1 = 0.0, tp2 = 0.0;
   double buffer = SL_BufferPips * FDK_PipSize(_Digits, _Point);
   FDK_StructureLevels(_Symbol, PERIOD_CURRENT, dir, price,
                       LevelsLookback, LevelsDepth, buffer, sl, tp1, tp2);

   double rr = FDK_RiskReward(price, sl, tp1);
   if(allowed && MinRR > 0.0 && rr > 0.0 && rr < MinRR)
      allowed = false;                      // rapport insuffisant

   bool isNew = allowed && (gPrevDir != dir);
   gPrevDir   = allowed ? dir : 0;

   if(!isNew || HasPosition() || sl <= 0.0 || tp1 <= 0.0)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(dir > 0)
      gTrade.Buy(Lots, _Symbol, ask, sl, tp1, "FDK long");
   else
      gTrade.Sell(Lots, _Symbol, price, sl, tp1, "FDK short");
  }
