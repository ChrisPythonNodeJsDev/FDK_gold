#property copyright "Custom"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_plots 0

//--- Inputs: session times are in "Benin time" (GMT+1, no DST); the offset
//--- converts broker/server time to Benin time: BeninTime = ServerTime + offset.
//--- With AutoDetectTimezone the offset is derived from the broker's own clock,
//--- so it follows the broker across DST changes without manual edits.
input group "=== Fuseau horaire ==="
input bool   AutoDetectTimezone       = true;   // Détecter le décalage automatiquement
input int    ServerToBeninOffsetHours = 0;      // Décalage manuel Serveur -> Bénin (si auto désactivé)

input group "=== Sessions (heure Bénin, format HHMM) ==="
input int    AsiaStart      = 0000;
input int    AsiaEnd        = 0400;
input int    LondonStart    = 0800;
input int    LondonEnd      = 1100;
input int    NewYorkAMStart = 1330;
input int    NewYorkAMEnd   = 1600;
input int    NewYorkPMStart = 1600;
input int    NewYorkPMEnd   = 1900;

input group "=== Structure / Biais ==="
input int    StructureLookback = 20;    // Barres utilisées pour détecter la structure (swings)
input int    SwingDepth        = 3;     // Profondeur de détection des swing highs/lows

input group "=== Indicateurs ==="
input int    RSIPeriod = 14;
input int    ATRPeriod = 14;

//--- SL et TP viennent de la structure du prix, pas d'un multiple d'ATR :
//--- le stop se place au-delà du dernier swing opposé, les cibles sur les
//--- swings précédents dans le sens du trade.
input group "=== Niveaux SL / TP (structure) ==="
input int    LevelsLookback = 150;   // Barres analysées pour trouver les swings
input int    LevelsDepth    = 3;     // Profondeur de détection des swings
input double SL_BufferPips  = 0;     // Marge au-delà du swing pour le SL (pips)

input group "=== Affichage ==="
input color  ColorAsia        = clrDodgerBlue;
input color  ColorLondon      = clrSeaGreen;
input color  ColorNewYorkAM   = clrGoldenrod;
input color  ColorNewYorkPM   = clrIndianRed;
input int    BoxOpacity       = 40;      // 0-255, transparence des zones de session
input int    PanelX           = 10;
input int    PanelY           = 10;
input color  PanelBgColor     = clrBlack;
input color  PanelTextColor   = clrWhite;
input color  BullishColor     = clrLime;
input color  BearishColor     = clrTomato;

input group "=== Étiquette journalière (graphique) ==="
input bool   ShowDayLabels    = true;    // Afficher biais H4/M15 + range sur chaque journée
input color  DayLabelColor    = clrCornflowerBlue;
input int    DayLabelFontSize = 8;
input int    DayLabelMaxDays   = 10;    // Nb max de journées étiquetées (0 = toutes)
input int    SessionMaxDays    = 15;    // Nb max de journées de zones de session

//--- Supply/demand zones: a "base" of small candles followed by an impulse
//--- candle marks an imbalance price often revisits. A zone stays "fraîche"
//--- until price trades back into it (mitigation).
input group "=== Zones Offre / Demande ==="
input bool   ShowZones         = true;   // Afficher les zones d'offre et de demande
input double ZoneImpulseATR    = 1.5;    // Corps mini de la bougie d'impulsion (x ATR)
input double ZoneBaseATR       = 0.5;    // Corps maxi des bougies de base (x ATR)
input int    ZoneMaxBase       = 3;      // Nombre maxi de bougies dans la base
input int    ZoneLookback      = 400;    // Barres analysées pour la détection
input int    ZoneMaxPerSide    = 6;      // Nombre maxi de zones affichées par côté
input bool   ZoneShowMitigated = false;  // Garder les zones déjà touchées (en estompé)
input bool   ZoneUseHTF        = true;   // Ajouter les zones d'une unité de temps supérieure
input ENUM_TIMEFRAMES ZoneHTF  = PERIOD_H4;
input color  ColorSupply       = clrCrimson;
input color  ColorDemand       = clrDeepSkyBlue;
input int    ZoneOpacity       = 55;     // 0-255, opacité du remplissage des zones

input group "=== Asiatique / Sweeps ==="
input bool   ShowAsiaStats     = true;  // Taille de l'asiatique et compteur de sweeps
input int    AsiaAvgDays       = 10;    // Jours servant de moyenne de référence
input double AsiaExpandedRatio = 1.0;   // Seuil (x moyenne) au-delà duquel l'asiatique est dite expansée

//--- Hypothese des points numerotes, inspiree des fleches observees sur
//--- l'indicateur de reference : dans une fenetre quotidienne on numerote
//--- les swings, et la relation entre le #1 et le #2 fait "confirmation".
//--- Mesuree sur 15 mois : perdante. Conservee comme outil de lecture et
//--- pour verifier si l'interpretation elle-meme est correcte.
input group "=== Points numérotés (fenêtre) ==="
input bool   ShowConfirmPoints  = true;
input int    ConfirmWindowStart = 1100;  // Début de fenêtre, HHMM heure Bénin
input int    ConfirmWindowEnd   = 1330;  // Fin de fenêtre
input int    ConfirmDepth       = 1;     // Bougies de confirmation de chaque côté

input group "=== Niveaux du signal ==="
input bool   FreezeLevels    = true;   // Figer SL/TP1/TP2 au moment du signal
input bool   ShowSignalLines = true;   // Tracer les niveaux figés sur le graphique

input group "=== Journal des signaux ==="
input bool   LogSignals  = true;   // Enregistrer chaque ENTREE AUTORISEE dans un CSV
input string LogFileName = "";     // Vide = FDK_signaux_<symbole>.csv

//--- Object name prefixes
#define PFX "FDKG_"
#define PANEL_BG    PFX"panel_bg"
#define PANEL_PREFIX PFX"panel_line_"

int hRSI, hATR_M15;
int hATR_Zone = INVALID_HANDLE;      // ATR on the chart timeframe
int hATR_ZoneHTF = INVALID_HANDLE;   // ATR on the higher timeframe
datetime lastDrawnDay = 0;
int      panelLineCount = 0;   // lines drawn on the previous panel render

//--- Contexte recalcule UNE FOIS PAR BOUGIE. MT5 interrompt un indicateur
//--- trop lent ("indicator is too slow") et le graphique se fige : tout ce
//--- qui lit des barres doit rester hors du chemin appele a chaque tick.
datetime gCtxBar       = 0;
int      gCtxBiasM15   = 0, gCtxBiasH4 = 0;
double   gCtxRSI       = 0.0, gCtxATR   = 0.0;
bool     gCtxAsiaValid = false, gCtxAsiaDone = false;
double   gCtxAsiaPips  = 0.0, gCtxAsiaRatio = 0.0;
int      gCtxSwUp      = 0, gCtxSwDn = 0, gCtxSwTot = 0;
double   gCtxRangeHi   = 0.0, gCtxRangeLo = 0.0;
double   gCtxSL        = 0.0, gCtxTP1 = 0.0, gCtxTP2 = 0.0;

//--- Etat des points numerotes de la fenetre du jour
int    gConfHighs = 0, gConfLows = 0;
int    gConfState = 0;          // -1 baissier confirme, +1 haussier, 0 aucun
string gConfLast  = "";

//--- Cache de la moyenne asiatique (recalculee une fois par jour)
datetime gAsiaAvgDay  = 0;
double   gAsiaAvgPips = 0.0;

//--- Niveaux figes au moment du signal. Sans ca, TP et SL se recalculent
//--- depuis le prix courant a chaque tick et ne designent aucun objectif
//--- stable : inutilisable pour poser un ordre.
datetime gSigTime  = 0;
int      gSigDir   = 0;
double   gSigPrice = 0.0, gSigATR = 0.0;
double   gSigTP1   = 0.0, gSigTP2 = 0.0, gSigSL = 0.0;

//--- Signal journal state
datetime gLastLoggedBar = 0;   // bar already written, guards against duplicates
int      gPrevSignalDir = 0;   // previous ENTREE AUTORISEE direction (0 = none)

//--- Last state the heavy chart layer was drawn for
datetime gLastBar          = 0;
int      gLastFirstVisible = -1;
int      gLastVisibleBars  = -1;

//--- A base/impulse imbalance. Supply sits above price, demand below.
struct Zone
  {
   datetime        tStart;
   double          hi;
   double          lo;
   bool            isSupply;
   bool            mitigated;
   ENUM_TIMEFRAMES tf;
  };

Zone   gZones[];
int    gZoneCount = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   hRSI = iRSI(_Symbol, PERIOD_M15, RSIPeriod, PRICE_CLOSE);
   hATR_M15 = iATR(_Symbol, PERIOD_M15, ATRPeriod);
   if(hRSI == INVALID_HANDLE || hATR_M15 == INVALID_HANDLE)
     {
      Print("FDK_Gold_Custom: erreur création handles indicateurs");
      return(INIT_FAILED);
     }

   if(ShowZones)
     {
      hATR_Zone = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
      if(hATR_Zone == INVALID_HANDLE)
        {
         Print("FDK_Gold_Custom: erreur handle ATR zones");
         return(INIT_FAILED);
        }
      if(ZoneUseHTF)
        {
         hATR_ZoneHTF = iATR(_Symbol, ZoneHTF, ATRPeriod);
         if(hATR_ZoneHTF == INVALID_HANDLE)
           {
            Print("FDK_Gold_Custom: erreur handle ATR zones HTF");
            return(INIT_FAILED);
           }
        }
     }
   if(LogSignals)
      gLastLoggedBar = InitLog();

   CreatePanel();
   EventSetTimer(5);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateAll();
  }

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                 const int prev_calculated,
                 const datetime &time[],
                 const double &open[],
                 const double &high[],
                 const double &low[],
                 const double &close[],
                 const long &tick_volume[],
                 const long &volume[],
                 const int &spread[])
  {
   UpdateAll();
   return(rates_total);
  }

//+------------------------------------------------------------------+
string LogPath()
  {
   if(StringLen(LogFileName) > 0)
      return(LogFileName);
   return("FDK_signaux_" + _Symbol + ".csv");
  }

//+------------------------------------------------------------------+
// Create the journal with its header if absent, and return the last bar
// already recorded so a reload does not duplicate a signal still standing.
datetime InitLog()
  {
   string f = LogPath();

   if(!FileIsExist(f))
     {
      int hw = FileOpen(f, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(hw == INVALID_HANDLE)
        {
         PrintFormat("FDK: journal %s non creable (err %d)", f, GetLastError());
         return(0);
        }
      FileWrite(hw, "bar_time_serveur", "tick_time_serveur", "heure_benin",
                "symbole", "periode", "sens", "prix", "atr", "tp1", "tp2", "sl",
                "session", "biais_m15", "biais_h4", "rsi",
                "asie_pips", "asie_ratio", "sweeps_haut", "sweeps_bas");
      FileClose(hw);
      PrintFormat("FDK: journal cree -> MQL5/Files/%s", f);
      return(0);
     }

   int hr = FileOpen(f, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(hr == INVALID_HANDLE)
      return(0);

   datetime last = 0;
   while(!FileIsEnding(hr))
     {
      string first = FileReadString(hr);
      while(!FileIsLineEnding(hr) && !FileIsEnding(hr))
         FileReadString(hr);
      // StringToTime renvoie la date du jour a minuit pour une chaine
      // non datee : sans ce filtre, l'en-tete passait pour un signal.
      if(StringFind(first, ".") < 0 || StringFind(first, ":") < 0)
         continue;
      datetime t = StringToTime(first);
      if(t > 0)
         last = t;
     }
   FileClose(hr);
   PrintFormat("FDK: journal %s, dernier signal enregistre %s", f,
               last > 0 ? TimeToString(last, TIME_DATE|TIME_MINUTES) : "aucun");
   return(last);
  }

//+------------------------------------------------------------------+
void LogSignal(datetime barTime, int dir, double price, double atr,
               double tp1, double tp2, double sl, string session,
               int bM15, int bH4, double rsi,
               double asiaPips, double asiaRatio, int swUp, int swDn)
  {
   string f = LogPath();
   int h = FileOpen(f, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
     {
      PrintFormat("FDK: journal %s inaccessible (err %d)", f, GetLastError());
      return;
     }
   FileSeek(h, 0, SEEK_END);

   int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   FileWrite(h,
             TimeToString(barTime, TIME_DATE|TIME_SECONDS),
             TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
             TimeToString(BeninTime(), TIME_DATE|TIME_SECONDS),
             _Symbol,
             EnumToString((ENUM_TIMEFRAMES)_Period),
             dir > 0 ? "LONG" : "SHORT",
             DoubleToString(price, dg),
             DoubleToString(atr,   dg),
             DoubleToString(tp1,   dg),
             DoubleToString(tp2,   dg),
             DoubleToString(sl,    dg),
             session,
             IntegerToString(bM15),
             IntegerToString(bH4),
             DoubleToString(rsi, 1),
             DoubleToString(asiaPips,  0),
             DoubleToString(asiaRatio, 3),
             IntegerToString(swUp),
             IntegerToString(swDn));
   FileClose(h);

   gLastLoggedBar = barTime;
   PrintFormat("FDK: signal %s enregistre (%s, %s)",
               dir > 0 ? "LONG" : "SHORT", session,
               TimeToString(barTime, TIME_DATE|TIME_MINUTES));
  }

//+------------------------------------------------------------------+
// Boxes, zones and day labels only change when a bar closes or the visible
// window moves. Rebuilding them on every tick was what made the chart blink.
void UpdateAll()
  {
   datetime curBar   = iTime(_Symbol, PERIOD_CURRENT, 0);
   int      firstVis = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   int      visBars  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);

   if(curBar != gLastBar || firstVis != gLastFirstVisible || visBars != gLastVisibleBars)
     {
      gLastBar          = curBar;
      gLastFirstVisible = firstVis;
      gLastVisibleBars  = visBars;

      DrawSessionBoxes();
      DrawDayLabels();
      BuildConfirmPoints();
      BuildZones();
      DrawZones();
     }

   DrawRangeLines();   // cheap, moves two lines in place
   UpdatePanel();
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void KeepName(string &keep[], string nm)
  {
   int n = ArraySize(keep);
   ArrayResize(keep, n + 1);
   keep[n] = nm;
  }

//+------------------------------------------------------------------+
// Delete only the objects under `prefix` that are no longer wanted. Pruning
// instead of ObjectsDeleteAll keeps the existing objects on screen, which is
// what stops the flicker.
void PruneObjects(string prefix, string &keep[])
  {
   int kn = ArraySize(keep);
   for(int i = ObjectsTotal(0, -1, -1) - 1; i >= 0; i--)
     {
      string nm = ObjectName(0, i, -1, -1);
      if(StringFind(nm, prefix) != 0)
         continue;
      bool found = false;
      for(int k = 0; k < kn; k++)
         if(keep[k] == nm) { found = true; break; }
      if(!found)
         ObjectDelete(0, nm);
     }
  }

//+------------------------------------------------------------------+
// Hours to add to server time to obtain Benin time (WAT = GMT+1, no DST).
// Auto mode compares the broker clock against GMT, so a broker switching to
// summer time is picked up on the next tick with no input change.
int BeninOffsetHours()
  {
   if(!AutoDetectTimezone)
      return(ServerToBeninOffsetHours);

   datetime gmt = TimeGMT();
   if(gmt <= 0)                       // GMT unavailable: fall back to manual
      return(ServerToBeninOffsetHours);

   double diff = ((double)(gmt + 3600) - (double)TimeCurrent()) / 3600.0;
   return((int)MathRound(diff));
  }

//+------------------------------------------------------------------+
datetime BeninTime()
  {
   return(TimeCurrent() + BeninOffsetHours() * 3600);
  }

//+------------------------------------------------------------------+
// Server-time timestamp of the start of the current Benin day
datetime BeninDayStart()
  {
   datetime beninNow = BeninTime();
   return(beninNow - (beninNow % 86400) - BeninOffsetHours() * 3600);
  }

//+------------------------------------------------------------------+
// Convert HHMM int (e.g. 1330) to seconds-since-midnight
int HHMMToSeconds(int hhmm)
  {
   int hh = hhmm / 100;
   int mm = hhmm % 100;
   return(hh * 3600 + mm * 60);
  }

//+------------------------------------------------------------------+
// Returns seconds-since-midnight for a given Benin datetime
int SecondsOfDay(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return(dt.hour * 3600 + dt.min * 60 + dt.sec);
  }

//+------------------------------------------------------------------+
struct SessionDef
  {
   string name;
   int    startSec;
   int    endSec;
   color  clr;
  };

int GetSessions(SessionDef &sessions[])
  {
   ArrayResize(sessions, 4);
   sessions[0].name = "ASIE";      sessions[0].startSec = HHMMToSeconds(AsiaStart);      sessions[0].endSec = HHMMToSeconds(AsiaEnd);      sessions[0].clr = ColorAsia;
   sessions[1].name = "LONDRES";   sessions[1].startSec = HHMMToSeconds(LondonStart);    sessions[1].endSec = HHMMToSeconds(LondonEnd);    sessions[1].clr = ColorLondon;
   sessions[2].name = "NY AM";     sessions[2].startSec = HHMMToSeconds(NewYorkAMStart); sessions[2].endSec = HHMMToSeconds(NewYorkAMEnd); sessions[2].clr = ColorNewYorkAM;
   sessions[3].name = "NY PM";     sessions[3].startSec = HHMMToSeconds(NewYorkPMStart); sessions[3].endSec = HHMMToSeconds(NewYorkPMEnd); sessions[3].clr = ColorNewYorkPM;
   return(4);
  }

//+------------------------------------------------------------------+
// Draw session boxes for the visible chart range, one rectangle per session per day
void DrawSessionBoxes()
  {
   if(!IntradayTF())
     {
      string none[];
      PruneObjects(PFX"box_", none);
      return;
     }

   int barsVisible = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   int firstVisible = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   if(barsVisible <= 0)
      return;

   int startIdx = firstVisible;
   int endIdx   = MathMax(0, firstVisible - barsVisible);

   datetime tStart = iTime(_Symbol, PERIOD_CURRENT, MathMin(startIdx, iBars(_Symbol,PERIOD_CURRENT)-1));
   datetime tEnd   = iTime(_Symbol, PERIOD_CURRENT, endIdx);

   SessionDef sessions[];
   GetSessions(sessions);

   // Iterate day by day across the visible range. Session hours are Benin
   // seconds-of-day, so the cursor must sit on Benin midnight expressed in
   // server time — anchoring on server midnight would shift every box.
   int off = BeninOffsetHours();
   datetime beninOldest = tStart + off * 3600;
   datetime dayCursor   = (beninOldest - (beninOldest % 86400)) - off * 3600;
   datetime dayLimit    = tEnd;

   // Plafond dur : chaque journee coute quatre balayages de barres.
   int span = (int)((dayLimit - dayCursor) / 86400) + 1;
   if(span > SessionMaxDays)
      dayCursor += (datetime)((span - SessionMaxDays) * 86400);

   string keep[];

   while(dayCursor <= dayLimit)
     {
      for(int s = 0; s < ArraySize(sessions); s++)
        {
         datetime boxStart = dayCursor + sessions[s].startSec;
         datetime boxEnd   = dayCursor + sessions[s].endSec;
         if(boxEnd <= boxStart)
            continue;

         string objName = PFX + "box_" + sessions[s].name + "_" + IntegerToString((long)dayCursor);
         double hi, lo;
         if(!GetRangeHighLow(boxStart, boxEnd, hi, lo))
            continue;

         if(ObjectFind(0, objName) < 0)
            ObjectCreate(0, objName, OBJ_RECTANGLE, 0, boxStart, hi, boxEnd, lo);
         else
           {
            ObjectMove(0, objName, 0, boxStart, hi);
            ObjectMove(0, objName, 1, boxEnd, lo);
           }
         ObjectSetInteger(0, objName, OBJPROP_COLOR, sessions[s].clr);
         ObjectSetInteger(0, objName, OBJPROP_FILL, true);
         ObjectSetInteger(0, objName, OBJPROP_BACK, true);
         ObjectSetInteger(0, objName, OBJPROP_STYLE, STYLE_SOLID);
         ObjectSetInteger(0, objName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
         KeepName(keep, objName);
        }
      dayCursor += 86400;
     }

   PruneObjects(PFX"box_", keep);
  }

//+------------------------------------------------------------------+
bool GetRangeHighLow(datetime from, datetime to, double &hi, double &lo)
  {
   int barFrom = iBarShift(_Symbol, PERIOD_CURRENT, from, false);
   int barTo   = iBarShift(_Symbol, PERIOD_CURRENT, to, false);
   if(barFrom < 0 || barTo < 0)
      return(false);
   int startBar = MathMin(barFrom, barTo);
   int count    = MathAbs(barFrom - barTo) + 1;
   if(count < 1)
      return(false);
   int hiIdx = iHighest(_Symbol, PERIOD_CURRENT, MODE_HIGH, count, startBar);
   int loIdx = iLowest(_Symbol, PERIOD_CURRENT, MODE_LOW, count, startBar);
   if(hiIdx < 0 || loIdx < 0)
      return(false);
   hi = iHigh(_Symbol, PERIOD_CURRENT, hiIdx);
   lo = iLow(_Symbol, PERIOD_CURRENT, loIdx);
   return(true);
  }

//+------------------------------------------------------------------+
// Draw today's range high/low horizontal dashed lines
void DrawRangeLines()
  {
   datetime dayStart = BeninDayStart();
   datetime dayEnd   = TimeCurrent();

   double hi, lo;
   if(!GetRangeHighLow(dayStart, dayEnd, hi, lo))
      return;

   DrawHLine(PFX"line_high", hi, clrRed, "Range High");
   DrawHLine(PFX"line_low",  lo, clrDodgerBlue, "Range Low");
  }

//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, string text)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   else
      ObjectMove(0, name, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
  }

//+------------------------------------------------------------------+
// Simple structure-based bias: compare last two swing highs and last two swing lows
// Returns 1 = bullish, -1 = bearish, 0 = neutre/indéterminé
// startShift = 0 evaluates the bias now; a positive shift evaluates it as of
// that bar, which is what the per-day chart labels need.
int ComputeBias(ENUM_TIMEFRAMES tf, int startShift = 0)
  {
   double highs[], lows[];
   int bars = StructureLookback + SwingDepth * 2 + 2;
   if(startShift < 0)
      startShift = 0;
   if(CopyHigh(_Symbol, tf, startShift, bars, highs) < bars)
      return(0);
   if(CopyLow(_Symbol, tf, startShift, bars, lows) < bars)
      return(0);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   int swingHighIdx[]; int swingLowIdx[];
   int shCount = 0, slCount = 0;
   ArrayResize(swingHighIdx, StructureLookback);
   ArrayResize(swingLowIdx, StructureLookback);

   for(int i = SwingDepth; i < StructureLookback + SwingDepth; i++)
     {
      bool isHigh = true, isLow = true;
      for(int k = 1; k <= SwingDepth; k++)
        {
         if(highs[i] <= highs[i-k] || highs[i] <= highs[i+k]) isHigh = false;
         if(lows[i]  >= lows[i-k]  || lows[i]  >= lows[i+k])  isLow  = false;
        }
      if(isHigh && shCount < StructureLookback) swingHighIdx[shCount++] = i;
      if(isLow  && slCount < StructureLookback) swingLowIdx[slCount++]  = i;
     }

   if(shCount < 2 || slCount < 2)
      return(0);

   double h1 = highs[swingHighIdx[0]], h2 = highs[swingHighIdx[1]];
   double l1 = lows[swingLowIdx[0]],   l2 = lows[swingLowIdx[1]];

   bool higherHigh = h1 > h2;
   bool higherLow  = l1 > l2;
   bool lowerHigh  = h1 < h2;
   bool lowerLow   = l1 < l2;

   if(higherHigh && higherLow)
      return(1);
   if(lowerHigh && lowerLow)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
// Scan one timeframe for base+impulse imbalances and append them to gZones.
// Series indexing: index 0 is the newest bar, so the base sits at HIGHER
// indices than the impulse that left it behind.
void DetectZones(ENUM_TIMEFRAMES tf, int atrHandle)
  {
   if(atrHandle == INVALID_HANDLE)
      return;

   int avail = Bars(_Symbol, tf);
   if(avail < ATRPeriod + ZoneMaxBase + 10)
      return;

   int need = MathMin(ZoneLookback, avail - ZoneMaxBase - 2);
   if(need < 10)
      return;

   double atr[], op[], cl[], hi[], lo[];
   datetime tm[];
   int span = need + ZoneMaxBase + 2;

   if(CopyBuffer(atrHandle, 0, 0, span, atr) < span) return;
   if(CopyOpen (_Symbol, tf, 0, span, op)   < span) return;
   if(CopyClose(_Symbol, tf, 0, span, cl)   < span) return;
   if(CopyHigh (_Symbol, tf, 0, span, hi)   < span) return;
   if(CopyLow  (_Symbol, tf, 0, span, lo)   < span) return;
   if(CopyTime (_Symbol, tf, 0, span, tm)   < span) return;

   ArraySetAsSeries(atr, true); ArraySetAsSeries(op, true);
   ArraySetAsSeries(cl,  true); ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo,  true); ArraySetAsSeries(tm, true);

   // Walk newest -> oldest so the freshest zones are kept first
   for(int i = 1; i < need; i++)
     {
      double a = atr[i];
      if(a <= 0.0)
         continue;

      double body = MathAbs(cl[i] - op[i]);
      if(body < ZoneImpulseATR * a)
         continue;                              // not an impulse candle

      bool bullish = (cl[i] > op[i]);

      // Collect the small-bodied base candles immediately before the impulse
      int baseCount = 0;
      for(int j = i + 1; j <= i + ZoneMaxBase && j < span; j++)
        {
         if(atr[j] <= 0.0)
            break;
         if(MathAbs(cl[j] - op[j]) > ZoneBaseATR * atr[j])
            break;
         baseCount++;
        }
      if(baseCount == 0)
         continue;                              // impulse with no base to mark

      double zHi = hi[i + 1], zLo = lo[i + 1];
      for(int j = i + 1; j <= i + baseCount; j++)
        {
         zHi = MathMax(zHi, hi[j]);
         zLo = MathMin(zLo, lo[j]);
        }
      if(zHi <= zLo)
         continue;

      // Mitigated once price trades back into the zone after the impulse
      bool mitigated = false;
      for(int k = i - 1; k >= 0; k--)
        {
         if(bullish ? (lo[k] <= zHi) : (hi[k] >= zLo))
           {
            mitigated = true;
            break;
           }
        }
      if(mitigated && !ZoneShowMitigated)
         continue;

      int n = ArraySize(gZones);
      ArrayResize(gZones, n + 1);
      gZones[n].tStart    = tm[i + baseCount];
      gZones[n].hi        = zHi;
      gZones[n].lo        = zLo;
      gZones[n].isSupply  = !bullish;
      gZones[n].mitigated = mitigated;
      gZones[n].tf        = tf;

      i += baseCount;                           // don't re-detect inside this base
     }
  }

//+------------------------------------------------------------------+
// Rebuild the zone list, newest first, capped per side.
void BuildZones()
  {
   ArrayResize(gZones, 0);
   gZoneCount = 0;
   if(!ShowZones)
      return;

   DetectZones(PERIOD_CURRENT, hATR_Zone);
   if(ZoneUseHTF)
      DetectZones(ZoneHTF, hATR_ZoneHTF);

   int total = ArraySize(gZones);
   if(total == 0)
      return;

   // Keep the zones NEAREST to price rather than merely the most recent:
   // a perfectly fresh zone 1800 pips away is noise on the chart.
   double price = iClose(_Symbol, PERIOD_CURRENT, 0);
   bool   taken[];
   ArrayResize(taken, total);
   for(int i = 0; i < total; i++)
      taken[i] = false;

   Zone kept[];
   int supply = 0, demand = 0;

   for(int pass = 0; pass < total; pass++)
     {
      int    best     = -1;
      double bestDist = 0.0;
      for(int i = 0; i < total; i++)
        {
         if(taken[i])                                        continue;
         if(gZones[i].isSupply  && supply >= ZoneMaxPerSide)  continue;
         if(!gZones[i].isSupply && demand >= ZoneMaxPerSide)  continue;

         double edge = gZones[i].isSupply ? gZones[i].lo : gZones[i].hi;
         double d    = MathAbs(edge - price);
         if(best < 0 || d < bestDist)
           { best = i; bestDist = d; }
        }
      if(best < 0)
         break;

      taken[best] = true;
      if(gZones[best].isSupply) supply++; else demand++;

      int n = ArraySize(kept);
      ArrayResize(kept, n + 1);
      kept[n] = gZones[best];
     }
   ArrayResize(gZones, ArraySize(kept));
   for(int i = 0; i < ArraySize(kept); i++)
      gZones[i] = kept[i];
   gZoneCount = ArraySize(gZones);
  }

//+------------------------------------------------------------------+
void DrawZones()
  {
   string keep[];
   if(!ShowZones)
     {
      PruneObjects(PFX"zone_", keep);
      return;
     }

   datetime rightEdge = TimeCurrent() + PeriodSeconds(PERIOD_CURRENT) * 10;
   int alpha = (int)MathMax(0, MathMin(255, ZoneOpacity));

   for(int i = 0; i < gZoneCount; i++)
     {
      // Name keyed on the zone itself, not its list position, so a rebuild
      // reuses the same object instead of destroying and recreating it.
      string name = StringFormat("%szone_%s_%d_%d", PFX,
                                 gZones[i].isSupply ? "S" : "D",
                                 (int)gZones[i].tStart, (int)gZones[i].tf);
      color  base = gZones[i].isSupply ? ColorSupply : ColorDemand;
      uchar  a    = (uchar)(gZones[i].mitigated ? alpha / 3 : alpha);

      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_RECTANGLE, 0, gZones[i].tStart, gZones[i].hi, rightEdge, gZones[i].lo);
      else
        {
         ObjectMove(0, name, 0, gZones[i].tStart, gZones[i].hi);
         ObjectMove(0, name, 1, rightEdge, gZones[i].lo);
        }
      ObjectSetInteger(0, name, OBJPROP_COLOR, ColorToARGB(base, a));
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetString (0, name, OBJPROP_TOOLTIP,
                       StringFormat("%s %s%s", gZones[i].isSupply ? "OFFRE" : "DEMANDE",
                                    EnumToString(gZones[i].tf),
                                    gZones[i].mitigated ? " (touchée)" : " (fraîche)"));
      KeepName(keep, name);
     }

   PruneObjects(PFX"zone_", keep);
  }

//+------------------------------------------------------------------+
// Nearest fresh supply above / demand below the current price.
// Returns false when no such zone exists.
bool NearestZone(bool wantSupply, double price, double &zHi, double &zLo, double &distPips)
  {
   bool   found = false;
   double bestEdge = 0.0;

   for(int i = 0; i < gZoneCount; i++)
     {
      if(gZones[i].isSupply != wantSupply) continue;
      if(gZones[i].mitigated)              continue;

      if(wantSupply)
        {
         if(gZones[i].lo < price) continue;          // must sit above price
         if(!found || gZones[i].lo < bestEdge)
           { bestEdge = gZones[i].lo; zHi = gZones[i].hi; zLo = gZones[i].lo; found = true; }
        }
      else
        {
         if(gZones[i].hi > price) continue;          // must sit below price
         if(!found || gZones[i].hi > bestEdge)
           { bestEdge = gZones[i].hi; zHi = gZones[i].hi; zLo = gZones[i].lo; found = true; }
        }
     }

   if(found)
      distPips = MathAbs(bestEdge - price) / PipSize();
   return(found);
  }

//+------------------------------------------------------------------+
// True when price currently sits inside a fresh zone of the given side.
bool PriceInZone(bool wantSupply, double price)
  {
   for(int i = 0; i < gZoneCount; i++)
     {
      if(gZones[i].isSupply != wantSupply) continue;
      if(gZones[i].mitigated)              continue;
      if(price >= gZones[i].lo && price <= gZones[i].hi)
         return(true);
     }
   return(false);
  }

//+------------------------------------------------------------------+
// Sessions, asiatique et points numerotes n'ont de sens qu'en intraday :
// au-dessus de H1 une session tient dans une seule bougie. Sans ce garde-fou,
// la boucle jour par jour parcourt des centaines de journees sur un
// graphique D1 et MT5 coupe l'indicateur pour lenteur.
bool IntradayTF()
  {
   return(PeriodSeconds(PERIOD_CURRENT) <= 3600);
  }

//+------------------------------------------------------------------+
// One pip. Gold quotes on 2 digits, where a pip is 0.10 (not 0.01).
double PipSize()
  {
   if(_Digits == 2 || _Digits == 3 || _Digits == 5)
      return(_Point * 10);
   return(_Point);
  }

//+------------------------------------------------------------------+
void MakeDayText(string name, datetime t, double price, string txt, color clr)
  {
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_TEXT, 0, t, price);
   else
      ObjectMove(0, name, 0, t, price);
   ObjectSetString(0, name, OBJPROP_TEXT, txt);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, DayLabelFontSize);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
// One label per Benin day, sitting on that day's range-high line:
// H4 bias / M15 bias / range in pips, all evaluated at the day's close.
void DrawDayLabels()
  {
   string keep[];
   if(!ShowDayLabels)
     {
      PruneObjects(PFX"daylbl_", keep);
      PruneObjects(PFX"dayhi_",  keep);
      return;
     }

   int barsVisible  = (int)ChartGetInteger(0, CHART_VISIBLE_BARS);
   int firstVisible = (int)ChartGetInteger(0, CHART_FIRST_VISIBLE_BAR);
   if(barsVisible <= 0)
      return;

   int totalBars = iBars(_Symbol, PERIOD_CURRENT);
   if(totalBars <= 0)
      return;

   datetime tStart = iTime(_Symbol, PERIOD_CURRENT, MathMin(firstVisible, totalBars - 1));
   datetime tEnd   = iTime(_Symbol, PERIOD_CURRENT, MathMax(0, firstVisible - barsVisible));

   int off = BeninOffsetHours();
   datetime beninOldest = tStart + off * 3600;
   datetime dayCursor   = (beninOldest - (beninOldest % 86400)) - off * 3600;
   double   pip         = PipSize();

   // On a high timeframe the visible window can span months; one label per
   // day would bury the chart under overlapping text.
   if(DayLabelMaxDays > 0)
     {
      int span = (int)((tEnd - dayCursor) / 86400) + 1;
      if(span > DayLabelMaxDays)
         dayCursor += (datetime)((span - DayLabelMaxDays) * 86400);
     }

   while(dayCursor <= tEnd)
     {
      datetime dayEnd = dayCursor + 86400;
      if(dayEnd > TimeCurrent())
         dayEnd = TimeCurrent();

      double hi, lo;
      if(dayEnd > dayCursor && GetRangeHighLow(dayCursor, dayEnd, hi, lo))
        {
         int shiftH4  = iBarShift(_Symbol, PERIOD_H4,  dayEnd, false);
         int shiftM15 = iBarShift(_Symbol, PERIOD_M15, dayEnd, false);
         int bH4      = ComputeBias(PERIOD_H4,  shiftH4);
         int bM15     = ComputeBias(PERIOD_M15, shiftM15);

         string tag  = IntegerToString((long)dayCursor);
         double step = MathMax((hi - lo) * 0.05, 10 * _Point);

         // Dashed segment marking this day's high, with the label stacked above it
         string hiName = PFX + "dayhi_" + tag;
         if(ObjectFind(0, hiName) < 0)
            ObjectCreate(0, hiName, OBJ_TREND, 0, dayCursor, hi, dayEnd, hi);
         else
           {
            ObjectMove(0, hiName, 0, dayCursor, hi);
            ObjectMove(0, hiName, 1, dayEnd, hi);
           }
         ObjectSetInteger(0, hiName, OBJPROP_COLOR, DayLabelColor);
         ObjectSetInteger(0, hiName, OBJPROP_STYLE, STYLE_DASH);
         ObjectSetInteger(0, hiName, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, hiName, OBJPROP_RAY_RIGHT, false);
         ObjectSetInteger(0, hiName, OBJPROP_BACK, true);
         ObjectSetInteger(0, hiName, OBJPROP_SELECTABLE, false);

         MakeDayText(PFX + "daylbl_h4_"  + tag, dayCursor, hi + step * 3,
                     "H4:"  + BiasText(bH4),  BiasColor(bH4));
         MakeDayText(PFX + "daylbl_m15_" + tag, dayCursor, hi + step * 2,
                     "M15:" + BiasText(bM15), BiasColor(bM15));
         MakeDayText(PFX + "daylbl_r_"   + tag, dayCursor, hi + step,
                     StringFormat("R:%d", (int)MathRound((hi - lo) / pip)), DayLabelColor);

         KeepName(keep, hiName);
         KeepName(keep, PFX + "daylbl_h4_"  + tag);
         KeepName(keep, PFX + "daylbl_m15_" + tag);
         KeepName(keep, PFX + "daylbl_r_"   + tag);
        }
      dayCursor += 86400;
     }

   PruneObjects(PFX"daylbl_", keep);
   PruneObjects(PFX"dayhi_",  keep);
  }

//+------------------------------------------------------------------+
// Plage de la session asiatique pour un jour donne (minuit Benin en heure serveur)
bool AsiaRange(datetime dayStartServer, double &hi, double &lo)
  {
   datetime a = dayStartServer + HHMMToSeconds(AsiaStart);
   datetime b = dayStartServer + HHMMToSeconds(AsiaEnd);
   if(b <= a)
      return(false);
   return(GetRangeHighLow(a, b, hi, lo));
  }

//+------------------------------------------------------------------+
// Moyenne de la taille de l'asiatique sur les N jours precedents, en pips.
// Les jours sans donnees (week-ends, feries) sont simplement ignores.
double AsiaAvgCached()
  {
   datetime today = BeninDayStart();
   if(today == gAsiaAvgDay)
      return(gAsiaAvgPips);

   double sum = 0.0;
   int    n   = 0;
   for(int d = 1; d <= AsiaAvgDays; d++)
     {
      double hi, lo;
      if(AsiaRange(today - d * 86400, hi, lo) && hi > lo)
        {
         sum += (hi - lo) / PipSize();
         n++;
        }
     }
   gAsiaAvgDay  = today;
   gAsiaAvgPips = (n > 0 ? sum / n : 0.0);
   return(gAsiaAvgPips);
  }

//+------------------------------------------------------------------+
// Un sweep = un extreme depasse puis referme a l'interieur. On compte les
// excursions completes, pas les barres : une sortie qui dure cinq bougies
// avant de rentrer reste un seul sweep.
int CountSweeps(datetime from, datetime to, double hiLevel, double loLevel,
                int &upSweeps, int &dnSweeps)
  {
   upSweeps = 0;
   dnSweeps = 0;

   int b1 = iBarShift(_Symbol, PERIOD_CURRENT, from, false);
   int b2 = iBarShift(_Symbol, PERIOD_CURRENT, to,   false);
   if(b1 < 0 || b2 < 0)
      return(0);

   int start = MathMax(b1, b2);      // plus ancienne
   int end   = MathMin(b1, b2);      // plus recente
   int count = start - end + 1;
   if(count <= 0)
      return(0);

   // Une copie groupee plutot que trois appels par barre : sur des dizaines
   // de barres et a chaque rafraichissement, l'ecart est considerable.
   double h[], l[], c[];
   if(CopyHigh (_Symbol, PERIOD_CURRENT, end, count, h) < count) return(0);
   if(CopyLow  (_Symbol, PERIOD_CURRENT, end, count, l) < count) return(0);
   if(CopyClose(_Symbol, PERIOD_CURRENT, end, count, c) < count) return(0);

   bool pendUp = false, pendDn = false;
   for(int i = 0; i < count; i++)        // ordre chronologique
     {
      if(h[i] > hiLevel)             pendUp = true;
      if(pendUp && c[i] < hiLevel) { upSweeps++; pendUp = false; }

      if(l[i] < loLevel)             pendDn = true;
      if(pendDn && c[i] > loLevel) { dnSweeps++; pendDn = false; }
     }
   return(upSweeps + dnSweeps);
  }

//+------------------------------------------------------------------+
// Trace SL / TP1 / TP2 sur le graphique. Les niveaux figes sont pleins,
// la projection vivante est pointillee : on voit d'un coup d'oeil si
// l'objectif affiche est un point fixe ou une valeur qui bouge.
void DrawSignalLines(bool frozen, double tp1, double tp2, double sl)
  {
   string keep[];
   if(!ShowSignalLines)
     {
      PruneObjects(PFX"lvl_", keep);
      return;
     }

   ENUM_LINE_STYLE st = frozen ? STYLE_SOLID : STYLE_DOT;
   string suffix = frozen ? "" : " (proj.)";

   string names[3] = {PFX"lvl_sl", PFX"lvl_tp1", PFX"lvl_tp2"};
   double vals[3];
   vals[0] = sl; vals[1] = tp1; vals[2] = tp2;
   color  cols[3] = {clrTomato, clrLightGreen, clrLime};
   string labs[3] = {"SL", "TP1", "TP2"};

   for(int i = 0; i < 3; i++)
     {
      if(vals[i] <= 0.0)
         continue;
      if(ObjectFind(0, names[i]) < 0)
         ObjectCreate(0, names[i], OBJ_HLINE, 0, 0, vals[i]);
      else
         ObjectMove(0, names[i], 0, 0, vals[i]);
      ObjectSetInteger(0, names[i], OBJPROP_COLOR, cols[i]);
      ObjectSetInteger(0, names[i], OBJPROP_STYLE, st);
      ObjectSetInteger(0, names[i], OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, names[i], OBJPROP_BACK, true);
      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, false);
      ObjectSetString (0, names[i], OBJPROP_TEXT, labs[i] + suffix);
      KeepName(keep, names[i]);
     }
   PruneObjects(PFX"lvl_", keep);
  }

//+------------------------------------------------------------------+
// Swings de la période courante, du plus récent au plus ancien.
void CollectSwings(int lookback, int depth, double &swHigh[], double &swLow[])
  {
   ArrayResize(swHigh, 0);
   ArrayResize(swLow,  0);

   int need = lookback + depth * 2 + 2;
   double h[], l[];
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, need, h) < need) return;
   if(CopyLow (_Symbol, PERIOD_CURRENT, 0, need, l) < need) return;
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
// SELL : stop au-dessus du dernier plus haut, cibles sur les plus bas
// précédents. BUY : l'inverse. Renvoie false si la structure ne fournit
// pas de niveau exploitable — mieux vaut n'afficher rien qu'un chiffre inventé.
bool StructureLevels(int dir, double price, double &sl, double &tp1, double &tp2)
  {
   sl = 0.0; tp1 = 0.0; tp2 = 0.0;

   double swH[], swL[];
   CollectSwings(LevelsLookback, LevelsDepth, swH, swL);
   double buf = SL_BufferPips * PipSize();

   if(dir < 0)
     {
      for(int i = 0; i < ArraySize(swH); i++)
         if(swH[i] > price) { sl = swH[i] + buf; break; }
      for(int i = 0; i < ArraySize(swL); i++)
         if(swL[i] < price) { tp1 = swL[i]; break; }
      if(tp1 > 0.0)
         for(int i = 0; i < ArraySize(swL); i++)
            if(swL[i] < tp1) { tp2 = swL[i]; break; }
     }
   else
     {
      for(int i = 0; i < ArraySize(swL); i++)
         if(swL[i] < price) { sl = swL[i] - buf; break; }
      for(int i = 0; i < ArraySize(swH); i++)
         if(swH[i] > price) { tp1 = swH[i]; break; }
      if(tp1 > 0.0)
         for(int i = 0; i < ArraySize(swH); i++)
            if(swH[i] > tp1) { tp2 = swH[i]; break; }
     }
   return(sl > 0.0 && tp1 > 0.0);
  }

//+------------------------------------------------------------------+
// Numérote les swings de la fenêtre du jour et les marque d'une flèche.
// Un swing n'est acquis que ConfirmDepth bougies après son sommet : les
// flèches apparaissent donc avec ce retard, comme toute lecture de structure.
void BuildConfirmPoints()
  {
   string keep[];
   gConfHighs = 0; gConfLows = 0; gConfState = 0; gConfLast = "";

   if(!ShowConfirmPoints || !IntradayTF())
     {
      PruneObjects(PFX"cp_", keep);
      return;
     }

   datetime day  = BeninDayStart();
   datetime from = day + HHMMToSeconds(ConfirmWindowStart);
   datetime to   = day + HHMMToSeconds(ConfirmWindowEnd);
   if(to <= from || TimeCurrent() < from)
     {
      PruneObjects(PFX"cp_", keep);
      return;
     }
   if(to > TimeCurrent())
      to = TimeCurrent();

   int bFrom = iBarShift(_Symbol, PERIOD_CURRENT, from, false);
   int bTo   = iBarShift(_Symbol, PERIOD_CURRENT, to,   false);
   if(bFrom < 0 || bTo < 0)
     {
      PruneObjects(PFX"cp_", keep);
      return;
     }

   double firstHigh = 0.0, lastHigh = 0.0, firstLow = 0.0, lastLow = 0.0;

   for(int i = MathMax(bFrom, bTo); i >= MathMin(bFrom, bTo); i--)
     {
      if(i < ConfirmDepth)
         continue;                       // sommet pas encore confirmé
      double h = iHigh(_Symbol, PERIOD_CURRENT, i);
      double l = iLow (_Symbol, PERIOD_CURRENT, i);
      bool isH = true, isL = true;
      for(int k = 1; k <= ConfirmDepth; k++)
        {
         if(h <= iHigh(_Symbol, PERIOD_CURRENT, i-k) || h <= iHigh(_Symbol, PERIOD_CURRENT, i+k)) isH = false;
         if(l >= iLow (_Symbol, PERIOD_CURRENT, i-k) || l >= iLow (_Symbol, PERIOD_CURRENT, i+k)) isL = false;
        }
      if(!isH && !isL)
         continue;

      datetime t = iTime(_Symbol, PERIOD_CURRENT, i);
      if(isH)
        {
         gConfHighs++;
         if(gConfHighs == 1) firstHigh = h;
         lastHigh = h;
         string nm = StringFormat("%scp_H%d_%d", PFX, gConfHighs, (int)t);
         if(ObjectFind(0, nm) < 0)
            ObjectCreate(0, nm, OBJ_ARROW, 0, t, h);
         else
            ObjectMove(0, nm, 0, t, h);
         ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, 242);      // flèche bas
         ObjectSetInteger(0, nm, OBJPROP_COLOR, clrRed);
         ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetString (0, nm, OBJPROP_TOOLTIP, StringFormat("HIGH #%d", gConfHighs));
         KeepName(keep, nm);
        }
      if(isL)
        {
         gConfLows++;
         if(gConfLows == 1) firstLow = l;
         lastLow = l;
         string nm = StringFormat("%scp_L%d_%d", PFX, gConfLows, (int)t);
         if(ObjectFind(0, nm) < 0)
            ObjectCreate(0, nm, OBJ_ARROW, 0, t, l);
         else
            ObjectMove(0, nm, 0, t, l);
         ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, 241);      // flèche haut
         ObjectSetInteger(0, nm, OBJPROP_COLOR, clrLime);
         ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
         ObjectSetInteger(0, nm, OBJPROP_ANCHOR, ANCHOR_TOP);
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetString (0, nm, OBJPROP_TOOLTIP, StringFormat("LOW #%d", gConfLows));
         KeepName(keep, nm);
        }
     }

   if(gConfHighs >= 2 && lastHigh < firstHigh)
     { gConfState = -1; gConfLast = StringFormat("HIGH #%d < #1", gConfHighs); }
   else if(gConfLows >= 2 && lastLow > firstLow)
     { gConfState = +1; gConfLast = StringFormat("LOW #%d > #1", gConfLows); }

   PruneObjects(PFX"cp_", keep);
  }

//+------------------------------------------------------------------+
string BiasText(int bias)
  {
   if(bias > 0) return("HAUSSIER");
   if(bias < 0) return("BAISSIER");
   return("NEUTRE");
  }

color BiasColor(int bias)
  {
   if(bias > 0) return(BullishColor);
   if(bias < 0) return(BearishColor);
   return(clrSilver);
  }

//+------------------------------------------------------------------+
// Returns the name of the currently active session, or "" if none
string ActiveSessionName()
  {
   int sod = SecondsOfDay(BeninTime());
   SessionDef sessions[];
   GetSessions(sessions);
   for(int i = 0; i < ArraySize(sessions); i++)
     {
      if(sod >= sessions[i].startSec && sod < sessions[i].endSec)
         return(sessions[i].name);
     }
   return("");
  }

//+------------------------------------------------------------------+
void CreatePanel()
  {
   if(ObjectFind(0, PANEL_BG) < 0)
     {
      ObjectCreate(0, PANEL_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_XDISTANCE, PanelX);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_YDISTANCE, PanelY);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_XSIZE, 260);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_BGCOLOR, PanelBgColor);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_BACK, false);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, PANEL_BG, OBJPROP_COLOR, clrGray);
     }
  }

//+------------------------------------------------------------------+
// Drop labels left over from a taller previous render and size the
// background to whatever the panel actually drew this pass.
void FinishPanel(int lineCount)
  {
   for(int i = lineCount; i < panelLineCount; i++)
      ObjectDelete(0, PANEL_PREFIX + IntegerToString(i));
   panelLineCount = lineCount;
   ObjectSetInteger(0, PANEL_BG, OBJPROP_YSIZE, 16 + lineCount * 16);
  }

//+------------------------------------------------------------------+
void SetPanelLine(int idx, string text, color clr)
  {
   string name = PANEL_PREFIX + IntegerToString(idx);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, PanelX + 8);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelY + 8 + idx * 16);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
// Tout ce qui lit des barres est regroupe ici et ne tourne qu'une fois par
// bougie. UpdatePanel se contente ensuite de mettre en page.
void RefreshContext()
  {
   double rsiBuf[1], atrBuf[1];
   if(CopyBuffer(hRSI,     0, 0, 1, rsiBuf) < 1) rsiBuf[0] = 0;
   if(CopyBuffer(hATR_M15, 0, 0, 1, atrBuf) < 1) atrBuf[0] = 0;
   gCtxRSI = rsiBuf[0];
   gCtxATR = atrBuf[0];

   gCtxBiasM15 = ComputeBias(PERIOD_M15);
   gCtxBiasH4  = ComputeBias(PERIOD_H4);

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dir   = (gCtxBiasM15 != 0) ? gCtxBiasM15 : gCtxBiasH4;
   gCtxSL = 0.0; gCtxTP1 = 0.0; gCtxTP2 = 0.0;
   StructureLevels(dir, price, gCtxSL, gCtxTP1, gCtxTP2);

   datetime dayStart = BeninDayStart();
   gCtxRangeHi = 0.0; gCtxRangeLo = 0.0;
   GetRangeHighLow(dayStart, TimeCurrent(), gCtxRangeHi, gCtxRangeLo);

   gCtxAsiaValid = false; gCtxAsiaDone = false;
   gCtxAsiaPips  = 0.0;   gCtxAsiaRatio = 0.0;
   gCtxSwUp = 0; gCtxSwDn = 0; gCtxSwTot = 0;

   if(ShowAsiaStats && IntradayTF())
     {
      double asiaHi = 0.0, asiaLo = 0.0;
      gCtxAsiaDone  = (SecondsOfDay(BeninTime()) >= HHMMToSeconds(AsiaEnd));
      gCtxAsiaValid = (AsiaRange(dayStart, asiaHi, asiaLo) && asiaHi > asiaLo);
      if(gCtxAsiaValid)
        {
         gCtxAsiaPips = (asiaHi - asiaLo) / PipSize();
         double avg   = AsiaAvgCached();
         gCtxAsiaRatio = (avg > 0.0 ? gCtxAsiaPips / avg : 0.0);
         if(gCtxAsiaDone)
            gCtxSwTot = CountSweeps(dayStart + HHMMToSeconds(AsiaEnd), TimeCurrent(),
                                    asiaHi, asiaLo, gCtxSwUp, gCtxSwDn);
        }
     }
  }

//+------------------------------------------------------------------+
void UpdatePanel()
  {
   datetime curBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(curBar != gCtxBar)
     {
      gCtxBar = curBar;
      RefreshContext();
     }

   int    biasM15 = gCtxBiasM15,  biasH4 = gCtxBiasH4;
   double atr = gCtxATR, rsi = gCtxRSI;
   bool   asiaValid = gCtxAsiaValid, asiaDone = gCtxAsiaDone;
   double asiaPips  = gCtxAsiaPips,  asiaRatio = gCtxAsiaRatio;
   int    swUp = gCtxSwUp, swDn = gCtxSwDn, swTot = gCtxSwTot;

   // Seuls le prix et la session se rafraichissent a chaque tick : ni l'un
   // ni l'autre ne lit de barres.
   string activeSession = ActiveSessionName();
   bool sessionActive = (activeSession != "");
   bool aligned = (biasM15 != 0 && biasM15 == biasH4);
   bool entryAllowed = aligned && sessionActive;

   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int dir = (biasM15 != 0) ? biasM15 : biasH4;
   int sgn = (dir >= 0) ? 1 : -1;

   double liveSL = gCtxSL, liveTP1 = gCtxTP1, liveTP2 = gCtxTP2;

   // Journal: one line per transition INTO the allowed state, at most one per
   // bar. gLastLoggedBar also survives a reload, so re-attaching the indicator
   // while a signal still stands does not duplicate it.
   if(entryAllowed && gPrevSignalDir != dir)
     {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(barTime > gLastLoggedBar)
        {
         // Les niveaux sont fixes une fois pour toutes ici, au prix du signal.
         gSigTime  = barTime;
         gSigDir   = dir;
         gSigPrice = price;
         gSigATR   = atr;
         gSigTP1   = liveTP1;
         gSigTP2   = liveTP2;
         gSigSL    = liveSL;

         if(LogSignals)
            LogSignal(barTime, dir, price, atr, gSigTP1, gSigTP2, gSigSL,
                      activeSession, biasM15, biasH4, rsi,
                      asiaPips, asiaRatio, swUp, swDn);
        }
     }
   gPrevSignalDir = entryAllowed ? dir : 0;

   // Ce qui est affiche : les niveaux figes si un signal en a produit,
   // sinon la projection vivante.
   bool   frozen = (FreezeLevels && gSigTime > 0);
   double tp1 = frozen ? gSigTP1 : liveTP1;
   double tp2 = frozen ? gSigTP2 : liveTP2;
   double sl  = frozen ? gSigSL  : liveSL;

   DrawSignalLines(frozen, tp1, tp2, sl);

   double   rangeHi  = gCtxRangeHi, rangeLo = gCtxRangeLo;
   datetime beninNow = BeninTime();

   int line = 0;
   SetPanelLine(line++, _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period), PanelTextColor);
   SetPanelLine(line++, TimeToString(beninNow, TIME_DATE|TIME_MINUTES) + " (Bénin)", clrSilver);
   SetPanelLine(line++, "Session: " + (sessionActive ? activeSession : "aucune"), sessionActive ? clrYellow : clrSilver);
   SetPanelLine(line++, StringFormat("Range H:%s L:%s", DoubleToString(rangeHi, digits), DoubleToString(rangeLo, digits)), clrSilver);
   SetPanelLine(line++, " ", clrSilver);
   SetPanelLine(line++, "Biais M15: " + BiasText(biasM15), BiasColor(biasM15));
   SetPanelLine(line++, "Biais H4:  " + BiasText(biasH4), BiasColor(biasH4));
   // ATR affiche aussi en pips : c'est l'unite utilisee dans les analyses
   // publiees, ca evite une conversion mentale a chaque comparaison.
   SetPanelLine(line++, StringFormat("RSI(%d): %.1f  ATR: %s (%d p)",
                RSIPeriod, rsi, DoubleToString(atr, digits),
                (int)MathRound(atr / PipSize())), clrSilver);

   if(ShowConfirmPoints && (gConfHighs > 0 || gConfLows > 0))
     {
      SetPanelLine(line++, StringFormat("Fenêtre %04d-%04d: %dH / %dB",
                   ConfirmWindowStart, ConfirmWindowEnd, gConfHighs, gConfLows), clrSilver);
      if(gConfState != 0)
         SetPanelLine(line++, StringFormat("  %s → %s", gConfLast,
                      gConfState < 0 ? "BAISSIER" : "HAUSSIER"),
                      gConfState < 0 ? BearishColor : BullishColor);
      else
         SetPanelLine(line++, "  pas de confirmation", clrGray);
     }

   if(ShowAsiaStats && asiaValid)
     {
      if(asiaRatio > 0.0)
         SetPanelLine(line++, StringFormat("Asie: %d pips  (x%.2f moy %dj)",
                      (int)MathRound(asiaPips), asiaRatio, AsiaAvgDays), clrSilver);
      else
         SetPanelLine(line++, StringFormat("Asie: %d pips", (int)MathRound(asiaPips)), clrSilver);

      if(!asiaDone)
         SetPanelLine(line++, "  asiatique en cours", clrGray);
      else if(asiaRatio >= AsiaExpandedRatio && asiaRatio > 0.0)
         SetPanelLine(line++, "  EXPANSEE", clrOrange);
      else if(asiaRatio > 0.0)
         SetPanelLine(line++, "  NON EXPANSEE", clrSilver);

      if(asiaDone)
         SetPanelLine(line++, StringFormat("Sweeps: %d  (haut %d / bas %d)", swTot, swUp, swDn),
                      swTot > 0 ? clrYellow : clrSilver);
      else
         SetPanelLine(line++, "Sweeps: -", clrGray);
     }

   if(ShowZones)
     {
      SetPanelLine(line++, " ", clrSilver);
      double zHi, zLo, dist;

      if(NearestZone(true, price, zHi, zLo, dist))
         SetPanelLine(line++, StringFormat("Offre   %s-%s  (%d pips)",
                      DoubleToString(zLo, digits), DoubleToString(zHi, digits), (int)MathRound(dist)), ColorSupply);
      else
         SetPanelLine(line++, "Offre   : aucune au-dessus", clrGray);

      if(NearestZone(false, price, zHi, zLo, dist))
         SetPanelLine(line++, StringFormat("Demande %s-%s  (%d pips)",
                      DoubleToString(zLo, digits), DoubleToString(zHi, digits), (int)MathRound(dist)), ColorDemand);
      else
         SetPanelLine(line++, "Demande : aucune en dessous", clrGray);

      if(PriceInZone(true, price))
         SetPanelLine(line++, "Prix DANS une zone d'OFFRE", ColorSupply);
      else if(PriceInZone(false, price))
         SetPanelLine(line++, "Prix DANS une zone de DEMANDE", ColorDemand);
     }

   SetPanelLine(line++, " ", clrSilver);
   if(frozen)
      SetPanelLine(line++, StringFormat("Niveaux figés — signal %s",
                   TimeToString(gSigTime, TIME_MINUTES)), clrAqua);
   else
      SetPanelLine(line++, "Projection (aucun signal figé)", clrGray);

   string slLab = (sgn < 0) ? "dernier haut" : "dernier bas";
   string tpLab = (sgn < 0) ? "plus bas"      : "plus haut";

   SetPanelLine(line++, sl  > 0.0 ? StringFormat("SL  %s  (%s)",  DoubleToString(sl,  digits), slLab)
                                  : "SL  : structure absente", sl  > 0.0 ? clrTomato : clrGray);
   SetPanelLine(line++, tp1 > 0.0 ? StringFormat("TP1 %s  (%s préc.)", DoubleToString(tp1, digits), tpLab)
                                  : "TP1 : structure absente", tp1 > 0.0 ? clrSilver : clrGray);
   SetPanelLine(line++, tp2 > 0.0 ? StringFormat("TP2 %s  (%s -2)",    DoubleToString(tp2, digits), tpLab)
                                  : "TP2 : aucun second swing", tp2 > 0.0 ? clrSilver : clrGray);
   SetPanelLine(line++, entryAllowed ? (">>> ENTREE AUTORISEE " + (dir > 0 ? "LONG" : "SHORT") + " <<<") : "En attente...",
                entryAllowed ? (dir > 0 ? BullishColor : BearishColor) : clrGray);

   FinishPanel(line);
  }
