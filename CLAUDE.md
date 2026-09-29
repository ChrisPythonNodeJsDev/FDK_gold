# Contexte du projet

Indicateur MetaTrader 5 pour XAUUSD (or) sur compte démo Deriv, plus
l'outillage de backtest servant à mesurer ce qu'il vaut.

L'utilisateur est basé au Bénin (WAT, UTC+1) et échange en français.

## À savoir avant de proposer quoi que ce soit

**La règle d'entrée n'a aucun avantage statistique démontré.** Mesurée sur
15 mois de XAUUSD Deriv réel (30 000 bougies M15, 193 trades) : entre
−0.021 et −0.098 R par trade selon la gestion. Le balayage de paramètres
montre une espérance nulle dès que l'échantillon dépasse 400 trades.

Deux pistes ont été testées puis écartées :
- entrée sur retour en zone offre/demande : +0.062 R, t = 1.11, non
  significatif (423 trades)
- confirmation par points numérotés dans une fenêtre : perdante, tous les
  résultats hors échantillon négatifs, jusqu'à t = −3.0

La règle SL/TP par structure a un rapport gain/risque médian de **0.58** :
il faudrait 63 % de réussite pour l'équilibre, on en observe 52 à 62 %.

### Le seul résultat qui se soit reproduit

Simulateur MT5, biais par cassure de structure, 2024.01 → 2026.04 puis
2026.05 → 2026.09 (fenêtre choisie après coup, marché de sens inverse) :

| | en échantillon | hors échantillon |
|---|---|---|
| ensemble | +57.8 R (433 trades) | **−3.9 R** (111 trades) |
| AMD dans le sens du H4 | +0.31 R (n=40) | +0.94 R (n=9) |
| AMD à contresens du H4 | −0.39 R (n=37) | −0.62 R (n=13) |

L'avantage d'ensemble ne s'est pas reproduit : le gain venait de
l'exposition acheteuse pendant que l'or montait de 138 %. Forcer tous les
signaux dans le sens du marché bat la direction choisie par le
détecteur, dans les deux fenêtres.

Seule la séparation par le H4 tient : −0.452 R/trade sur les 50 trades à
contresens réunis, t = −2.66. D'où `ForbidH4Contre`, actif par défaut.
C'est un filtre qui retire des trades perdants, pas un avantage.

Ne pas présenter cet indicateur comme un générateur de signaux validé.
Ne pas donner de conseil de position, de niveau d'entrée ou de
dimensionnement : l'utilisateur trade en démo et décide seul.

## Méthode attendue

Toute hypothèse se mesure avant d'être recommandée : calibration sur les
10 premiers mois, validation sur les 5 derniers jamais regardés. Un
résultat sur un seul échantillon ou sans test de robustesse ne vaut rien
ici — plusieurs configurations séduisantes se sont révélées être du bruit
de petit échantillon.

## Où sont les choses

L'installation MT5 est sur la **machine locale** de l'utilisateur, pas sur
ce serveur :

    ~/.mt5/drive_c/Program Files/MetaTrader 5/

Les sources de ce dépôt y sont liées par liens symboliques
(`MQL5/Indicators`, `MQL5/Scripts`) : éditer ici suffit, il reste à
recompiler.

- `indicators/FDK_Gold_Custom.mq5` — l'indicateur
- `scripts/FDK_ExportData.mq5` — export des bougies vers CSV
- `backtest/` — bt2 (backtest), sweep (robustesse), zones, confirm, v3_stats
- `resultats/` — sorties brutes des mesures

## Compilation

MetaEditor tourne sous Wine. Deux pièges rencontrés :

- le chemin doit être **relatif** à la racine de l'installation MT5, sinon
  la compilation échoue en silence
- Wine ayant été mis à jour pendant que MT5 tournait, le `wineserver` en
  mémoire ne correspond plus au client ; on compile alors dans un préfixe
  isolé temporaire plutôt que de fermer le terminal de l'utilisateur

```
cd "<racine MT5>"
WINEPREFIX=<prefixe_isole> wine MetaEditor64.exe \
  /compile:"MQL5\Indicators\FDK_Gold_Custom.mq5" /log
iconv -f UTF-16LE -t UTF-8 MQL5/Indicators/FDK_Gold_Custom.log
```

Le log est en UTF-16. **Vérifier l'horodatage du `.ex5`, pas le texte du
log** : quand MetaEditor ne démarre pas, l'ancien log reste en place et
sa ligne « 0 errors » se relit comme un succès. Le 29/09 le préfixe isolé
était corrompu (`could not load kernel32.dll`) et deux compilations ont
été annoncées réussies alors qu'aucune n'avait eu lieu.

Wine est désormais en 11.18 des deux côtés : le préfixe isolé n'est plus
nécessaire, `WINEPREFIX=$HOME/.mt5` fonctionne pendant que MT5 tourne.

## Pièges de l'environnement

- `Bars(sym, tf)` ne suffit pas à savoir si une unité de temps est lisible :
  tant qu'aucun graphique ne l'a ouverte, la série n'est pas construite et
  le compte est trop faible. C'est `CopyHigh` qui déclenche la
  construction. Tester `Bars()` **avant** de copier condamne l'unité de
  temps à rester indisponible — le 29/09 le biais H4 est resté absent
  toute la journée sur un terminal n'affichant qu'un graphique M15, alors
  que `Bases/Deriv-Demo/history/XAUUSD/` contenait tout l'historique.
  Demander, puis accepter ce qui revient.
- Une lecture qui échoue ne doit être ni mise en cache pour la bougie
  entière, ni retentée à chaque appel : les étiquettes journalières
  relancent une vingtaine de lectures par redessin, ce qui a valu un
  `indicator is too slow, 2840 ms`. Un repos d'une seconde entre deux
  tentatives.
- MT5 interrompt un indicateur trop lent (`indicator is too slow`) et le
  graphique se fige : rien qui lise des barres ne doit tourner à chaque
  tick. Le contexte est mis en cache une fois par bougie dans
  `RefreshContext`.
- La police Wingdings est absente du préfixe Wine : `OBJ_ARROW` s'affiche
  en carrés vides. Utiliser `OBJ_TEXT`.
- Le serveur Deriv est en UTC, le Bénin en UTC+1 ; le décalage est
  détecté automatiquement via `TimeGMT`.
- Un pip sur cet or vaut 0.10, pas 0.01.
- Des coupures réseau côté Deriv figent le prix : vérifier
  `logs/<date>.log` du terminal avant d'incriminer le code.
- Le disque de la machine locale est proche de la saturation ; nettoyer
  les préfixes Wine temporaires après usage.
