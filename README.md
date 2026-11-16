# ASUSTOR Explorateur pour iPhone

App iOS 16 ou ultérieure et extension Apple Fichiers. Les deux cibles utilisent le relais EZ‑Connect de l’explorateur. Les dossiers ne chargent que leurs métadonnées. Lorsqu’iOS demande le contenu d’un document, l’extension télécharge ce seul fichier.

## Dépôt et compilation Codemagic

1. Créer un dépôt GitHub privé et envoyer **le contenu** de ce dossier à sa racine. Le fichier `codemagic.yaml` et le dossier `ASUSTOR.xcodeproj` doivent se trouver au même niveau. L’URL du dépôt a la forme `https://github.com/VOTRE-COMPTE/asustor-iphone`.
2. Dans Codemagic, connecter GitHub, sélectionner le dépôt privé et lancer **Vérifier la compilation iOS**. Ce workflow compile les deux cibles pour le simulateur et vérifie que l’extension est incluse dans l’app. Il ne requiert ni certificat ni adhésion Apple. Il ne produit pas d’app installable sur iPhone.
3. Pour obtenir l’app privée, choisir un identifiant de bundle unique et le reporter dans `Signing.xcconfig` et `codemagic.yaml`. Renseigner le Team ID dans `Signing.xcconfig`.
4. Dans Apple Developer, enregistrer l’UDID de l’iPhone. Créer les App IDs explicites de l’app et de l’extension (`<identifiant>.fileprovider`) et activer le même App Group `group.<identifiant>` pour les deux. Les entitlements demandent aussi un accès au groupe de trousseau `<préfixe App ID>.<identifiant>.session`.
5. Dans Codemagic, ajouter le certificat de distribution et les deux profils Ad Hoc contenant ton iPhone sous **iOS code signing identities**. On peut générer ou importer les profils via la connexion Apple Developer proposée par Codemagic. Aucun certificat, mot de passe NAS, jeton ou secret n’est à ajouter au dépôt.
6. Lancer **Exporter l’IPA privé Ad Hoc**. Il archive les deux cibles, vérifie que les deux profils sont inclus et exporte l’IPA. Le workflow ne publie rien. Pour une installation à distance, un service de distribution Ad Hoc fournit un lien d’installation sur l’iPhone, à condition que son UDID figure dans les profils. Un simple lien de téléchargement vers un IPA ne garantit pas l’installation.
7. Après installation et connexion à l’app, ouvrir **Fichiers → Explorer → ⋯ → Modifier**, puis activer **ASUSTOR · nom du compte**.

Documentation : [projet iOS natif Codemagic](https://docs.codemagic.io/yaml-quick-start/building-a-native-ios-app/) · [signer les deux cibles](https://docs.codemagic.io/yaml-code-signing/signing-ios/) · [approvisionnement Ad Hoc chez Apple](https://developer.apple.com/fr/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/).

## Vérifier la persistance sur iPhone

- Se connecter avec « Rester connecté sur cet appareil », parcourir deux dossiers depuis Fichiers, puis ouvrir un seul document. Les requêtes de liste ne doivent déclencher aucun transfert de contenu.
- Fermer puis relancer l’app. Le même compte doit revenir sans ressaisir le mot de passe, et le même emplacement doit rester disponible dans Fichiers.
- Quand ADM expire le SID mais accepte encore le jeton de reconnexion, tenter une liste et un téléchargement depuis Fichiers. Chaque opération refusée peut renouveler la session et être rejouée une fois. L’app reprend ce cookie à son retour.
- Se déconnecter depuis l’explorateur, puis vérifier que l’emplacement disparaît et qu’un nouveau lancement demande une connexion. Refaire le test sans cocher la reconnexion et vérifier que la session temporaire ne se restaure pas depuis le trousseau après un lancement à froid.

La reconnexion dépend de la durée de validité du jeton ADM. Cette version prépare le parcours pour un compte actif. Le récapitulatif fonctionnel reste dans [LISEZ-MOI.md](LISEZ-MOI.md).
