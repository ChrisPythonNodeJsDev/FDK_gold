//+------------------------------------------------------------------+
//| FDK_ExportData.mq5                                               |
//| Exporte les bougies du symbole courant vers MQL5/Files en CSV,   |
//| pour analyse hors ligne (backtest).                              |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property script_show_inputs

input int    BarsM15 = 30000;   // Bougies M15 à exporter
input int    BarsH4  = 6000;    // Bougies H4 à exporter
input string Suffixe = "";      // Suffixe optionnel dans le nom de fichier

//+------------------------------------------------------------------+
bool ExportTF(ENUM_TIMEFRAMES tf, int count, string label)
  {
   MqlRates r[];
   ArraySetAsSeries(r, false);            // chronological: oldest first

   int got = CopyRates(_Symbol, tf, 0, count, r);
   if(got <= 0)
     {
      PrintFormat("FDK_Export: aucune donnée %s (err %d). Fais défiler le "
                  "graphique vers la gauche pour charger l'historique.",
                  label, GetLastError());
      return(false);
     }

   string fname = StringFormat("FDK_%s_%s%s.csv", _Symbol, label, Suffixe);
   int h = FileOpen(fname, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
     {
      PrintFormat("FDK_Export: FileOpen %s échoué (err %d)", fname, GetLastError());
      return(false);
     }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   FileWrite(h, "time_server", "open", "high", "low", "close", "tick_volume");
   for(int i = 0; i < got; i++)
      FileWrite(h,
                TimeToString(r[i].time, TIME_DATE|TIME_SECONDS),
                DoubleToString(r[i].open,  digits),
                DoubleToString(r[i].high,  digits),
                DoubleToString(r[i].low,   digits),
                DoubleToString(r[i].close, digits),
                (string)r[i].tick_volume);
   FileClose(h);

   PrintFormat("FDK_Export: %s -> %s (%d bougies, du %s au %s)",
               label, fname, got,
               TimeToString(r[0].time, TIME_DATE|TIME_MINUTES),
               TimeToString(r[got-1].time, TIME_DATE|TIME_MINUTES));
   return(true);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   PrintFormat("FDK_Export: symbole %s, décalage serveur->GMT %d s",
               _Symbol, (int)(TimeCurrent() - TimeGMT()));
   bool a = ExportTF(PERIOD_M15, BarsM15, "M15");
   bool b = ExportTF(PERIOD_H4,  BarsH4,  "H4");
   if(a && b)
      Print("FDK_Export: terminé. Fichiers dans MQL5/Files.");
  }
