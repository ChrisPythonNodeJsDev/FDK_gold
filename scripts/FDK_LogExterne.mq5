//+------------------------------------------------------------------+
//| FDK_LogExterne.mq5                                               |
//| Enregistre un signal reçu d'une source externe, au même format    |
//| que nos propres signaux, pour pouvoir le mesurer plus tard.       |
//|                                                                   |
//| Aucune source n'est créditée a priori : on enregistre, on attend  |
//| l'échantillon, on mesure. Le rapport gain/risque est calculé ici  |
//| parce que c'est l'information qui manque presque toujours.        |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property script_show_inputs

enum ESens { SENS_ACHAT, SENS_VENTE };

input string Source     = "financier";  // Nom de la source
input ESens  Sens       = SENS_VENTE;
input double PrixEntree = 0.0;
input double StopLoss   = 0.0;
input double TP1        = 0.0;
input double TP2        = 0.0;          // 0 = non fourni
input double TP3        = 0.0;          // 0 = non fourni
input string Note       = "";
input int    OffsetBenin = 1;           // Heures à ajouter à l'heure serveur

//+------------------------------------------------------------------+
double PipSize()
  {
   if(_Digits == 2 || _Digits == 3 || _Digits == 5)
      return(_Point * 10);
   return(_Point);
  }

//+------------------------------------------------------------------+
double RatioVers(double tp, double entree, double risque, int sens)
  {
   if(tp <= 0.0 || risque <= 0.0)
      return(0.0);
   double gain = (sens > 0) ? (tp - entree) : (entree - tp);
   return(gain > 0.0 ? gain / risque : 0.0);
  }

//+------------------------------------------------------------------+
void OnStart()
  {
   int sens = (Sens == SENS_ACHAT) ? 1 : -1;

   if(PrixEntree <= 0.0 || StopLoss <= 0.0 || TP1 <= 0.0)
     {
      Print("FDK_Externe: entrée, stop et TP1 sont obligatoires.");
      return;
     }
   // Un stop du mauvais côté est une erreur de saisie, pas une stratégie.
   if((sens > 0 && StopLoss >= PrixEntree) || (sens < 0 && StopLoss <= PrixEntree))
     {
      PrintFormat("FDK_Externe: stop %s du mauvais côté pour un %s.",
                  DoubleToString(StopLoss, _Digits),
                  sens > 0 ? "achat" : "vente");
      return;
     }

   double risque = MathAbs(PrixEntree - StopLoss);
   double pip    = PipSize();
   double r1 = RatioVers(TP1, PrixEntree, risque, sens);
   double r2 = RatioVers(TP2, PrixEntree, risque, sens);
   double r3 = RatioVers(TP3, PrixEntree, risque, sens);

   double atr = 0.0;
   int h = iATR(_Symbol, PERIOD_M15, 14);
   if(h != INVALID_HANDLE)
     {
      double buf[1];
      if(CopyBuffer(h, 0, 0, 1, buf) >= 1) atr = buf[0];
     }

   string fname = "FDK_externes_" + _Symbol + ".csv";
   bool neuf = !FileIsExist(fname);

   int fh = FileOpen(fname, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
     {
      PrintFormat("FDK_Externe: ouverture de %s impossible (err %d)", fname, GetLastError());
      return;
     }
   if(neuf)
      FileWrite(fh, "horodatage_benin", "source", "symbole", "sens", "entree",
                "sl", "tp1", "tp2", "tp3", "risque_pips",
                "rr_tp1", "rr_tp2", "rr_tp3", "prix_au_depot", "atr", "note");
   FileSeek(fh, 0, SEEK_END);

   FileWrite(fh,
             TimeToString(TimeCurrent() + OffsetBenin*3600, TIME_DATE|TIME_SECONDS),
             Source, _Symbol, sens > 0 ? "ACHAT" : "VENTE",
             DoubleToString(PrixEntree, _Digits),
             DoubleToString(StopLoss,   _Digits),
             DoubleToString(TP1, _Digits),
             TP2 > 0.0 ? DoubleToString(TP2, _Digits) : "",
             TP3 > 0.0 ? DoubleToString(TP3, _Digits) : "",
             DoubleToString(risque / pip, 0),
             DoubleToString(r1, 2),
             r2 > 0.0 ? DoubleToString(r2, 2) : "",
             r3 > 0.0 ? DoubleToString(r3, 2) : "",
             DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits),
             DoubleToString(atr, _Digits),
             Note);
   FileClose(fh);

   PrintFormat("FDK_Externe: %s %s enregistré — risque %.0f pips, R:R TP1 %.2f"
               " (équilibre à %.0f%%)",
               Source, sens > 0 ? "ACHAT" : "VENTE", risque / pip, r1,
               r1 > 0.0 ? 100.0 / (1.0 + r1) : 0.0);
  }
