# ASUSTOR Explorateur pour iPhone

Le projet Xcode contient une app iOS et son extension Apple Fichiers. L’app ouvre l’explorateur ASUSTOR publié dans un composant WebKit intégré. Ce choix conserve l’interface et la logique existantes, notamment les aperçus et les éditeurs. L’extension utilise directement le service de l’explorateur pour communiquer avec ADM par le relais web EZ‑Connect.

## Installer sur un iPhone

1. Sur un Mac avec Xcode, ouvrir `ASUSTOR.xcodeproj`. L’app cible les iPhone sous iOS 16 ou ultérieur.
2. Dans `Signing.xcconfig`, renseigner `DEVELOPMENT_TEAM` et remplacer `ASUSTOR_BUNDLE_ID` par un identifiant unique. Dans « Signing & Capabilities », vérifier la signature des deux cibles, ainsi que le même App Group et le même groupe d’accès au trousseau. Le groupe d’apps est `group.<identifiant de l’app>`. Enregistrer ce groupe auprès de l’équipe Apple si Xcode le demande.
3. Sélectionner le schéma `ASUSTOR` et l’iPhone, puis lancer `Run`. Autoriser le mode Développeur sur l’iPhone si Xcode le demande.
4. Ouvrir l’app et saisir le Cloud ID EZ‑Connect, le compte ADM et son mot de passe. « Rester connecté sur cet appareil » utilise le mécanisme de reconnexion d’ADM lorsque le NAS le prend en charge. Le trousseau partagé ne conserve que le cookie de session de l’explorateur et l’empreinte du compte. Le mot de passe ne fait pas partie du stockage de l’app ni de la base des récents.
5. Ouvrir **Fichiers → Explorer → ⋯ → Modifier** et activer l’emplacement **ASUSTOR · nom du compte**. La déconnexion depuis l’explorateur retire l’emplacement. Une installation TestFlight requiert la signature et la distribution via une équipe du programme Apple Developer.

## Cahier des charges repris dans l’app

| Demande | Comportement et limites |
| --- | --- |
| Connexion et confidentialité | Relais web EZ‑Connect et identifiants ADM. L’app utilise la même passerelle que le site. La reconnexion dépend de la durée de validité accordée par ADM. L’étape supplémentaire de validation ADM reste à gérer si le NAS l’exige. |
| « Mes fichiers » | L’explorateur conserve la police Brown, l’interface responsive, les icônes de navigation avec initiales lorsque la colonne est réduite, la liste et la grille. Il affiche le partage correspondant à l’initiale du compte ou le plus proche, puis les favoris, les récents et les grands dossiers partagés. Dans un dossier, la liste principale ne duplique pas les sous-dossiers. |
| Récents et favoris | Le serveur rattache les récents à l’empreinte du Cloud ID et du compte ADM. Les transferts de contenu demandés depuis Fichiers envoient une mise à jour des récents lorsque le relais est joignable. Les favoris du site restent stockés par compte dans les données locales WebKit de l’app. |
| Recherche et dossiers lents | L’explorateur utilise la recherche avancée native d’ADM, avec choix de l’emplacement, et conserve les messages distincts pour les dossiers vides et les erreurs de chargement. L’extension Fichiers peut indexer les métadonnées des fichiers déjà ouverts. La recherche ADM sur tout le NAS reste dans l’explorateur. |
| Actions, création et transferts | Le menu « ⋯ » remplace le clic droit sur l’écran tactile. Le menu Nouveau propose dossiers, documents, classeurs, présentations, texte, scripts Python et un fichier avec extension libre. L’explorateur conserve l’import, le téléchargement, les opérations sur les fichiers et les liens ADM avec expiration et mot de passe facultatif. Les droits et le partage nominatif sont gérés côté ADM. |
| Aperçus | L’explorateur reprend les aperçus Word et PowerPoint mis en page, Excel, PDF sans OCR, images, vidéos, sons et texte, dont Python coloré. Pour une extension inconnue, l’aperçu texte dépend de la possibilité de décoder le fichier. Fichiers fait appel aux aperçus natifs iOS pour les types pris en charge par Apple. |
| Édition | L’explorateur ouvre l’éditeur dans une vue distincte avec Quill pour Word et CodeMirror pour le texte et Python, et l’éditeur Excel actuel. Le bouton Fermer utilise le dialogue de l’éditeur avec Rester, Quitter sans enregistrer et Enregistrer et quitter. L’édition PowerPoint utilise ONLYOFFICE Docs uniquement si son instance est configurée. La fidélité et les fonctions de l’interface Excel ou Word dépendent des éditeurs actuels du site. |
| Conversions | Le menu Convertir de l’explorateur crée une copie. Le site propose les conversions de PDF vers les formats bureautiques, ZIP de JPG ou texte, de ZIP d’images vers PDF, des conversions d’images vers JPG, PNG, WebP ou PDF, et l’extraction audio WAV/MP3 pour les sources que le moteur sait décoder. L’OCR, l’encodage HEIC et le transcodage vidéo MP4 vers d’autres formats vidéo ne sont pas proposés par le convertisseur actuel. La prise en charge des codecs est à vérifier sur iPhone. |
| Apple Fichiers | L’extension affiche l’arborescence, permet l’ouverture et la copie depuis le NAS. Les opérations d’écriture dans Apple Fichiers sont désactivées. Elles restent disponibles dans l’explorateur, selon les droits ADM. |

## Stockage et validation sur appareil

- L’énumération demande `/api/list` pour le dossier courant et reçoit noms, chemins, dates et tailles. Elle ne descend pas récursivement dans le NAS et ne contient aucun appel de téléchargement.
- L’extension expose les documents à iOS avec la politique `downloadLazily`. Une demande de contenu pour un document déclenche `/api/content` pour ce seul fichier. Le réseau écrit dans un fichier temporaire transmis à File Provider. iOS gère ensuite la copie locale. Si iOS offre la commande « Supprimer le téléchargement », celle-ci libère la copie locale et préserve le fichier du NAS.
- Pour la recette, ouvrir deux dossiers contenant des fichiers de taille significative, puis vérifier qu’aucune requête à `/api/content` ne part pendant la navigation. Ouvrir un fichier et vérifier que seul son chemin est demandé. Tester la suppression du téléchargement, la reconnexion, la séparation de deux comptes, et la disparition de l’emplacement après déconnexion.
- Tester sur iPhone les menus, l’import depuis la galerie ou Fichiers, un téléchargement partagé avec une autre app, les aperçus PDF et PowerPoint, et les trois choix de fermeture d’un éditeur modifié. Tester l’édition des diapositives lorsque ONLYOFFICE Docs est configuré.

Le service de test a été exercé avec un NAS simulé. La validation Xcode, la signature et la recette sur iPhone n’ont pas été réalisées dans l’environnement Linux.
