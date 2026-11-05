Travaille sur OpenNotes dans /Users/edouard/Documents/Personal_Projects/CatNotes. Applique Ponytail full : le plus petit changement complet, avec validation et gestion des erreurs préservées.

MULTI-AGENT EXECUTION
- Garde le modèle parent actuel pour architecture, planification, intégration et validation finale.
- Délègue les tâches indépendantes utiles avec collaboration.spawn_agent : agent_type="worker", model="gpt-6.1-terra", reasoning_effort="high", fork_turns="none".
- Utilise xhigh uniquement pour une difficulté démontrée de géométrie/rendu, synchronisation d’état, lasso ou interaction SwiftUI/UIKit. Explique ce choix.
- Modèles OpenAI uniquement. Si Terra n’est pas disponible, signale-le et poursuis avec le parent ; ne substitue pas silencieusement un autre fournisseur.
- Donne à chaque worker un périmètre explicite, le contexte minimal et les critères de réussite. Rappelle qu’il n’est pas seul et ne doit pas annuler les changements des autres. Deux workers utiles valent mieux qu’un essaim de microtâches ; ne redélègue pas le même travail.

AVANT DE MODIFIER
Lis les AGENTS.md applicables et docs/MCP_SYNC_AUDIT_2026-11-01.md. Inspecte git status : le workspace contient beaucoup de travail non commité à préserver. Pour des sessions simultanées, travaille sur une copie/branche isolée issue du même état courant sauvegardé, comprenant ces changements ; un worktree créé uniquement depuis HEAD ne les contient pas. Ne nettoie, stash ou commit pas le travail d’autrui. N’expose pas de secrets dans les rapports. Vérifie les callers et les tests avant de modifier le code partagé.

MISSION — P0 : rendre les outils OpenNotes réellement utilisables dans ChatGPT.

Le plugin existe, malgré une recherche qui renvoie zéro résultat. Identités vérifiées lors de l’audit : plugin_asdk_app_6ae68c46fbdc81919c1004de0f92d05d ; App asdk_app_6ae68c46fbdc81919c1004de0f92d05d. La version inspectée était 1.0.0, release PluginRelease_9bc89a2303408191b59893228af17642 : revalide l’état actuel. Le paquet contient .app.json et .codex-plugin/plugin.json, qui référencent l’App ; la connexion MCP n’est pas décrite dans ces fichiers. Aucun outil OpenNotes n’est actuellement exposé dans le chat de l’audit.

Périmètre réservé : inspection et configuration de l’App/plugin existants et parcours OAuth du client. server/public/consent.* seulement si un défaut de consentement est établi. Pas de modification de server/index.mjs, server/mcp.mjs ni des fichiers Swift : l’autre session possède ces fichiers.

Délégation utile : un worker inspecte identité/paquet/permissions et la procédure officielle d’actualisation ; un second examine les métadonnées et le consentement. Le parent garde la connexion utilisateur et les validations dans ChatGPT.

1. Charge les compétences appropriées plugin-creator:update-plugin et la documentation OpenAI officielle actuelle. Inspecte les outils réellement disponibles avant de conclure qu’une fonctionnalité manque. Préfère les outils de service ; utilise l’éditeur de l’App dans le navigateur si nécessaire et accessible. Ne demande jamais le mot de passe dans le chat et ne contourne pas une connexion manquante.
2. Vérifie dans l’App existante l’URL canonique https://opennotes-mcp-edouazs-projects.vercel.app/mcp, l’authentification OAuth, l’état de découverte des outils et l’état publié/installé. Vérifie une éventuelle divergence d’alias avec resource/issuer. Ne crée pas de doublon de plugin ni de deuxième configuration MCP, et ne publie pas une hausse de version cosmétique.
3. Identifie exactement où échoue la chaîne : accès réseau, découverte ressource, découverte OAuth, enregistrement du client, consentement, PKCE/échange du code, requête MCP authentifiée, inventaire des outils ou exposition dans ChatGPT. Vérifie la version de protocole utilisée et ses échanges réellement requis ; n’impose pas un ancien handshake à un client plus récent.
4. Corrige le maillon démontré défectueux dans ton périmètre. Respecte l’identité, la portée et les permissions. Si l’outil d’édition de connexion n’est pas disponible, fournis les étapes concrètes dans l’éditeur, les valeurs attendues et le blocage exact. N’annonce pas avoir effectué un refresh qui n’a pas été exécuté.
5. Prouve la réussite par une véritable invocation depuis ChatGPT : outils listés, list_folders et list_notebooks réussis sur le compte attendu, puis lecture d’un carnet de test. Une écriture de test doit viser un carnet jetable clairement identifié ; ne modifie pas les notes existantes pour tester. Vérifie le résultat. Un HTTP 200/401, un lien @OpenNotes ou un test InMemoryTransport ne suffit pas.

Ne modifie pas le serveur de production pendant qu’une autre session capture son état ; coordonne le déploiement avec l’intégration. Ne migre pas vers Railway pour contourner un défaut de configuration App/OAuth. Termine par état de chaque maillon, preuve d’appel réel ou blocage précis, changements et prochaines actions minimales.
