//+------------------------------------------------------------------+
//| FDK_Garde.mq5                                                     |
//|                                                                   |
//| Garde-fou pour le challenge Bridge Prop « Startup Afrique         |
//| Synthetic 2-Step », compte de 2 500 USD sur indices synthétiques.  |
//|                                                                   |
//| CE PROGRAMME N'OUVRE AUCUNE POSITION ET N'ÉMET AUCUN SIGNAL.       |
//| Il surveille le compte et applique mécaniquement les règles qui    |
//| peuvent l'être. Les mesures du 2 octobre 2026 sont sans appel :    |
//| sur ces instruments le biais de structure n'a aucune valeur        |
//| prédictive (|t| <= 0.92 sur six séries) et la volatilité est       |
//| identique aux 24 heures du cadran à 2,0 % près. Il n'y a donc rien |
//| à prédire ici — mais il y a tout à protéger, et les six erreurs    |
//| recensées dans le protocole sont, pour cinq d'entre elles,         |
//| purement mécaniques.                                               |
//|                                                                   |
//| La sixième — savoir quand entrer — reste entièrement humaine.      |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

//--- Les cinq nombres du règlement, en valeurs absolues.
input group "=== Seuils du règlement (USD) ==="
input double SoldeInitial        = 2500.0;  // Solde à l'achat du challenge
input double SeuilDrawdown       = 2375.0;  // Violation : consomme un cycle sur trois
input double SeuilDisqualif      = 2250.0;  // Mort définitive du compte
input double PerteJournaliereMax = 125.0;   // Limite dure de la journée
input double ArretJournalier     = 90.0;    // Arrêt volontaire, bien avant la limite
input double AlerteJournaliere   = 75.0;    // Premier avertissement
input double RisqueParTrade      = 12.50;   // Plafond par trade

//--- La journée de trading bascule à 19 h en Colombie (UTC-5), soit
//--- minuit UTC pile, soit 01 h 00 au Bénin. On raisonne donc en UTC,
//--- ce qui évite toute question de fuseau et de changement d'heure.
input group "=== Journée de trading ==="
input int    HeureClotureUTC     = 22;      // Clôture générale (22 h UTC = 23 h Bénin)
input bool   ClotureAvantBascule = true;    // Ne jamais franchir minuit UTC en position

//--- Dimensionnement : le lot suit l'ATR pour que le risque reste
//--- constant, mais sa variation est bornée plus étroitement que ne
//--- l'exige le règlement (0,50x à 2,00x la moyenne courante).
input group "=== Dimensionnement ==="
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_M15;
input int    ATR_Periode         = 14;
input double StopEnATR           = 1.5;     // Distance du stop, en multiples d'ATR
input double LotRatioMin         = 0.65;    // Marge interne sous le 0,50 du règlement
input double LotRatioMax         = 1.55;    // Marge interne sous le 2,00 du règlement

input group "=== Protection des positions ==="
input bool   PoserStopManquant   = true;    // Attacher un SL aux positions qui n'en ont pas
input double SeuilUrgence        = 110.0;   // Au-delà, on ferme même avant 2 minutes
input long   MagicSurveille      = 0;       // 0 = toutes les positions du symbole

input group "=== Affichage et journal ==="
input bool   AfficherPanneau     = true;
input string FichierJournal      = "";      // vide = FDK_garde_<symbole>.csv

//+------------------------------------------------------------------+
#define PFX "FDKGARDE_"
#define DUREE_MIN_SECONDES 120              // Règle 04 : 2 minutes minimum

CTrade  gTrade;
int     gATR = INVALID_HANDLE;

datetime gJourUTC      = 0;      // minuit UTC de la journée en cours
double   gEquityDebut  = 0.0;    // equity à la bascule
double   gLotDuJour    = 0.0;    // figé une fois par journée
double   gStopDuJour   = 0.0;    // distance en prix correspondante
bool     gBloque       = false;  // plus aucune ouverture tolérée aujourd'hui
string   gMotifBlocage = "";
double   gMoyenneLots  = 0.0;    // moyenne des lots déjà passés sur ce symbole
int      gNbLots       = 0;

//+------------------------------------------------------------------+
string Journal()
  {
   if(StringLen(FichierJournal) > 0)
      return(FichierJournal);
   return("FDK_garde_" + _Symbol + ".csv");
  }

//+------------------------------------------------------------------+
void Noter(const string evenement, const string detail)
  {
   string f = Journal();
   bool neuf = !FileIsExist(f);
   int h = FileOpen(f, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   if(neuf)
      FileWrite(h, "horodatage_utc", "symbole", "evenement", "detail",
                "equity", "perte_du_jour", "distance_2375", "lot_du_jour");
   FileWrite(h,
             TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS),
             _Symbol, evenement, detail,
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(gEquityDebut - AccountInfoDouble(ACCOUNT_EQUITY), 2),
             DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY) - SeuilDrawdown, 2),
             DoubleToString(gLotDuJour, 3));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Moyenne des volumes déjà engagés sur ce symbole. Le règlement     |
//| compare chaque nouveau lot à cette moyenne, et elle survit aux    |
//| redémarrages : on la relit dans l'historique plutôt que de la     |
//| garder en mémoire.                                                |
//+------------------------------------------------------------------+
void RelireMoyenneLots()
  {
   gMoyenneLots = 0.0; gNbLots = 0;
   if(!HistorySelect(TimeCurrent() - 90 * 86400, TimeCurrent() + 3600))
      return;
   double somme = 0.0;
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if(HistoryDealGetString(t, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      somme += HistoryDealGetDouble(t, DEAL_VOLUME);
      gNbLots++;
     }
   if(gNbLots > 0)
      gMoyenneLots = somme / gNbLots;
  }

//+------------------------------------------------------------------+
//| Le lot du jour, et la distance de stop qui lui correspond.         |
//|                                                                   |
//| On vise un risque de RisqueParTrade exactement. Le lot suit donc  |
//| l'inverse de l'ATR. Quand le bornage mord, c'est le STOP qui       |
//| s'ajuste et non le lot : le règlement encadre le volume, il        |
//| n'encadre pas la distance du stop.                                 |
//+------------------------------------------------------------------+
bool CalculerLotDuJour(double &lot, double &stopPrix, string &note)
  {
   double atr[1];
   if(gATR == INVALID_HANDLE || CopyBuffer(gATR, 0, 0, 1, atr) < 1 || atr[0] <= 0.0)
     {
      note = "ATR indisponible";
      return(false);
     }

   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vpas = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lvl  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;

   if(tv <= 0.0 || ts <= 0.0 || vpas <= 0.0)
     {
      note = "fiche du symbole illisible";
      return(false);
     }

   stopPrix = StopEnATR * atr[0];
   if(stopPrix < lvl)
      stopPrix = lvl;                       // jamais sous le minimum du courtier

   double risqueParLot = stopPrix / ts * tv;
   if(risqueParLot <= 0.0) { note = "risque par lot nul"; return(false); }

   lot = RisqueParTrade / risqueParLot;

   // Bornage interne par rapport à la moyenne déjà engagée.
   bool borne = false;
   if(gNbLots >= 5 && gMoyenneLots > 0.0)
     {
      double bas = gMoyenneLots * LotRatioMin;
      double haut = gMoyenneLots * LotRatioMax;
      if(lot < bas)  { lot = bas;  borne = true; }
      if(lot > haut) { lot = haut; borne = true; }
     }

   // Bornage par le courtier, puis alignement VERS LE BAS sur le pas :
   // sur un plafond, on n'arrondit jamais au plus proche.
   if(lot > vmax) { lot = vmax; borne = true; }
   lot = MathFloor(lot / vpas) * vpas;
   lot = NormalizeDouble(lot, 3);

   if(lot < vmin)
     {
      note = StringFormat("lot minimum %.3f impose %.2f USD, plafond %.2f",
                          vmin, vmin * risqueParLot, RisqueParTrade);
      return(false);                        // symbole inutilisable sur ce compte
     }

   // Le lot ayant pu être borné ou arrondi, on recale le stop pour que
   // le produit retombe exactement sur le risque voulu.
   stopPrix = RisqueParTrade * ts / (lot * tv);
   if(stopPrix < lvl)
     {
      stopPrix = lvl;
      note = "stop ramené au minimum courtier — risque réel sous le plafond";
     }
   else if(borne)
      note = StringFormat("lot borné, stop recalé à %.2f x ATR", stopPrix / atr[0]);
   else
      note = StringFormat("stop %.2f x ATR", stopPrix / atr[0]);

   return(true);
  }

//+------------------------------------------------------------------+
int NbPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(MagicSurveille != 0
         && PositionGetInteger(POSITION_MAGIC) != MagicSurveille) continue;
      n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
//| Ferme tout ce qui traîne. Une position de moins de deux minutes   |
//| ne peut pas être clôturée sans violer la règle 04 : on attend,    |
//| SAUF si la perte du jour approche la limite dure, auquel cas on   |
//| choisit la violation la moins chère et on l'écrit dans le journal.|
//+------------------------------------------------------------------+
int ToutFermer(const string motif, const bool urgence)
  {
   int fermees = 0, differees = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(MagicSurveille != 0
         && PositionGetInteger(POSITION_MAGIC) != MagicSurveille) continue;

      long ouverture = PositionGetInteger(POSITION_TIME);
      long age = (long)TimeCurrent() - ouverture;
      if(age < DUREE_MIN_SECONDES && !urgence)
        {
         differees++;
         continue;
        }
      if(age < DUREE_MIN_SECONDES && urgence)
         Noter("CONFLIT_REGLES",
               StringFormat("fermeture a %ld s (<120) pour eviter la limite journaliere", age));

      if(gTrade.PositionClose(t))
         fermees++;
      else
         Noter("ECHEC_FERMETURE", StringFormat("ticket %I64u err %d", t, gTrade.ResultRetcode()));
     }
   if(fermees > 0)
      Noter("FERMETURE", StringFormat("%s — %d position(s)", motif, fermees));
   if(differees > 0)
      Noter("FERMETURE_DIFFEREE",
            StringFormat("%s — %d position(s) de moins de 2 min", motif, differees));
   return(fermees);
  }

//+------------------------------------------------------------------+
//| Règle 03 : toute position doit porter un stop dans les 2 minutes. |
//| On n'attend pas la limite — on le pose dès qu'on voit la position.|
//+------------------------------------------------------------------+
void PoserStops()
  {
   if(!PoserStopManquant || gStopDuJour <= 0.0)
      return;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(MagicSurveille != 0
         && PositionGetInteger(POSITION_MAGIC) != MagicSurveille) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double ouvre = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = (type == POSITION_TYPE_BUY) ? ouvre - gStopDuJour
                                                 : ouvre + gStopDuJour;
      sl = NormalizeDouble(sl, digits);
      double tp = PositionGetDouble(POSITION_TP);
      long age = (long)TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);

      if(gTrade.PositionModify(t, sl, tp))
         Noter("STOP_POSE", StringFormat("ticket %I64u a %.*f, %ld s apres l'ouverture",
                                         t, digits, sl, age));
      else
         Noter("STOP_REFUSE", StringFormat("ticket %I64u err %d — POSE-LE A LA MAIN",
                                           t, gTrade.ResultRetcode()));
     }
  }

//+------------------------------------------------------------------+
void Ligne(const int idx, const string texte, const color clr)
  {
   string nom = PFX + IntegerToString(idx);
   if(ObjectFind(0, nom) < 0)
     {
      ObjectCreate(0, nom, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nom, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, nom, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, nom, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetString (0, nom, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nom, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, nom, OBJPROP_SELECTABLE, false);
     }
   ObjectSetInteger(0, nom, OBJPROP_YDISTANCE, 16 + idx * 15);
   ObjectSetString (0, nom, OBJPROP_TEXT, texte == "" ? " " : texte);
   ObjectSetInteger(0, nom, OBJPROP_COLOR, clr);
  }

//+------------------------------------------------------------------+
void Panneau()
  {
   if(!AfficherPanneau)
      return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double perte = gEquityDebut - eq;
   double marge = eq - SeuilDrawdown;
   int l = 0;

   Ligne(l++, "GARDE-FOU  " + _Symbol, clrWhite);
   Ligne(l++, StringFormat("equity        %10.2f", eq), clrSilver);
   Ligne(l++, StringFormat("au plancher   %10.2f", marge),
         marge < 25.0 ? clrRed : (marge < 60.0 ? clrOrange : clrLightGreen));
   Ligne(l++, StringFormat("perte du jour %10.2f / %.0f", perte, ArretJournalier),
         perte >= ArretJournalier ? clrRed
                                  : (perte >= AlerteJournaliere ? clrOrange : clrLightGreen));
   Ligne(l++, " ", clrSilver);
   if(gLotDuJour > 0.0)
     {
      Ligne(l++, StringFormat("lot du jour   %10.3f", gLotDuJour), clrAqua);
      Ligne(l++, StringFormat("stop          %10.*f",
            (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), gStopDuJour), clrAqua);
      Ligne(l++, StringFormat("risque        %10.2f", RisqueParTrade), clrAqua);
     }
   else
      Ligne(l++, "lot du jour   indisponible", clrRed);
   if(gNbLots >= 5)
      Ligne(l++, StringFormat("moyenne lots  %10.3f", gMoyenneLots), clrSilver);
   Ligne(l++, " ", clrSilver);
   Ligne(l++, StringFormat("positions     %10d", NbPositions()), clrSilver);
   Ligne(l++, StringFormat("bascule a     %10s", "00:00 UTC"), clrSilver);
   Ligne(l++, gBloque ? ">> BLOQUE : " + gMotifBlocage : ">> surveillance active",
         gBloque ? clrRed : clrLightGreen);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   gTrade.SetExpertMagicNumber(0);
   gTrade.SetTypeFillingBySymbol(_Symbol);
   gATR = iATR(_Symbol, ATR_TF, ATR_Periode);
   if(gATR == INVALID_HANDLE)
     {
      Print("FDK_Garde: ATR indisponible, err ", GetLastError());
      return(INIT_FAILED);
     }
   RelireMoyenneLots();
   gJourUTC = 0;                            // force le calcul au premier tick
   EventSetTimer(5);
   Noter("DEMARRAGE", StringFormat("seuils %.0f / %.0f, arret du jour %.0f",
                                   SeuilDrawdown, SeuilDisqualif, ArretJournalier));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   if(gATR != INVALID_HANDLE)
      IndicatorRelease(gATR);
  }

//+------------------------------------------------------------------+
void OnTimer() { Surveiller(); }
void OnTick()  { Surveiller(); }

//+------------------------------------------------------------------+
void Surveiller()
  {
   datetime utc = TimeGMT();
   datetime jour = utc - (utc % 86400);     // minuit UTC = bascule Bridge

   // --- bascule de journée ---
   if(jour != gJourUTC)
     {
      gJourUTC     = jour;
      gEquityDebut = AccountInfoDouble(ACCOUNT_EQUITY);
      gBloque      = false;
      gMotifBlocage = "";
      RelireMoyenneLots();
      string note = "";
      double lot = 0.0, stop = 0.0;
      if(CalculerLotDuJour(lot, stop, note))
        {
         gLotDuJour = lot; gStopDuJour = stop;
         Noter("NOUVELLE_JOURNEE",
               StringFormat("equity %.2f, lot %.3f, stop %.*f — %s",
                            gEquityDebut, lot,
                            (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), stop, note));
        }
      else
        {
         gLotDuJour = 0.0; gStopDuJour = 0.0;
         gBloque = true; gMotifBlocage = "dimensionnement impossible";
         Noter("DIMENSIONNEMENT_IMPOSSIBLE", note);
        }
     }

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double perte = gEquityDebut - eq;

   // --- règle 03 : stop sur toute position qui n'en a pas ---
   PoserStops();

   // --- règle 01 : le plancher, limite opérationnelle absolue ---
   if(eq <= SeuilDrawdown + 15.0 && NbPositions() > 0)
     {
      ToutFermer("approche du plancher 2375", eq <= SeuilDrawdown + 5.0);
      gBloque = true; gMotifBlocage = "plancher 2375 approche";
     }

   // --- règle 02 : la limite journalière ---
   if(perte >= ArretJournalier && NbPositions() > 0)
     {
      ToutFermer(StringFormat("arret du jour a %.2f", perte),
                 perte >= SeuilUrgence);
      gBloque = true; gMotifBlocage = StringFormat("perte du jour %.0f", perte);
     }
   else if(perte >= AlerteJournaliere && !gBloque)
      gMotifBlocage = "alerte 75 franchie";

   // --- erreur n°1 : la position laissée ouverte ---
   int heureUTC = (int)((utc % 86400) / 3600);
   if(ClotureAvantBascule && heureUTC >= HeureClotureUTC && NbPositions() > 0)
     {
      ToutFermer(StringFormat("cloture programmee %02d:00 UTC", HeureClotureUTC), false);
      gBloque = true; gMotifBlocage = "journee close";
     }

   Panneau();
  }
//+------------------------------------------------------------------+
