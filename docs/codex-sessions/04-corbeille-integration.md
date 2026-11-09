Travaille sur OpenNotes dans /Users/edouard/Documents/Personal_Projects/CatNotes. Applique Ponytail full : le plus petit changement complet, avec validation et gestion des erreurs préservées.

MULTI-AGENT EXECUTION
- Garde le modèle parent actuel pour architecture, planification, intégration et validation finale.
- Délègue les tâches indépendantes utiles avec collaboration.spawn_agent : agent_type="worker", model="gpt-6.1-terra", reasoning_effort="high", fork_turns="none".
- Utilise xhigh uniquement pour une difficulté démontrée de géométrie/rendu, synchronisation d’état, lasso ou interaction SwiftUI/UIKit. Explique ce choix.
- Modèles OpenAI uniquement. Si Terra n’est pas disponible, signale-le et poursuis avec le parent ; ne substitue pas silencieusement un autre fournisseur.
- Donne à chaque worker un périmètre explicite, le contexte minimal et les critères de réussite. Rappelle qu’il n’est pas seul et ne doit pas annuler les changements des autres. Deux workers utiles valent mieux qu’un essaim de microtâches ; ne redélègue pas le même travail.

AVANT DE MODIFIER
Lis les AGENTS.md applicables et docs/MCP_SYNC_AUDIT_2026-11-01.md. Inspecte git status : le workspace contient beaucoup de travail non commité à préserver. Pour des sessions simultanées, travaille sur une copie/branche isolée issue du même état courant sauvegardé, comprenant ces changements ; un worktree créé uniquement depuis HEAD ne les contient pas. Ne nettoie, stash ou commit pas le travail d’autrui. N’expose pas de secrets dans les rapports. Vérifie les callers et les tests avant de modifier le code partagé.

MISSION — P2 puis intégration : cohérence de la corbeille et validation de la version commune.

À lancer après les sessions 01-cloud-sync, 02-chatgpt-mcp et 03-mcp-server, une fois leurs changements et preuves disponibles. N’intègre pas uniquement leurs conclusions : vérifie les diffs sur le même état de travail de départ, y compris les modifications déjà présentes avant ces sessions.

Périmètre de cette session : cohérence app/MCP pour dossiers, suppression, restauration et carnets purgedAt ; intégration finale, tests et paquet installable. Préserve les sources et données existantes. N’ajoute pas de nouvelle migration de stockage ou de suppression d’historique sans besoin confirmé.

Délégation utile : un worker examine les transitions et la visibilité Swift ; un autre examine les opérations MCP et leurs tests. Ils commencent en lecture seule pour éviter des changements simultanés de contrat. Le parent choisit la sémantique, attribue ensuite les fichiers, puis intègre et valide.

1. Compare les comportements actuels : l’app supprime le sous-arbre et met ses carnets à la corbeille ; update_folder(trashed:true) masque seulement le dossier. L’app masque purgedAt, mais list_notebooks expose les heads correspondants. Les archives historiques et certains fichiers locaux restent conservés.
2. Définis une sémantique minimale et explicite : supprimer un dossier avec ses descendants, restaurer un carnet dont le dossier est supprimé, vider la corbeille sur tous les appareils, visibilité normale dans le MCP, accès explicite à l’historique. Ne présente pas un masquage comme une purge physique. Préserve la récupération et les conflits concurrents ; traite les anciens clients explicitement.
3. Corrige les divergences nécessaires dans les callers app/MCP et ajoute les tests utiles. Ne supprime pas les archives utilisateur pour tester ni pour simplifier le code. Identifie les effets d’une opération sur une session d’édition encore ouverte et sur une resynchronisation.
4. Intègre les correctifs des trois premières sessions. Vérifie : carnet réel tablette -> cloud -> iPhone -> redémarrage ; absence d’écrasement d’un carnet invalide ; conflits préservés ; vrai appel ChatGPT ; erreurs lisibles ; cycle supprimer/restaurer/vider cohérent sur deux clients.
5. Si le défaut réel de synchronisation ou la connexion ChatGPT reste bloqué, indique ce qui manque et ne qualifie pas la release de corrigée. Une correction partielle doit être nommée comme telle.
6. Après réussite des vérifications applicables, génère une IPA avec numéro supérieur à la dernière version distribuée, identifiants inchangés, configuration Supabase publique correcte, contrôle ZIP et SHA-256. Distingue IPA signée/non signée ; ne demande pas de désinstaller l’app. Mets à jour les notes de validation et les seuls rappels réellement terminés, sans insérer ces prompts dans leurs descriptions.

Compte rendu final : comportement obtenu, preuves et tests, artefact, tâches restantes et risques. Évite de refaire tous les audits quand les preuves n’ont pas changé ; consacre la validation supplémentaire aux interfaces et défauts réellement touchés.
