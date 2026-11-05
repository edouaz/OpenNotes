Travaille sur OpenNotes dans /Users/edouard/Documents/Personal_Projects/CatNotes. Applique Ponytail full : le plus petit changement complet, avec validation et gestion des erreurs préservées.

MULTI-AGENT EXECUTION
- Garde le modèle parent actuel pour architecture, planification, intégration et validation finale.
- Délègue les tâches indépendantes utiles avec collaboration.spawn_agent : agent_type="worker", model="gpt-6.1-terra", reasoning_effort="high", fork_turns="none".
- Utilise xhigh uniquement pour une difficulté démontrée de géométrie/rendu, synchronisation d’état, lasso ou interaction SwiftUI/UIKit. Explique ce choix.
- Modèles OpenAI uniquement. Si Terra n’est pas disponible, signale-le et poursuis avec le parent ; ne substitue pas silencieusement un autre fournisseur.
- Donne à chaque worker un périmètre explicite, le contexte minimal et les critères de réussite. Rappelle qu’il n’est pas seul et ne doit pas annuler les changements des autres. Deux workers utiles valent mieux qu’un essaim de microtâches ; ne redélègue pas le même travail.

AVANT DE MODIFIER
Lis les AGENTS.md applicables et docs/MCP_SYNC_AUDIT_2026-11-01.md. Inspecte git status : le workspace contient beaucoup de travail non commité à préserver. Pour des sessions simultanées, travaille sur une copie/branche isolée issue du même état courant sauvegardé, comprenant ces changements ; un worktree créé uniquement depuis HEAD ne les contient pas. Ne nettoie, stash ou commit pas le travail d’autrui. N’expose pas de secrets dans les rapports. Vérifie les callers et les tests avant de modifier le code partagé.

MISSION — P1 : corriger les défauts établis du transport, de l’authentification et du diagnostic MCP.

Périmètre réservé : server/index.mjs et tests HTTP/transport pertinents ; server/mcp.mjs seulement pour les diagnostics communs indispensables. N’édite pas server/public/consent.*, les fichiers Swift ni la configuration App ChatGPT. Ne change pas encore la sémantique corbeille/dossiers.

Délégation utile : un worker sur les échanges HTTP et leur couverture ; un second sur l’authentification/claims et les exigences officielles. L’orchestrateur arbitre les constats, intègre les petites corrections et revoit les tests. Vérifie la version de protocole effectivement prise en charge par SDK et client : les exigences de handshake/session varient selon les versions.

1. Établis une matrice : requêtes anonymes, jetons invalides, utilisateur valide, client OAuth réel, méthode HTTP incorrecte, requête malformée, annulation, indisponibilité Supabase et tailles limites. Distingue clairement les vérifications locales, simulées et de production.
2. Inspecte les claims réellement émis et ce que getUser valide. Compare avec les exigences MCP actuelles d’issuer, audience/destination, resource et client OAuth. Vérifie ce que Supabase supporte avant d’imposer une règle ; n’invente pas une audience qui rejetterait tous les jetons. Préserve l’isolation RLS et n’introduis pas de clé administrateur dans le client ou le plugin.
3. Vérifie Origin selon les clients pris en charge, les délais, la fermeture des transports, les statuts OAuth et les erreurs transitoires. Ajoute uniquement les correctifs justifiés avec tests d’acceptation/rejet ; évite une refonte de l’authentification fondée sur des hypothèses.
4. Réutilise une journalisation simple pour enregistrer identifiant de corrélation, étape, code et durée. Ne journalise ni Authorization/cookies, ni jetons, mots de passe, liens signés, titres ou contenu de carnet. Ajoute un test de non-divulgation si tu ajoutes cette logique.
5. Exécute npm test. Complète la couverture du véritable transport HTTP authentifié quand possible : les tests SDK en mémoire ne valident pas le middleware de production. La session App ChatGPT reste propriétaire de sa configuration et de la validation client.
6. Évalue l’hébergement seulement si des traces indiquent un problème réseau, temps limite, taille ou cycle de vie. Le projet actuel utilise le runtime container Vercel. La documentation actuelle lui applique les limites des Functions, dont 4,5 Mo pour les corps de requête/réponse : vérifie les tailles réelles, le streaming et les transferts déjà implémentés avant de conclure que cette limite intervient ici. Railway n’est une proposition pertinente qu’avec un cas reproductible, une comparaison et un coût explicités. Aucune migration automatique.

Livre les défauts confirmés, leur effet concret, la correction minimale, les tests et les limites restantes. Prépare un candidat de déploiement reviewable ; coordonne sa mise en production après les résultats de la session App pour ne pas changer sa cible en cours d’analyse. N’affirme pas que tout fonctionne depuis ChatGPT sans l’appel réel de cette session.
