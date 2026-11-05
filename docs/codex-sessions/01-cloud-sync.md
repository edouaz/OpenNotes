Travaille sur OpenNotes dans /Users/edouard/Documents/Personal_Projects/CatNotes. Applique Ponytail full : le plus petit changement complet, avec validation et gestion des erreurs préservées.

MULTI-AGENT EXECUTION
- Garde le modèle parent actuel pour architecture, planification, intégration et validation finale.
- Délègue les tâches indépendantes utiles avec collaboration.spawn_agent : agent_type="worker", model="gpt-6.1-terra", reasoning_effort="high", fork_turns="none".
- Utilise xhigh uniquement pour une difficulté démontrée de géométrie/rendu, synchronisation d’état, lasso ou interaction SwiftUI/UIKit. Explique ce choix.
- Modèles OpenAI uniquement. Si Terra n’est pas disponible, signale-le et poursuis avec le parent ; ne substitue pas silencieusement un autre fournisseur.
- Donne à chaque worker un périmètre explicite, le contexte minimal et les critères de réussite. Rappelle qu’il n’est pas seul et ne doit pas annuler les changements des autres. Deux workers utiles valent mieux qu’un essaim de microtâches ; ne redélègue pas le même travail.

AVANT DE MODIFIER
Lis les AGENTS.md applicables et docs/MCP_SYNC_AUDIT_2026-11-01.md. Inspecte git status : le workspace contient beaucoup de travail non commité à préserver. Pour des sessions simultanées, travaille sur une copie/branche isolée issue du même état courant sauvegardé, comprenant ces changements ; un worktree créé uniquement depuis HEAD ne les contient pas. Ne nettoie, stash ou commit pas le travail d’autrui. N’expose pas de secrets dans les rapports. Vérifie les callers et les tests avant de modifier le code partagé.

MISSION — P0 : rétablir la synchronisation des fichiers entre iPad et iPhone.

Les deux appareils utilisent déjà la dernière version annoncée. L’app s’installe ; le problème est le téléchargement/import des carnets cloud. Erreur : « notebooks could not be imported », « Installing notebook », « Invalid encoded data », suivie d’une suggestion de mise à jour. Cette suggestion est générique, pas un diagnostic. Le build 17 n’a pas résolu le cas réel.

Périmètre réservé : OpenNotes/Services/CloudSync.swift, NotebookArchive.swift, OpenNotes/App/LibraryStore.swift pour le chemin d’archive uniquement, modèles/décodeurs nécessaires, tests Swift pertinents. N’édite pas la corbeille, server/ ou la configuration du plugin. Coordonne toute modification de fichiers partagés.

Délégation utile : un worker sur la lecture/décodage des ressources natives ; un autre sur la validation publication/réception et les tests existants. L’orchestrateur garde la reproduction et décide du correctif.

1. Reproduis à partir du carnet exact. Le précédent audit a confirmé les métadonnées et l’existence des objets Supabase, pas leur contenu ni leur checksum réel. Cherche un accès Storage authentifié disponible, via les outils connectés ou la configuration déjà autorisée. Ne rends pas le bucket public, ne change pas RLS et n’extrais pas de secrets pour contourner un accès manquant. Si les octets ne sont pas accessibles, demande une copie .catnote/diagnostic approprié et termine les analyses indépendantes ; ne prétends pas avoir trouvé la cause.
2. Télécharge une copie privée de la révision fautive. Compare taille et SHA-256 aux métadonnées ; décode le JSON de l’archive puis chaque ressource d’encre avec le vrai décodeur Swift. Localise page, ressource, chemin JSON et champ fautif sans afficher le contenu privé. Distingue corruption des octets, JSON incompatible, schéma d’encre, points/tailles, style et chemin vectoriel. Compare avec l’archive source de la tablette si accessible. Conserve les originaux.
3. Vérifie la lacune connue : DiskStore.archive contrôle la présence des ressources mais applyCloudArchive décode ensuite InkDrawing. Un upload peut donc être accepté alors que l’import est impossible. Ne confonds pas ce défaut établi dans le code avec la cause encore non prouvée du carnet réel.
4. Écris un test reproduisant le défaut avant la correction. Corrige la cause une fois dans le code commun. Conserve les limites de validation ; ne remplace pas silencieusement l’encre par un dessin vide. Si des archives anciennes doivent être normalisées, conserve leur original et prouve que le contenu est préservé.
5. Aligne la validation avant publication avec la lecture nécessaire à l’import. Vérifie qu’un fichier invalide ne peut plus être annoncé synchronisé. Corrige aussi le diagnostic qui mélange le préfixe Uploading avec une erreur Installing enregistrée, et exporte le contexte sûr via Diagnostics existant.
6. Vérifie source -> Supabase -> bibliothèque iPhone vierge -> redémarrage -> nouvelle synchronisation. Un aller-retour utilisant seulement une archive neuve ne suffit pas. Les archives réelles doivent être prises en compte quand disponibles.

Pas de migration vers Drive, de changement d’hébergeur ni de réparation destructive des données pendant cette session. Fournis cause prouvée ou hypothèses clairement séparées, test avant/après, fichiers modifiés et limites. Prépare une IPA seulement après validation du correctif ; garde les identifiants et l’installation en place. N’annonce pas le problème résolu sans avoir retesté le cas fautif ou indique précisément cette limite.
