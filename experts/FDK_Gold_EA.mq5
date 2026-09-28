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
input int    FenetreStart   = 1100;   // Fenêtre entre Londres et New York
input int    FenetreEnd     = 1330;
input bool   TradeAsia      = false;   // L'Asie est la phase d'accumulation

input group "=== Déclenchement ==="
input FDK_EntryMode EntryMode   = FDK_ENTRY_LES_DEUX;
input bool          AllowNeutralH4 = true;
input bool          ForbidH4Contre = true;   // Interdire l'AMD à contresens du H4

input group "=== Structure / Biais ==="
input int    StructureLookback = 20;
input int    SwingDepth        = 3;
input FDK_BiasMode BiasMode    = FDK_BIAIS_CASSURE;
input double BiasDisplacementATR = 1.0;  // Déplacement exigé au-delà du niveau
input int    BiasBarsBack        = 200;  // Historique parcouru (cassure la plus ancienne mesurée : 141 bougies)

input group "=== Niveaux SL / TP ==="
input int    LevelsLookback = 150;
input int    LevelsDepth    = 3;
input double SL_BufferPips  = 0;
input FDK_SLMode SL_Mode    = FDK_SL_FIXE;
input double SL_FixedPips   = 200;
input FDK_TPMode TP_Mode    = FDK_TP_FIXE;
input double TP1_FixedPips  = 300;
input double TP2_FixedPips  = 500;

input group "=== Filtre gain/risque ==="
input double MinRR     = 1.0;          // 0 = filtre désactivé
input double MinSL_ATR = 0.5;          // Stop mini, en multiples d'ATR

input group "=== Exécution ==="
// Une seule position bloquait 63 % des signaux sur le test 2024-2026, et le
// choix de celui qui passe ne dependait que de l'ordre d'arrivee. En rejouant
// la fenetre 2025-06 / 2026-04 sans limite, 8 positions ont coexisté au plus
// fort, 4 ou moins 95 % du temps : le lot doit etre divise d'autant si le
// risque par evenement doit rester constant.
input int    MaxPositions = 5;    // Positions simultanees autorisees
input double Lots        = 0.02;
input long   MagicNumber = 20260927;

//--- Purement visuel. L'EA décide via FDK_Common.mqh ; charger l'indicateur
//--- ne change aucune décision, ça permet seulement de le VOIR travailler en
//--- mode visuel. Il tourne avec SES propres réglages par défaut, qui peuvent
//--- différer des entrées de l'EA si tu les as modifiées.
input group "=== Affichage (mode visuel) ==="
input bool   ShowIndicator = false;    // Ralentit nettement le test

CTrade   gTrade;
int      gIndHandle   = INVALID_HANDLE;
bool     gIndAttached = false;
datetime gLastBar    = 0;
int      gPrevDir    = 0;

//+------------------------------------------------------------------+
// Fenêtres où la manipulation puis la distribution peuvent avoir lieu.
// L'Asie en est exclue : c'est la phase d'accumulation.
void BuildWindows(FDK_Session &w[])
  {
   ArrayResize(w, 4);
   w[0].name = "LONDRES"; w[0].from = FDK_HHMMToSec(LondonStart);    w[0].to = FDK_HHMMToSec(LondonEnd);
   w[1].name = "FENETRE"; w[1].from = FDK_HHMMToSec(FenetreStart);   w[1].to = FDK_HHMMToSec(FenetreEnd);
   w[2].name = "NY_AM";   w[2].from = FDK_HHMMToSec(NewYorkAMStart); w[2].to = FDK_HHMMToSec(NewYorkAMEnd);
   w[3].name = "NY_PM";   w[3].from = FDK_HHMMToSec(NewYorkPMStart); w[3].to = FDK_HHMMToSec(NewYorkPMEnd);
  }

//+------------------------------------------------------------------+
void BuildSessions(FDK_Session &s[])
  {
   ArrayResize(s, 5);
   s[4].name = "FENETRE"; s[4].from = FDK_HHMMToSec(FenetreStart);   s[4].to = FDK_HHMMToSec(FenetreEnd);
   s[0].name = "ASIE";    s[0].from = FDK_HHMMToSec(AsiaStart);      s[0].to = FDK_HHMMToSec(AsiaEnd);
   s[1].name = "LONDRES"; s[1].from = FDK_HHMMToSec(LondonStart);    s[1].to = FDK_HHMMToSec(LondonEnd);
   s[2].name = "NY_AM";   s[2].from = FDK_HHMMToSec(NewYorkAMStart); s[2].to = FDK_HHMMToSec(NewYorkAMEnd);
   s[3].name = "NY_PM";   s[3].from = FDK_HHMMToSec(NewYorkPMStart); s[3].to = FDK_HHMMToSec(NewYorkPMEnd);
  }

//+------------------------------------------------------------------+
int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   gTrade.SetExpertMagicNumber(MagicNumber);
   gTrade.SetTypeFillingBySymbol(_Symbol);

   // L'attachement au graphique est reporte au premier tick : en mode visuel
   // le graphique du Simulateur n'existe pas encore pendant OnInit, et
   // ChartIndicatorAdd echoue alors sans rien signaler.
   if(ShowIndicator)
     {
      gIndHandle = iCustom(_Symbol, PERIOD_CURRENT, "FDK_Gold_Custom");
      if(gIndHandle == INVALID_HANDLE)
         Print("FDK_EA: indicateur non chargé (err ", GetLastError(),
               ") — le test continue, seul l'affichage manque.");
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(gIndHandle != INVALID_HANDLE)
      IndicatorRelease(gIndHandle);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // La règle se décide à la bougie, pas au tick : évaluer plus souvent
   // ferait diverger l'EA de l'indicateur et du backtest.
   if(gIndHandle != INVALID_HANDLE && !gIndAttached)
     {
      gIndAttached = true;
      if(!ChartIndicatorAdd(0, 0, gIndHandle))
         Print("FDK_EA: ChartIndicatorAdd a échoué (err ", GetLastError(), ")");
     }

   datetime cur = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur == gLastBar)
      return;
   gLastBar = cur;

   int off      = FDK_BeninOffset(AutoDetectTimezone, ServerToBeninOffsetHours);
   datetime now = TimeCurrent() + off * 3600;

   FDK_Session sess[];
   BuildSessions(sess);
   string active = FDK_ActiveSession(FDK_SecOfDay(now), sess);

   int biasM15 = FDK_BiasOf(BiasMode, _Symbol, PERIOD_M15, StructureLookback,
                            SwingDepth, BiasDisplacementATR, BiasBarsBack);
   int biasH4  = FDK_BiasOf(BiasMode, _Symbol, PERIOD_H4,  StructureLookback,
                            SwingDepth, BiasDisplacementATR, BiasBarsBack);

   // Séquence AMD du jour, évaluée exactement comme dans l'indicateur.
   datetime beninMidnight = now - (now % 86400) - off * 3600;
   double asiaHi = 0.0, asiaLo = 0.0;
   FDK_Amd amd;
   amd.side = 0; amd.ext = 0.0; amd.level = 0.0; amd.confirmed = false; amd.dir = 0;

   if(FDK_RangeHiLo(_Symbol, PERIOD_CURRENT,
                    beninMidnight + FDK_HHMMToSec(AsiaStart),
                    beninMidnight + FDK_HHMMToSec(AsiaEnd), asiaHi, asiaLo))
     {
      FDK_Session wins[];
      BuildWindows(wins);
      FDK_ComputeAmd(_Symbol, PERIOD_CURRENT,
                     beninMidnight + FDK_HHMMToSec(AsiaEnd), TimeCurrent(),
                     asiaHi, asiaLo, off, wins, amd);
     }

   bool asiaBlocked = (!TradeAsia && active == "ASIE");

   FDK_Decision dec;
   FDK_Decide(EntryMode, AllowNeutralH4, biasM15, biasH4, amd,
              active != "", asiaBlocked, dec, ForbidH4Contre);

   bool allowed = dec.allowed;
   int  dir     = dec.dir;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp1 = 0.0, tp2 = 0.0;
   double buffer = SL_BufferPips * FDK_PipSize(_Digits, _Point);
   FDK_StructureLevels(_Symbol, PERIOD_CURRENT, dir, price,
                       LevelsLookback, LevelsDepth, buffer, sl, tp1, tp2);
   sl = FDK_StopLoss(SL_Mode, dir, price, sl,
                     SL_FixedPips, FDK_PipSize(_Digits, _Point));
   FDK_Targets(TP_Mode, dir, price, tp1, tp2, TP1_FixedPips, TP2_FixedPips,
               FDK_PipSize(_Digits, _Point), tp1, tp2);

   double rr = FDK_RiskReward(price, sl, tp1);
   double atrBuf[1];
   double atr = 0.0;
   int hAtr = iATR(_Symbol, PERIOD_M15, 14);
   if(hAtr != INVALID_HANDLE && CopyBuffer(hAtr, 0, 0, 1, atrBuf) >= 1)
      atr = atrBuf[0];

   string motif = "";
   if(allowed && !FDK_LevelsAcceptable(price, sl, atr, MinSL_ATR, rr, MinRR, motif))
     {
      allowed = false;
      PrintFormat("FDK_EA: signal écarté — %s", motif);
     }

   bool isNew = allowed && (gPrevDir != dir);
   gPrevDir   = allowed ? dir : 0;
   if(isNew)
      PrintFormat("FDK_EA: signal %s par %s (M15=%d H4=%d, AMD=%s, R:R %.2f)",
                  dir > 0 ? "LONG" : "SHORT",
                  dec.amdSignal && dec.biasSignal ? "AMD+BIAIS"
                                                  : (dec.amdSignal ? "AMD" : "BIAIS"),
                  biasM15, biasH4, amd.confirmed ? "oui" : "non", rr);

   if(!isNew || sl <= 0.0 || tp1 <= 0.0)
      return;

   int ouvertes = CountPositions();
   if(ouvertes >= MathMax(1, MaxPositions))
     {
      PrintFormat("FDK_EA: signal %s non pris — %d position(s) déjà ouverte(s) "
                  "sur %d autorisée(s)",
                  dir > 0 ? "LONG" : "SHORT", ouvertes, MathMax(1, MaxPositions));
      return;
     }

   // Le broker refuse les stops trop proches du prix. Sans ce controle,
   // l'ordre echoue en "Invalid stops" et le signal disparait du rapport :
   // le backtest surestime alors les setups a stop large.
   long   lvl     = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist = lvl * _Point;
   if(minDist > 0.0
      && (MathAbs(price - sl) < minDist || MathAbs(tp1 - price) < minDist))
     {
      PrintFormat("FDK_EA: signal %s ignoré — stops sous le minimum broker "
                  "(%.1f pts requis, SL %.1f / TP %.1f)",
                  dir > 0 ? "LONG" : "SHORT", minDist / _Point,
                  MathAbs(price - sl) / _Point, MathAbs(tp1 - price) / _Point);
      return;
     }

   // Le lot doit être divisé si MaxPositions augmente, sinon le risque par
   // événement est multiplié d'autant. Un lot hors bornes ou hors pas fait
   // rejeter l'ordre par le broker et le signal disparaît du rapport : on
   // le normalise et on le signale.
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vol   = Lots;
   if(vstep > 0.0) vol = MathRound(vol / vstep) * vstep;
   if(vmin  > 0.0 && vol < vmin) vol = vmin;
   if(vmax  > 0.0 && vol > vmax) vol = vmax;
   if(MathAbs(vol - Lots) > 1e-8)
      PrintFormat("FDK_EA: lot %.2f ajusté à %.2f (min %.2f, max %.2f, pas %.2f)",
                  Lots, vol, vmin, vmax, vstep);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(dir > 0)
      gTrade.Buy(vol, _Symbol, ask, sl, tp1, "FDK long");
   else
      gTrade.Sell(vol, _Symbol, price, sl, tp1, "FDK short");
  }
