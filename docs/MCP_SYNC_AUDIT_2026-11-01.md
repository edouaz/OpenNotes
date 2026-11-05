# Audit OpenNotes — synchronisation et MCP

Audit du 1er novembre 2026. Déclencheur : l’utilisateur confirme que le build 17 échoue encore, à l’étape « Installing notebook », avec « Invalid encoded data ». Les outils OpenNotes restent absents du chat malgré la mention du plugin. Le build 17 ne peut donc pas être considéré comme une correction validée de ce cas réel.

## Résultat

Deux chaînes doivent être vérifiées séparément : installation des archives natives et connexion de l’App ChatGPT au serveur MCP. Le serveur partage les archives et le compte avec l’app mobile, mais l’absence d’outils dans ChatGPT ne prouve pas une corruption des archives. Inversement, un endpoint public accessible ne prouve pas une connexion ChatGPT fonctionnelle.

Aucune nouvelle IPA, migration, modification de documents ni publication de plugin effectuée pendant cet audit. Les travaux non résolus sont enregistrés dans Apple Reminders, liste iCloud « OpenNotes — Audit et corrections » (`286495E8-0F4F-4030-85C1-3ECFB6351F5B`).

## Constats et preuves

| Priorité | Constat | Preuve / limite | Suite nécessaire |
| --- | --- | --- | --- |
| P0 | L’importation réelle échoue encore sur iPhone. | Message transmis par l’utilisateur : étape Installing notebook et erreur de décodage. Le carnet exact n’a pas été lu pendant cet audit. | Obtenir une copie native .catnote ou le chemin JSON complet du diagnostic ; reproduire sur les mêmes octets avant de choisir une conversion. |
| P0 | L’envoi et la réception n’ont pas la même validation d’encre. | `DiskStore.archive`, NotebookArchive.swift:208, rassemble les ressources et appelle validate(), qui contrôle leur présence mais ne décode pas InkDrawing. `LibraryStore.applyCloudArchive`, LibraryStore.swift:277, décode ensuite chaque ressource avec InkDrawing(data:). | Tester une archive structurée contenant une ressource d’encre invalide ; refuser sa publication avant upload/commit, sans modifier l’original. L’implication de cette lacune dans le cas réel reste une hypothèse. |
| P0 | Le plugin existe, mais aucun outil OpenNotes n’est exposé ici. | ALL_TOOLS ne contient pas d’outil OpenNotes. search_plugins renvoie zéro résultat, mais list_owned_personal_plugins retrouve le plugin exact. Le résultat de recherche seul ne permettait pas de conclure à son absence. | Vérifier la connexion de l’App liée et exécuter réellement list_folders/list_notebooks dans le chat. |
| P0 | La configuration de connexion appartient à une App liée. | Le paquet contient seulement .app.json et .codex-plugin/plugin.json. Le premier référence asdk_app_6ae68c46fbdc81919c1004de0f92d05d ; aucun endpoint MCP n’est déclaré dans le paquet inspecté. | Inspecter et actualiser l’App existante dans son éditeur : URL MCP exacte, OAuth, découverte/publication des outils. Les outils de paquet disponibles n’exposent pas cette configuration de connexion. Ne pas créer de doublon ni ajouter un deuxième serveur dans le paquet. |
| P1 | Le parcours OAuth et HTTP authentifié n’est pas validé de bout en bout. | Les métadonnées publiques fonctionnent, et les tests SDK locaux passent. Ces tests n’exécutent pas la connexion ChatGPT avec le compte utilisateur en production. | Consentement, code PKCE, échange de jeton, initialize HTTP, tools/list, lecture puis écriture dans un carnet de test. |
| P1 | La validation de jeton MCP doit être approfondie. | index.mjs:31–38 vérifie getUser puis utilise le jeton pour Supabase/RLS. Pas de contrôle explicite d’une audience spécifique à cette ressource MCP dans ce code. | Vérifier les claims émis et la prise en charge de resource/audience par Supabase avant tout changement. Vérifier Origin et les délais HTTP. Ce point ne démontre pas la cause du défaut actuel. |
| P1 | Le diagnostic global peut décrire la mauvaise étape. | CloudSync conserve les erreurs par carnet puis remonte leur agrégat après la boucle d’envoi ; le préfixe global peut donc être Uploading notebook alors que l’échec enregistré est Installing notebook. Le catch HTTP global du serveur ne fournit pas de journal applicatif de l’étape fautive. | Conserver étape, chemin JSON, révision et code par échec ; ajouter des traces serveur sans contenu de carnet, titre, mot de passe ou jeton. |
| P2 | La corbeille n’a pas la même sémantique sur les deux interfaces. | L’app supprime le sous-arbre de dossiers et marque ses carnets supprimés. MCP update_folder(trashed:true) ne fait qu’actualiser le dossier. list_notebooks retourne tous les heads, y compris ceux dont l’archive porte purgedAt. | Définir la visibilité, la restauration et la conservation d’historique de façon cohérente. Empty Trash masque les entrées mais ne libère pas actuellement tous les fichiers et révisions. |

## Identité et permissions du plugin inspecté

- Nom affiché : OpenNotes.
- Référence utilisateur : dev-6ae68c46fbdc81919c1004de0f92d05d.
- Identifiant backend vérifié : plugin_asdk_app_6ae68c46fbdc81919c1004de0f92d05d.
- Identifiant App : asdk_app_6ae68c46fbdc81919c1004de0f92d05d.
- Portée USER, visibilité PRIVATE, version 1.0.0.
- Release inspectée : PluginRelease_9bc89a2303408191b59893228af17642.
- Permissions : défaut global Allow low-risk actions, règle App Use my default. Aucun refus global identifié par cette inspection ; cela ne prouve pas que l’authentification de la connexion est valide.

Une simple hausse de version du paquet ne corrigerait pas une connexion App défectueuse. Aucun changement cosmétique de version n’a été publié.

## Vérifications effectuées

1. Inventaire des outils de ce chat, recherche et inventaire des plugins personnels, lecture complète des deux fichiers du plugin et inspection de ses permissions.
2. Lecture du chemin archive → téléchargement → installation et du décodage de l’encre native ; lecture du serveur HTTP, des outils MCP, du dépôt d’archives, de la page de consentement, des tests et du Dockerfile.
3. Requêtes publiques : métadonnées de ressource MCP lisibles ; les deux endpoints de découverte Supabase suivants répondent HTTP 200 avec le même issuer `https://evuqpcklfxxnjzjcrwos.supabase.co/auth/v1` :
   - `https://evuqpcklfxxnjzjcrwos.supabase.co/.well-known/oauth-authorization-server/auth/v1`
   - `https://evuqpcklfxxnjzjcrwos.supabase.co/auth/v1/.well-known/oauth-authorization-server`
4. `npm test` dans server/ : **20 tests réussis, zéro échec**. Inclut les tests HTTP anonymes, les opérations SDK en mémoire, les conflits, les checksums, les transferts privés et le rendu. Aucune exécution authentifiée de l’App ChatGPT n’est revendiquée.
5. Création puis vérification des huit rappels avec notes et critères de validation. Aucun mot de passe ou jeton stocké dans les rappels.

## Ordre de reprise

1. Reproduire la lecture du carnet exact, avec son chemin JSON complet ; préserver les originaux et les historiques.
2. Vérifier la connexion dans l’éditeur de l’App ChatGPT existante. Utiliser l’URL canonique `https://opennotes-mcp-edouazs-projects.vercel.app/mcp`, identique à celle annoncée dans les métadonnées.
3. Valider OAuth et les véritables appels HTTP authentifiés. Ne pas qualifier la connexion de fonctionnelle à partir d’un simple HTTP 200/401.
4. Corriger la validation d’archive et les erreurs avec un test sur le cas reproduit ; seulement ensuite produire et tester une nouvelle IPA sur les deux appareils.
5. Traiter les écarts d’authentification, d’observabilité et de corbeille avec leurs tests dédiés.

## Référence de protocole

La spécification MCP demande une validation de la destination du jeton, au-delà de l’identité utilisateur : [Authorization — Token Audience Binding and Validation](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/basic/authorization.mdx). Cette exigence motive l’audit des claims ; elle ne justifie pas d’ajouter une règle arbitraire qui rendrait tous les jetons Supabase invalides.
