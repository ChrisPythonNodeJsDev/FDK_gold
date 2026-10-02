//+------------------------------------------------------------------+
//| FDK_Garde.mq5                                                     |
//|                                                                   |
//| Garde-fou pour le challenge Bridge Prop « Startup Afrique         |
//| Synthetic 2-Step » sur indices synthétiques.                      |
//|                                                                   |
//| CE PROGRAMME N'OUVRE AUCUNE POSITION ET N'ÉMET AUCUN SIGNAL.       |
//| Il surveille le compte et applique mécaniquement les règles qui    |
//| peuvent l'être. Les mesures du 2 octobre 2026 sont sans appel :    |
//| sur ces instruments le biais de structure n'a aucune valeur        |
//| prédictive (|t| <= 0.92 sur six séries) et la volatilité est       |
//| identique aux 24 heures du cadran à 2,0 % près. Il n'y a rien à    |
//| prédire ici — mais il y a tout à protéger, et cinq des six erreurs |
//| recensées dans le protocole sont purement mécaniques.              |
//|                                                                   |
//| La sixième — savoir quand entrer — reste entièrement humaine.      |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

//--- Les seuils sont exprimés en POURCENTAGE du solde initial, non en
//--- dollars : la démo Bridge est dotée de 10 000 USD alors que le compte
//--- d'évaluation en vaudra 2 500. Figer 2 375 en dur rendait les deux
//--- semaines de simulation exigées par le protocole sans rapport avec
//--- le challenge réel. SoldeInitial à 0 prend le solde du compte.
input group "=== Seuils du règlement (% du solde initial) ==="
input double SoldeInitial   = 0.0;   // 0 = lire le solde du compte au démarrage
input double PctDrawdown    = 5.0;   // Violation : consomme un cycle sur trois
input double PctDisqualif   = 10.0;  // Mort définitive du compte
input double PctPerteJour   = 5.0;   // Limite dure de la journée
input double PctArretJour   = 3.6;   // Arrêt volontaire  (90 USD sur 2 500)
input double PctAlerteJour  = 3.0;   // Premier avertissement (75 sur 2 500)
input double PctUrgence     = 4.4;   // Au-delà, on ferme même avant 2 minutes
input double PctRisqueTrade = 0.5;   // Plafond par trade (12,50 sur 2 500)
//--- Règle « idée de trading » : plusieurs opérations sur le MÊME actif,
//--- dans la MÊME direction, à moins de 30 minutes d'écart, comptent pour
//--- une seule idée dont le risque cumulé est plafonné à 2 %.
input double PctIdeeMax     = 2.0;   // Plafond par idée (50 sur 2 500)
input int    IdeeFenetreMin = 30;    // Minutes regroupant les opérations

//--- La journée de trading bascule à 19 h en Colombie (UTC-5), soit
//--- minuit UTC pile, soit 01 h 00 au Bénin. Tout est calculé en UTC :
//--- plus aucune question de fuseau ni de changement d'heure.
input group "=== Journée de trading ==="
input int    HeureClotureUTC     = 22;    // 22 h UTC = 23 h Bénin
input bool   ClotureAvantBascule = true;  // Ne jamais franchir minuit UTC en position

input group "=== Dimensionnement ==="
input ENUM_TIMEFRAMES ATR_TF = PERIOD_M15;
input int    ATR_Periode     = 14;
input double StopEnATR       = 1.5;   // Distance du stop, en multiples d'ATR
input double LotRatioMin     = 0.65;  // Marge interne sous le 0,50 du règlement
input double LotRatioMax     = 1.55;  // Marge interne sous le 2,00 du règlement

input group "=== Protection des positions ==="
input bool   PoserStopManquant = true; // Attacher un SL aux positions qui n'en ont pas
input long   MagicSurveille    = 0;    // 0 = toutes les positions du symbole

//--- Alerter à l'expiration des deux minutes reviendrait à annoncer la
//--- violation au lieu de l'éviter. L'alerte part donc dès que la
//--- position est vue sans stop, et se répète jusqu'à ce qu'il y soit.
input group "=== Alarmes ==="
input bool   AlerteImmediate  = true;  // Alerter dès l'ouverture d'une position sans SL
input bool   AlerteSonore     = true;  // Fenêtre Alert() + son
input bool   AlertePush       = true;  // Notification sur le téléphone (MetaQuotes ID)
input int    RappelSecondes   = 20;    // Intervalle entre deux rappels
input int    SecondesCritique = 105;   // Dernière sommation avant les 120 s
input int    PreavisClotureMin = 15;   // Préavis avant l'heure de clôture (minutes)
//--- La perte journalière et le plancher sont des limites de COMPTE.
//--- Avec une instance par symbole, chacune crierait le même
//--- franchissement : on ne l'active que sur un seul graphique.
input bool   AlarmesCompte    = true;  // Alarmes de compte — UN SEUL graphique

input group "=== Affichage et journal ==="
input bool   AfficherPanneau = true;
input string FichierJournal  = "";    // vide = FDK_garde_<symbole>.csv

//+------------------------------------------------------------------+
#define PFX "FDKGARDE_"
#define DUREE_MIN_SECONDES 120        // Règle 04 : 2 minutes minimum
#define RAPPEL_ECHEC_SEC   300        // Un refus qui dure se renote toutes les 5 min

CTrade gTrade;
int    gATR = INVALID_HANDLE;

//--- Seuils en valeur absolue, dérivés du solde au démarrage.
double gSolde = 0.0, gPlancher = 0.0, gDisqualif = 0.0;
double gPerteMax = 0.0, gArret = 0.0, gAlerte = 0.0, gUrgence = 0.0, gRisque = 0.0;
double gIdeeMax  = 0.0;
bool   gIdeeCriee[2];          // 0 = achat, 1 = vente
string gIdeeEcran[2];

datetime gJourUTC     = 0;     // minuit UTC de la journée en cours
double   gEquityDebut = 0.0;
double   gLotDuJour   = 0.0;   // indicatif : ce que TU devrais engager
double   gStopDuJour  = 0.0;   // distance correspondant à ce lot
bool     gBloque      = false;
string   gMotif       = "";
double   gMoyenneLots = 0.0;
int      gNbLots      = 0;

//--- Suivi des positions vues sans stop : une entrée par ticket, pour
//--- savoir quand on l'a repérée et quand on a rappelé pour la dernière
//--- fois. Le compte à rebours des 120 secondes part de l'OUVERTURE de la
//--- position, pas du moment où on la découvre.
#define MAX_SUIVI 16
ulong    gSuiviTicket[MAX_SUIVI];
datetime gSuiviDernier[MAX_SUIVI];
bool     gSuiviCritique[MAX_SUIVI];
bool     gSuiviViole[MAX_SUIVI];
int      gSuiviN = 0;
string   gCompteARebours = "";

//--- Seuils de perte déjà criés aujourd'hui, pour ne hurler qu'une fois
//--- par palier franchi. Remis à zéro à la bascule de minuit UTC.
bool     gPerteCriee[4];      // 0 alerte, 1 arret, 2 urgence, 3 limite dure
bool     gPlancherCrie = false;
datetime gDernierRappelPerte = 0;
int      gPreavisCrie  = 0;   // 0 aucun, 1 preavis, 2 cinq min, 3 une min, 4 depassee
string   gCompteCloture = "";

//--- Anti-répétition : un refus qui revient toutes les deux secondes
//--- écrivait soixante lignes identiques par minute dans le journal.
ulong    gEchecTicket = 0;
uint     gEchecCode   = 0;
datetime gEchecVu     = 0;
string   gAlerteEcran = "";

//+------------------------------------------------------------------+
string Journal()
  {
   if(StringLen(FichierJournal) > 0) return(FichierJournal);
   return("FDK_garde_" + _Symbol + ".csv");
  }

//+------------------------------------------------------------------+
void Noter(const string evenement, const string detail)
  {
   string f = Journal();
   bool neuf = !FileIsExist(f);
   int h = FileOpen(f, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   if(neuf)
      FileWrite(h, "horodatage_utc", "symbole", "evenement", "detail",
                "equity", "resultat_du_jour", "distance_plancher", "lot_du_jour");
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   FileWrite(h, TimeToString(TimeGMT(), TIME_DATE|TIME_SECONDS),
             _Symbol, evenement, detail,
             DoubleToString(eq, 2),
             DoubleToString(eq - gEquityDebut, 2),
             DoubleToString(eq - gPlancher, 2),
             DoubleToString(gLotDuJour, 3));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Pourquoi le terminal refuse-t-il d'agir ? Le code 10027 seul ne   |
//| dit rien à la lecture ; ces trois interrupteurs disent tout.      |
//+------------------------------------------------------------------+
string RaisonBlocageTrading()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return("AutoTrading desactive dans le terminal (bouton de la barre)");
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return("Trading auto refuse pour CET expert (proprietes, onglet Commun)");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      return("Le courtier interdit les experts sur ce compte");
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
      return("Trading desactive sur le compte");
   return("");
  }

//+------------------------------------------------------------------+
//| Résultat réalisé depuis la bascule, tous symboles confondus.      |
//| La limite journalière est une limite de COMPTE : un trade perdant |
//| sur un autre indice compte autant qu'ici.                          |
//+------------------------------------------------------------------+
double RealiseDuJour(const datetime debutJour)
  {
   double somme = 0.0;
   if(!HistorySelect(debutJour, TimeCurrent() + 3600))
      return(0.0);
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      if((datetime)HistoryDealGetInteger(t, DEAL_TIME) < debutJour) continue;
      somme += HistoryDealGetDouble(t, DEAL_PROFIT)
             + HistoryDealGetDouble(t, DEAL_SWAP)
             + HistoryDealGetDouble(t, DEAL_COMMISSION);
     }
   return(somme);
  }

//+------------------------------------------------------------------+
void RelireMoyenneLots()
  {
   gMoyenneLots = 0.0; gNbLots = 0;
   if(!HistorySelect(TimeCurrent() - 90 * 86400, TimeCurrent() + 3600)) return;
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
   if(gNbLots > 0) gMoyenneLots = somme / gNbLots;
  }

//+------------------------------------------------------------------+
//| Risque en dollars d'un écart de prix donné, pour un volume donné. |
//+------------------------------------------------------------------+
double RisqueDe(const double ecartPrix, const double volume)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0.0 || ts <= 0.0) return(0.0);
   return(ecartPrix / ts * tv * volume);
  }

//+------------------------------------------------------------------+
//| L'écart de prix qui fait exactement gRisque pour ce volume.       |
//| Jamais sous la distance minimale imposée par le courtier.         |
//+------------------------------------------------------------------+
double StopPourVolume(const double volume)
  {
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double lvl = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   if(tv <= 0.0 || ts <= 0.0 || volume <= 0.0) return(0.0);
   double ecart = gRisque * ts / (volume * tv);
   return(MathMax(ecart, lvl));
  }

//+------------------------------------------------------------------+
//| Le lot que TU devrais engager aujourd'hui, et son stop.           |
//| Purement indicatif : l'EA n'ouvre rien, il affiche la valeur.     |
//+------------------------------------------------------------------+
bool CalculerLotDuJour(double &lot, double &stopPrix, string &note)
  {
   double atr[1];
   if(gATR == INVALID_HANDLE || CopyBuffer(gATR, 0, 0, 1, atr) < 1 || atr[0] <= 0.0)
     { note = "ATR indisponible"; return(false); }

   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vpas = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double lvl  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   if(vpas <= 0.0) { note = "fiche du symbole illisible"; return(false); }

   stopPrix = MathMax(StopEnATR * atr[0], lvl);
   double parLot = RisqueDe(stopPrix, 1.0);
   if(parLot <= 0.0) { note = "risque par lot nul"; return(false); }

   lot = gRisque / parLot;

   bool borne = false;
   if(gNbLots >= 5 && gMoyenneLots > 0.0)
     {
      double bas = gMoyenneLots * LotRatioMin, haut = gMoyenneLots * LotRatioMax;
      if(lot < bas)  { lot = bas;  borne = true; }
      if(lot > haut) { lot = haut; borne = true; }
     }
   if(lot > vmax) { lot = vmax; borne = true; }

   // Sur un plafond, on arrondit toujours VERS LE BAS.
   lot = NormalizeDouble(MathFloor(lot / vpas) * vpas, 3);
   if(lot < vmin)
     {
      note = StringFormat("lot minimum %.3f impose %.2f USD pour un plafond de %.2f",
                          vmin, RisqueDe(stopPrix, vmin), gRisque);
      return(false);
     }

   stopPrix = StopPourVolume(lot);
   if(borne) note = StringFormat("lot borne, stop recale a %.2f x ATR", stopPrix / atr[0]);
   else      note = StringFormat("stop %.2f x ATR", stopPrix / atr[0]);
   return(true);
  }

//+------------------------------------------------------------------+
bool Surveillee(const ulong ticket)
  {
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return(false);
   if(MagicSurveille != 0
      && PositionGetInteger(POSITION_MAGIC) != MagicSurveille) return(false);
   return(true);
  }

//+------------------------------------------------------------------+
int NbPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t != 0 && Surveillee(t)) n++;
     }
   return(n);
  }

//+------------------------------------------------------------------+
//| Positions ouvertes sur l'ensemble du compte, tous symboles.       |
//| Les alarmes de compte doivent annoncer le bon nombre, pas         |
//| seulement celles du graphique où tourne cette instance.           |
//+------------------------------------------------------------------+
int NbPositionsCompte()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetTicket(i) != 0) n++;
   return(n);
  }

//+------------------------------------------------------------------+
//| Ferme tout. Une position de moins de deux minutes ne peut pas     |
//| être clôturée sans violer la règle 04 : on attend, SAUF si la     |
//| perte du jour approche la limite dure, auquel cas on choisit la   |
//| violation la moins chère et on l'écrit dans le journal.           |
//+------------------------------------------------------------------+
void ToutFermer(const string motif, const bool urgence)
  {
   int fermees = 0, differees = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Surveillee(t)) continue;
      long age = (long)TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);
      if(age < DUREE_MIN_SECONDES && !urgence) { differees++; continue; }
      if(age < DUREE_MIN_SECONDES && urgence)
         Noter("CONFLIT_REGLES",
               StringFormat("fermeture a %ld s (<120) pour eviter la limite journaliere", age));
      if(gTrade.PositionClose(t)) fermees++;
      else Noter("ECHEC_FERMETURE",
                 StringFormat("ticket %I64u err %u — FERME-LA A LA MAIN",
                              t, gTrade.ResultRetcode()));
     }
   if(fermees > 0)
      Noter("FERMETURE", StringFormat("%s — %d position(s)", motif, fermees));
   if(differees > 0)
      Noter("FERMETURE_DIFFEREE",
            StringFormat("%s — %d position(s) de moins de 2 min", motif, differees));
  }

//+------------------------------------------------------------------+
//| Règle 03 : toute position doit porter un stop dans les 2 minutes. |
//|                                                                   |
//| Le stop est calculé à partir du VOLUME RÉEL de la position, pas   |
//| du lot que l'EA recommande. Le 2 octobre, une position ouverte à  |
//| la main en 1,0 lot recevait le stop calculé pour 2,1 lots : la    |
//| distance était bonne pour un autre volume, donc le risque faux.   |
//+------------------------------------------------------------------+
void PoserStops()
  {
   if(!PoserStopManquant) return;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Surveillee(t)) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      double vol = PositionGetDouble(POSITION_VOLUME);
      double ecart = StopPourVolume(vol);
      if(ecart <= 0.0) continue;

      long   type  = PositionGetInteger(POSITION_TYPE);
      double ouvre = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = NormalizeDouble((type == POSITION_TYPE_BUY) ? ouvre - ecart
                                                              : ouvre + ecart, digits);
      long age = (long)TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);

      if(gTrade.PositionModify(t, sl, PositionGetDouble(POSITION_TP)))
        {
         Noter("STOP_POSE",
               StringFormat("ticket %I64u vol %.3f -> SL %.*f (%.2f USD) a %ld s",
                            t, vol, digits, sl, RisqueDe(ecart, vol), age));
         if(gEchecTicket == t) { gEchecTicket = 0; gEchecCode = 0; gAlerteEcran = ""; }
        }
      else
        {
         uint code = gTrade.ResultRetcode();
         string pourquoi = RaisonBlocageTrading();
         gAlerteEcran = (pourquoi != "") ? pourquoi
                                         : StringFormat("SL refuse, err %u", code);
         // On ne renote pas le même refus toutes les deux secondes.
         bool nouveau = (t != gEchecTicket || code != gEchecCode
                         || TimeCurrent() - gEchecVu >= RAPPEL_ECHEC_SEC);
         if(nouveau)
           {
            gEchecTicket = t; gEchecCode = code; gEchecVu = TimeCurrent();
            Noter("STOP_REFUSE",
                  StringFormat("ticket %I64u err %u — %s — SL voulu %.*f, POSE-LE A LA MAIN",
                               t, code,
                               pourquoi != "" ? pourquoi : "cause inconnue",
                               digits, sl));
           }
        }
     }
  }

//+------------------------------------------------------------------+
void Crier(const string titre, const string corps, const bool fort)
  {
   string m = titre + " — " + corps;
   if(AlerteSonore && fort)
      Alert(m);                           // fenêtre + son, impossible à manquer
   else if(AlerteSonore)
      PlaySound("alert.wav");
   if(AlertePush && TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      SendNotification(_Symbol + " : " + m);
   Print("FDK_Garde: ", m);
  }

//+------------------------------------------------------------------+
int IndexSuivi(const ulong ticket)
  {
   for(int i = 0; i < gSuiviN; i++)
      if(gSuiviTicket[i] == ticket) return(i);
   if(gSuiviN >= MAX_SUIVI) return(-1);
   gSuiviTicket[gSuiviN]   = ticket;
   gSuiviDernier[gSuiviN]  = 0;
   gSuiviCritique[gSuiviN] = false;
   gSuiviViole[gSuiviN]    = false;
   gSuiviN++;
   return(gSuiviN - 1);
  }

//+------------------------------------------------------------------+
void OublierSuivi(const ulong ticket)
  {
   for(int i = 0; i < gSuiviN; i++)
      if(gSuiviTicket[i] == ticket)
        {
         for(int j = i; j < gSuiviN - 1; j++)
           {
            gSuiviTicket[j]   = gSuiviTicket[j+1];
            gSuiviDernier[j]  = gSuiviDernier[j+1];
            gSuiviCritique[j] = gSuiviCritique[j+1];
            gSuiviViole[j]    = gSuiviViole[j+1];
           }
         gSuiviN--;
         return;
        }
  }

//+------------------------------------------------------------------+
//| Règle 03 surveillée à la seconde. Le compte à rebours part de     |
//| l'ouverture de la position : au moment où on la découvre, une     |
//| partie des 120 secondes est déjà consommée.                       |
//+------------------------------------------------------------------+
void VeillerStops()
  {
   gCompteARebours = "";
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // Oublier les tickets qui ne sont plus à découvert.
   for(int i = gSuiviN - 1; i >= 0; i--)
     {
      ulong t = gSuiviTicket[i];
      if(!PositionSelectByTicket(t) || PositionGetDouble(POSITION_SL) > 0.0)
        {
         if(PositionSelectByTicket(t))
            Noter("STOP_CONSTATE", StringFormat("ticket %I64u protege", t));
         OublierSuivi(t);
        }
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Surveillee(t)) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      double vol   = PositionGetDouble(POSITION_VOLUME);
      double ecart = StopPourVolume(vol);
      long   type  = PositionGetInteger(POSITION_TYPE);
      double ouvre = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = NormalizeDouble((type == POSITION_TYPE_BUY) ? ouvre - ecart
                                                              : ouvre + ecart, digits);
      long age     = (long)TimeCurrent() - (long)PositionGetInteger(POSITION_TIME);
      long restant = DUREE_MIN_SECONDES - age;

      int k = IndexSuivi(t);
      if(k < 0) continue;
      bool premier = (gSuiviDernier[k] == 0);

      gCompteARebours = StringFormat("SANS STOP — %lds — SL %.*f", restant, digits, sl);

      // Message unique, répété : il contient le prix à taper.
      string corps = StringFormat("%.2f lot sans stop. Tape SL %.*f (%.2f USD). %lds restantes",
                                  vol, digits, sl, RisqueDe(ecart, vol), restant);

      if(premier && AlerteImmediate)
        {
         Crier("STOP MANQUANT", corps, true);
         Noter("ALERTE_SANS_STOP",
               StringFormat("ticket %I64u vol %.2f, SL a taper %.*f, %lds restantes",
                            t, vol, digits, sl, restant));
         gSuiviDernier[k] = TimeCurrent();
         continue;
        }

      if(restant <= (DUREE_MIN_SECONDES - SecondesCritique) && !gSuiviCritique[k] && restant > 0)
        {
         gSuiviCritique[k] = true;
         Crier("DERNIERE SOMMATION", corps, true);
         gSuiviDernier[k] = TimeCurrent();
         continue;
        }

      if(restant <= 0 && !gSuiviViole[k])
        {
         gSuiviViole[k] = true;
         Crier("REGLE 03 VIOLEE", StringFormat("%.2f lot ouvert depuis %lds sans stop", vol, age), true);
         Noter("VIOLATION_REGLE_03",
               StringFormat("ticket %I64u sans stop a %lds — un cycle sur trois consomme", t, age));
         gSuiviDernier[k] = TimeCurrent();
         continue;
        }

      if(TimeCurrent() - gSuiviDernier[k] >= RappelSecondes)
        {
         Crier("stop toujours absent", corps, false);
         gSuiviDernier[k] = TimeCurrent();
        }
     }
  }

//+------------------------------------------------------------------+
//| Risque cumulé d'une idée de trading : même symbole, même sens.    |
//|                                                                   |
//| Le risque de chaque position se mesure sur SON stop réel. Une      |
//| position encore sans stop est comptée au stop qu'elle devrait      |
//| avoir — sinon une entrée non protégée ferait paraître l'idée plus  |
//| sage qu'elle ne l'est, exactement au mauvais moment.               |
//+------------------------------------------------------------------+
double RisqueIdee(const long sens, int &nb)
  {
   double somme = 0.0; nb = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || !Surveillee(t)) continue;
      if(PositionGetInteger(POSITION_TYPE) != sens) continue;
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double ouvre = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble(POSITION_SL);
      double ecart = (sl > 0.0) ? MathAbs(ouvre - sl) : StopPourVolume(vol);
      somme += RisqueDe(ecart, vol);
      nb++;
     }
   return(somme);
  }

//+------------------------------------------------------------------+
//| Alarme 4 — le plafond de l'idée de trading.                       |
//|                                                                   |
//| Lecture prudente : on SOMME le risque des positions ouvertes dans  |
//| le même sens sur le même actif. Le règlement dit ailleurs que le   |
//| risque « sera mesuré en fonction du risque le plus élevé défini    |
//| par le stop loss », ce qui se lirait comme un maximum et non une   |
//| somme. Les deux lectures ne donnent pas le même chiffre : tant     |
//| que le support n'a pas tranché, on prend la plus sévère.           |
//+------------------------------------------------------------------+
void VeillerIdee()
  {
   long sens[2] = {POSITION_TYPE_BUY, POSITION_TYPE_SELL};
   string noms[2] = {"ACHAT", "VENTE"};
   for(int k = 0; k < 2; k++)
     {
      int nb = 0;
      double r = RisqueIdee(sens[k], nb);
      if(nb == 0)
        {
         gIdeeCriee[k] = false;
         gIdeeEcran[k] = "";
         continue;
        }
      gIdeeEcran[k] = StringFormat("idee %-5s %7.2f / %.2f  (%d)",
                                   noms[k], r, gIdeeMax, nb);
      if(r >= gIdeeMax && !gIdeeCriee[k])
        {
         gIdeeCriee[k] = true;
         string corps = StringFormat("%d position(s) %s cumulent %.2f USD, plafond %.2f",
                                     nb, noms[k], r, gIdeeMax);
         Crier("PLAFOND D IDEE ATTEINT", corps, true);
         Noter("ALERTE_IDEE", corps);
        }
      else if(r < gIdeeMax * 0.9)
         gIdeeCriee[k] = false;          // réarmement une fois redescendu
     }
  }

//+------------------------------------------------------------------+
//| Alarme 2 — la perte de la journée.                                |
//|                                                                   |
//| Quatre paliers, criés une fois chacun. Quand plusieurs sont        |
//| franchis d'un coup — un gros mouvement contre une position — on    |
//| ne crie que le plus haut et on marque les autres comme passés,     |
//| sinon l'opérateur reçoit quatre fenêtres à empiler avant de        |
//| pouvoir agir.                                                      |
//+------------------------------------------------------------------+
void VeillerPerte()
  {
   if(!AlarmesCompte) return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double perte = gEquityDebut - eq;
   double marge = eq - gPlancher;

   // Le plancher d'abord : c'est le seuil qui consomme un cycle sur trois.
   if(marge <= gRisque * 2.0 && !gPlancherCrie)
     {
      gPlancherCrie = true;
      Crier("PLANCHER PROCHE",
            StringFormat("%.2f USD avant %.2f. Ferme tout et arrete la journee.",
                         marge, gPlancher), true);
      Noter("ALERTE_PLANCHER", StringFormat("marge %.2f USD", marge));
     }

   int niveau = -1;
   if(perte >= gPerteMax)      niveau = 3;
   else if(perte >= gUrgence)  niveau = 2;
   else if(perte >= gArret)    niveau = 1;
   else if(perte >= gAlerte)   niveau = 0;
   if(niveau < 0)
      return;

   string titres[4] = {"ALERTE PERTE", "ARRET DU JOUR", "URGENCE", "LIMITE JOURNALIERE"};
   double seuils[4];
   seuils[0] = gAlerte; seuils[1] = gArret; seuils[2] = gUrgence; seuils[3] = gPerteMax;

   for(int i = 0; i <= niveau; i++)
     {
      if(gPerteCriee[i]) continue;
      gPerteCriee[i] = true;
      if(i < niveau) continue;                 // marqué, mais pas crié
      string corps = StringFormat("perte du jour %.2f USD (seuil %.2f). %d position(s) ouverte(s).",
                                  perte, seuils[i], NbPositionsCompte());
      Crier(titres[i], corps, i >= 1);
      Noter(i >= 3 ? "VIOLATION_REGLE_02" : "ALERTE_PERTE", corps);
      gDernierRappelPerte = TimeCurrent();
     }

   // Tant qu'on reste au-dessus de l'arrêt, on rappelle.
   if(niveau >= 1 && TimeCurrent() - gDernierRappelPerte >= RappelSecondes
      && NbPositionsCompte() > 0)
     {
      gDernierRappelPerte = TimeCurrent();
      Crier("journee a arreter",
            StringFormat("perte %.2f USD, %d position(s) encore ouverte(s)",
                         perte, NbPositionsCompte()), false);
     }
  }

//+------------------------------------------------------------------+
//| Alarme 3 — l'heure de clôture.                                    |
//|                                                                   |
//| C'est l'erreur n°1 du protocole : la position oubliee pendant la   |
//| nuit. Le preavis part quinze minutes avant, puis se resserre.      |
//+------------------------------------------------------------------+
void VeillerCloture()
  {
   gCompteCloture = "";
   if(!AlarmesCompte || !ClotureAvantBascule || NbPositionsCompte() == 0)
     {
      gPreavisCrie = 0;
      return;
     }

   int sec     = (int)(TimeGMT() % 86400);
   int cible   = HeureClotureUTC * 3600;
   int restant = cible - sec;

   int niveau = 0;
   if(restant <= 0)             niveau = 4;
   else if(restant <= 60)       niveau = 3;
   else if(restant <= 300)      niveau = 2;
   else if(restant <= PreavisClotureMin * 60) niveau = 1;
   if(niveau == 0)
      return;

   gCompteCloture = (restant > 0)
      ? StringFormat("cloture dans %d min %02d s", restant / 60, restant % 60)
      : "HEURE DE CLOTURE DEPASSEE";

   if(niveau <= gPreavisCrie)
      return;
   gPreavisCrie = niveau;

   string corps = (restant > 0)
      ? StringFormat("%d position(s) ouverte(s), cloture dans %d min %02d s",
                     NbPositionsCompte(), restant / 60, restant % 60)
      : StringFormat("%d position(s) encore ouverte(s) apres l'heure de cloture",
                     NbPositionsCompte());
   string titres[5] = {"", "PREAVIS DE CLOTURE", "CLOTURE DANS 5 MIN",
                       "CLOTURE DANS 1 MIN", "FERME MAINTENANT"};
   Crier(titres[niveau], corps, niveau >= 3);
   Noter("ALERTE_CLOTURE", corps);
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
   if(!AfficherPanneau) return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double perte = gEquityDebut - eq;
   double marge = eq - gPlancher;
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   int l = 0;

   Ligne(l++, "GARDE-FOU  " + _Symbol, clrWhite);
   if(gCompteARebours != "")
      Ligne(l++, ">> " + gCompteARebours, clrRed);
   if(gCompteCloture != "")
      Ligne(l++, ">> " + gCompteCloture, clrOrange);
   Ligne(l++, StringFormat("solde initial %10.2f", gSolde), clrSilver);
   Ligne(l++, StringFormat("plancher      %10.2f", gPlancher), clrSilver);
   Ligne(l++, StringFormat("equity        %10.2f", eq), clrSilver);
   Ligne(l++, StringFormat("au plancher   %10.2f", marge),
         marge < gRisque * 2 ? clrRed : (marge < gRisque * 5 ? clrOrange : clrLightGreen));
   // Le résultat porte son signe naturel : un gain s'affiche en gain.
   double resultat = -perte;
   Ligne(l++, StringFormat("resultat jour %+10.2f", resultat),
         resultat >= 0.0 ? clrLightGreen : (perte >= gAlerte ? clrOrange : clrSilver));
   // Et ce qui compte vraiment : ce qu'il reste à perdre avant l'arrêt.
   double reste = gArret - perte;
   Ligne(l++, StringFormat("avant l arret %10.2f", reste),
         reste <= 0.0 ? clrRed : (reste <= gRisque * 2.0 ? clrOrange : clrLightGreen));
   Ligne(l++, " ", clrSilver);
   if(gLotDuJour > 0.0)
     {
      Ligne(l++, StringFormat("lot conseille %10.3f", gLotDuJour), clrAqua);
      Ligne(l++, StringFormat("stop          %10.*f", d, gStopDuJour), clrAqua);
      Ligne(l++, StringFormat("risque max    %10.2f", gRisque), clrAqua);
     }
   else
      Ligne(l++, "lot conseille  indisponible", clrRed);
   if(gNbLots >= 5)
      Ligne(l++, StringFormat("moyenne lots  %10.3f", gMoyenneLots), clrSilver);
   Ligne(l++, " ", clrSilver);
   Ligne(l++, StringFormat("positions     %10d", NbPositions()), clrSilver);
   for(int k = 0; k < 2; k++)
      if(gIdeeEcran[k] != "")
        {
         int nb = 0;
         double r = RisqueIdee(k == 0 ? POSITION_TYPE_BUY : POSITION_TYPE_SELL, nb);
         Ligne(l++, gIdeeEcran[k],
               r >= gIdeeMax ? clrRed : (r >= gIdeeMax * 0.8 ? clrOrange : clrSilver));
        }
   Ligne(l++, "bascule a        00:00 UTC", clrSilver);
   Ligne(l++, AlarmesCompte ? "alarmes de compte : ICI"
                            : "alarmes de compte : ailleurs",
         AlarmesCompte ? clrAqua : clrGray);
   if(AlertePush && !TerminalInfoInteger(TERMINAL_NOTIFICATIONS_ENABLED))
      Ligne(l++, "push inactif : MetaQuotes ID absent", clrOrange);
   if(gAlerteEcran != "")
      Ligne(l++, ">> " + gAlerteEcran, clrRed);
   else
      Ligne(l++, gBloque ? ">> BLOQUE : " + gMotif : ">> surveillance active",
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
     { Print("FDK_Garde: ATR indisponible, err ", GetLastError()); return(INIT_FAILED); }

   gSolde = (SoldeInitial > 0.0) ? SoldeInitial : AccountInfoDouble(ACCOUNT_BALANCE);
   gPlancher  = gSolde * (1.0 - PctDrawdown   / 100.0);
   gDisqualif = gSolde * (1.0 - PctDisqualif  / 100.0);
   gPerteMax  = gSolde * PctPerteJour   / 100.0;
   gArret     = gSolde * PctArretJour   / 100.0;
   gAlerte    = gSolde * PctAlerteJour  / 100.0;
   gUrgence   = gSolde * PctUrgence     / 100.0;
   gRisque    = gSolde * PctRisqueTrade / 100.0;
   gIdeeMax   = gSolde * PctIdeeMax     / 100.0;

   RelireMoyenneLots();
   gJourUTC = 0;
   EventSetTimer(1);                      // le compte a rebours se joue a la seconde

   string pourquoi = RaisonBlocageTrading();
   if(pourquoi != "")
     {
      gAlerteEcran = pourquoi;
      Noter("TRADING_BLOQUE", pourquoi);
     }
   Noter("DEMARRAGE",
         StringFormat("solde %.2f, plancher %.2f, disqualif %.2f, arret du jour %.2f, risque %.2f",
                      gSolde, gPlancher, gDisqualif, gArret, gRisque));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectsDeleteAll(0, PFX);
   if(gATR != INVALID_HANDLE) IndicatorRelease(gATR);
  }

//+------------------------------------------------------------------+
//| Une position peut naitre entre deux ticks sur un marche calme :    |
//| OnTradeTransaction fait partir l'alerte a la seconde ou elle       |
//| apparait, au lieu d'attendre le prochain passage du minuteur.      |
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD
      || trans.type == TRADE_TRANSACTION_POSITION)
      Surveiller();
  }

//+------------------------------------------------------------------+
void OnTimer() { Surveiller(); }
void OnTick()  { Surveiller(); }

//+------------------------------------------------------------------+
void Surveiller()
  {
   datetime utc  = TimeGMT();
   datetime jour = utc - (utc % 86400);      // minuit UTC = bascule Bridge

   if(jour != gJourUTC)
     {
      gJourUTC = jour;
      // Le solde au début de la journée, et non l'equity au moment où
      // l'EA est posé : attaché à 20 h après 200 USD de pertes, il
      // repartait de zéro et autorisait 358 USD de plus.
      gEquityDebut = AccountInfoDouble(ACCOUNT_BALANCE) - RealiseDuJour(jour);
      gBloque = false; gMotif = "";
      for(int i = 0; i < 4; i++) gPerteCriee[i] = false;
      gPlancherCrie = false; gPreavisCrie = 0; gDernierRappelPerte = 0;
      RelireMoyenneLots();
      string note = ""; double lot = 0.0, stop = 0.0;
      if(CalculerLotDuJour(lot, stop, note))
        {
         gLotDuJour = lot; gStopDuJour = stop;
         Noter("NOUVELLE_JOURNEE",
               StringFormat("equity %.2f, lot conseille %.3f, stop %.*f — %s",
                            gEquityDebut, lot,
                            (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS), stop, note));
        }
      else
        {
         gLotDuJour = 0.0; gStopDuJour = 0.0;
         Noter("DIMENSIONNEMENT_IMPOSSIBLE", note);
        }
     }

   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double perte = gEquityDebut - eq;

   // Quand le serveur refuse les experts, insister ne sert qu'a inonder le
   // journal : on bascule en veille et on alerte au lieu d'agir.
   if(RaisonBlocageTrading() == "")
      PoserStops();
   VeillerStops();
   VeillerIdee();
   VeillerPerte();
   VeillerCloture();

   if(eq <= gPlancher + gRisque && NbPositions() > 0)
     {
      ToutFermer("approche du plancher", eq <= gPlancher + gRisque * 0.4);
      gBloque = true; gMotif = StringFormat("plancher %.0f approche", gPlancher);
     }

   if(perte >= gArret && NbPositions() > 0)
     {
      ToutFermer(StringFormat("arret du jour a %.2f", perte), perte >= gUrgence);
      gBloque = true; gMotif = StringFormat("perte du jour %.2f", perte);
     }
   else if(perte >= gAlerte && !gBloque)
      gMotif = "alerte franchie";

   int heureUTC = (int)((utc % 86400) / 3600);
   if(ClotureAvantBascule && heureUTC >= HeureClotureUTC && NbPositions() > 0)
     {
      ToutFermer(StringFormat("cloture programmee %02d:00 UTC", HeureClotureUTC), false);
      gBloque = true; gMotif = "journee close";
     }

   Panneau();
  }
//+------------------------------------------------------------------+
