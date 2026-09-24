# FDK Gold Custom — indicateur MT5 et validation

Indicateur MetaTrader 5 pour XAUUSD, avec l'outillage de backtest qui sert
à mesurer ce qu'il vaut réellement.

## Contenu

| Chemin | Rôle |
|---|---|
| `indicators/FDK_Gold_Custom.mq5` | L'indicateur |
| `scripts/FDK_ExportData.mq5` | Exporte les bougies MT5 vers CSV |
| `backtest/bt2.py` | Backtest, 3 scénarios de gestion |
| `backtest/sweep.py` | Sensibilité aux paramètres de structure |
| `backtest/zones.py` | Variantes filtrées par zones, split in/out-of-sample |
| `backtest/v3_stats.py` | Test de significativité |
| `resultats/` | Sorties brutes des mesures |

## Ce que l'indicateur affiche

- Zones de session en heure Bénin (Asie, Londres, NY AM, NY PM)
- Biais M15 et H4 par structure de swings
- Zones d'offre et de demande (base + impulsion), fraîches ou touchées
- Range du jour, étiquettes journalières, RSI, ATR, TP1/TP2
- Journal CSV automatique de chaque signal `ENTREE AUTORISEE`

## Résultat des mesures — à lire avant d'utiliser le signal

La règle d'entrée (biais M15 aligné sur biais H4 pendant une session)
**n'a pas d'avantage statistique démontrable**.

Sur 15 mois de XAUUSD Deriv réel (30 000 bougies M15, 193 trades) :

| Scénario | Espérance/trade |
|---|---:|
| A — tout à TP1 | −0.098 R |
| B — viser TP2, stop fixe | −0.021 R |
| C — moitié TP1 + point mort | −0.060 R |

TP1 touché avant le stop : 87/193, soit 45 % — sous le seuil d'équilibre
d'un rapport 1:1.

Le balayage de paramètres confirme : dès que l'échantillon dépasse
400 trades, l'espérance s'écrase sur zéro (+0.002, +0.000, +0.005 R).
Les valeurs attrayantes n'apparaissent qu'à 11 ou 47 trades — du bruit.

### Piste des zones, testée puis écartée

Filtrer les entrées par un retour dans une zone fraîche alignée avec le
biais produit **6 trades en 10 mois et 1 seul sur 5 mois de validation** :
les conditions ne se rencontrent quasiment jamais ensemble.

La seule variante à volume exploitable (entrée sur simple retour en zone,
sans biais ni session) donne sur 423 trades :

| Scénario | Moyenne | t | IC 95 % |
|---|---:|---:|:---:|
| A | +0.050 R | 1.02 | [−0.046 ; +0.145] |
| C | +0.062 R | 1.11 | [−0.047 ; +0.171] |

Tous les |t| < 1.2, tous les intervalles contiennent zéro. Non réfuté,
mais **non mesurable** à cette taille. Il faudrait environ 1400 trades,
soit près de 4 ans, pour trancher.

### Avertissement méthodologique

La règle actuelle donne −0.131 R en calibration et +0.200 R en validation.
Le même système change de visage selon la période : à ces niveaux de bruit,
aucun résultat de période unique ne doit être pris au sérieux.

**L'indicateur est un outil de lecture, pas un générateur de signaux validé.**

## Flux de travail

Les sources de ce dépôt sont la référence. Les fichiers dans
`MQL5/Indicators` et `MQL5/Scripts` de MT5 sont des liens symboliques
vers elles, donc éditer ici suffit ; il reste à recompiler.

Compilation (MetaEditor, depuis la racine de l'installation MT5) :

    wine MetaEditor64.exe /compile:"MQL5\Indicators\FDK_Gold_Custom.mq5" /log

Backtest sur données exportées :

    python3 backtest/bt2.py <chemin>/FDK_XAUUSD_M15.csv "XAUUSD Deriv"
