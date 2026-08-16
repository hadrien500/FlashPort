# Changelog

Toutes les évolutions notables de FlashPort sont documentées ici.
Format inspiré de [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/) ; le projet suit [SemVer](https://semver.org/lang/fr/).

## [Non publié] — prochaine bêta 3

### Ajouté
- Vérification de mise à jour au lancement : si une nouvelle release est publiée sur GitHub, un bouton « Mise à jour disponible » ouvre la page de téléchargement.

### Corrigé
- Le firmware importé n'est plus marqué « À vérifier » avant la lecture du PIT (régression de la bêta 2 liée au moteur natif par défaut).

## [1.0.0-beta.2] — 2026-08-15

### Ajouté
- Le moteur natif Swift devient le backend par défaut (Heimdall passe en option de secours « Heimdall (externe) »).
- Vérification du trailer MD5 des archives `.tar.md5` à l'import : une archive corrompue bloque l'import avant tout envoi au téléphone.
- Glisser-déposer du ZIP ou du dossier firmware directement sur la fenêtre.
- Notification macOS à la fin du flash quand l'app est en arrière-plan.
- Le Mac ne peut plus se mettre en veille pendant un flash.
- Les réglages (backend, redémarrage après flash, mode données) sont mémorisés entre les lancements.
- Intégration continue GitHub Actions (compilation + tests unitaires).

### Modifié
- Libellés des backends clarifiés : « Natif (Swift) » et « Heimdall (externe) » (les anciens noms « Rapide »/« Compatible lent » ne reflétaient plus la réalité : le moteur natif utilise l'USB bulk rapide).
- L'historique des sessions enregistre le moteur réellement utilisé, pas le réglage affiché.
- Identifiants de bundle corrigés (`com.hadrien500.*`) — l'historique local et les réglages repartent à zéro une fois lors de la mise à jour.

## [1.0.0-beta.1] — 2026-08-15

Première bêta publique, validée de bout en bout sur un Galaxy A13 (SM-A137F, MediaTek) : flash complet avec conservation des données utilisateur.

### Ajouté
- Import des packages firmware Samsung officiels (ZIP ou dossier extrait) avec analyse BL/AP/CP/CSC/HOME_CSC.
- Moteur du protocole Odin natif en Swift : handshake, lecture PIT, session unique, tailles 64 bits (images > 4 Go que Heimdall 1.4.2 tronque silencieusement), délais de finalisation étendus après les grosses images.
- Conservation des données : respect du `meta-data/download-list.txt` comme Odin (avec HOME_CSC, `misc.bin`, `param.bin`, `md_udc.img` et `userdata.img` sont exclus automatiquement).
- Garde-fous : vérification du modèle et du binary bootloader, blocage anti-downgrade, détection des doublons de partition, blocage des images non associées au PIT.
- Backend Heimdall : session unique avec reprise `--resume` automatique des images restantes, grosses partitions envoyées en dernier, tolérance des fins de session non confirmées.
- Détection automatique du téléphone en mode Download, décompression LZ4 (binaire `lz4` ou décodeur Swift intégré), console de logs, export de rapport et du PIT, historique des flashs.
- Interface avec badge BETA, icône de l'app, binaire universel (Apple Silicon + Intel).
