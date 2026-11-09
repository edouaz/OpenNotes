# Sessions Codex pour OpenNotes

Chaque fichier est un prompt autonome à copier dans un nouveau chat Codex. Le modèle parent orchestre ; les workers d’implémentation sont OpenAI gpt-6.1-terra high, avec fork_turns none. XHigh est réservé aux difficultés justifiées.

## Ordre et correspondance des rappels

| Session | Quand | Rappels couverts | Responsabilité |
| --- | --- | --- | --- |
| 01-cloud-sync.md | En premier, parallélisable avec 02/03 | P0 reproduction du défaut cloud, P0 validation de l’encre avant publication, partie Swift du P1 diagnostics | Archive native, octets réels Supabase, décodeur Swift, tests de synchronisation |
| 02-chatgpt-mcp.md | Parallèle avec 01/03 | P0 outils OpenNotes absents, P0 actualisation de l’App existante, P1 parcours authentifié | App ChatGPT, connexion, OAuth client et consentement |
| 03-mcp-server.md | Parallèle avec 01/02 ; déploiement coordonné après diagnostic | P1 audience/transport, partie serveur du P1 diagnostics | HTTP, authentification et tests serveur |
| 04-corbeille-integration.md | Après les trois autres | P2 cohérence corbeille + validation transversale et livraison | Contrats app/MCP, intégration, tests réels et IPA |

Les huit rappels restent des tâches séparées ; leurs descriptions ne reçoivent pas ces prompts. Les regrouper en sessions évite de demander à plusieurs chats de modifier CloudSync ou l’authentification simultanément.

Avant de lancer plusieurs sessions : préserver le workspace courant, qui contient de nombreuses modifications non commitées. Les copies de travail doivent inclure cet état, pas seulement HEAD. Les prompts définissent des propriétaires de fichiers pour éviter les conflits. Ne changer la production utilisée par la session 02 qu’après avoir capturé son diagnostic.

## Décisions d’architecture proposées

Le chemin mobile appelle directement Supabase depuis CloudSync. Le serveur MCP sur Vercel intervient dans le chemin assistant -> MCP -> Supabase. Un défaut de lecture des carnets dans l’app native n’implique donc pas automatiquement Vercel.

Conserver Supabase pendant le diagnostic. Son stockage privé et ses contrôles RLS correspondent à l’architecture déjà implémentée ; le point à prouver est la lisibilité des mêmes octets sur les deux appareils. Le précédent audit n’a vérifié que les références et l’existence des objets, pas téléchargé les archives privées fautives. La session 01 doit obtenir une copie autorisée et comparer checksum, archive et ressources internes.

Google Drive permet de stocker des données propres à une application, mais introduirait une autre intégration OAuth/stockage. Il ne corrigerait pas par lui-même un décodeur de carnet incompatible. Le considérer ultérieurement pour une demande explicite de sauvegarde/export ou si le diagnostic révèle une contrainte de stockage réellement bloquante.

Railway permet d’héberger un serveur MCP Streamable HTTP. C’est une alternative à comparer si le runtime actuel pose une limite mesurée de taille, durée ou cycle de vie. La documentation Vercel indique que les limites Functions s’appliquent aussi aux containers, avec notamment 4,5 Mo par corps de requête/réponse. Cela mérite une vérification des appels MCP volumineux, mais ne démontre pas la cause de l’absence d’outils ni de l’erreur native.

Références consultées le 1er novembre 2026 :
- https://supabase.com/docs/guides/storage/security/access-control
- https://supabase.com/docs/guides/storage/uploads/file-limits
- https://developers.google.com/workspace/drive/api/guides/appdata
- https://vercel.com/docs/functions/runtimes/container
- https://vercel.com/docs/functions/limitations
- https://railway.com/guides/mcp-server

Aucune migration, mise à jour de rappel, modification du code applicatif ou nouvelle validation de carnets privés n’a été effectuée pour préparer ces prompts.
