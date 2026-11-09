# OpenNotes — Audit d'architecture et d'optimisation (2026-11-05)

Source : lecture du code (≈16 500 lignes Swift app + tests), docs existantes (`ARCHITECTURE.md`, `HYBRID_ARCHITECTURE_AUDIT.md`). **Aucune mesure sur appareil** : aucune latence, FPS ou mémoire n'est affirmée ici. Les points marqués *hypothèse* sont à confirmer avec Instruments.

## 1. Diagnostic

Application SwiftUI (bibliothèque, réglages) + UIKit pour tout ce qui touche au Pencil. Pas de PencilKit : moteur d'encre maison.

| Sous-système | Implémentation réelle |
|---|---|
| Capture | `InkCanvasView` (UIScrollView) → `InkContentView.touches*` ; coalesced + predicted touches, `InkSampleBuffer` (`InkCanvasView.swift:34`) |
| Rendu live | 1 `CAShapeLayer` par trait validé + 1 layer `preview` ; `CGPath` rempli (cercles + quads par segment) — `InkStroke.paintedPath` (`InkDocument.swift:248`). Pas de Metal. |
| Traitement | `StrokeProcessing.process` : lissage causal One-Euro, pression, style — reprocessé sur **tous** les échantillons à chaque `touchesMoved` (`showPreview` → `makeStroke`) |
| Gomme | `InkSpatialIndex` (grille 128 pt) construit au début du geste ; `EraserEditing.erase` en booléens `CGPath` (subtracting/intersection) sur le thread principal |
| Lasso / sélection | `PageSelectionView`, `SelectionGeometry`, aperçu bitmap déplacé par UIKit |
| Post-it | `StickyNoteControl` (UIKit) + `StickyInkOcclusion` (masques `CAShapeLayer` par booléens de chemins) |
| PDF | `PageArtwork` (CGPDFDocument une fois) → `TiledPaperView` ; PDFKit pour texte/export |
| Persistance | `DiskStore` (actor) : `library.json` atomique + journal + backup, ressources séparées ; 1 fichier JSON de dessin par révision de page (`writeDrawingRevision`) |
| Sync | `CloudSync` (Supabase, expérimental) |
| Tests | ~260 tests XCTest ; aucun benchmark, aucun signpost |

Verdict : l'architecture est cohérente et proportionnée. La frontière « SwiftUI = chrome, UIKit = interaction » est bonne. Le principal risque n'est pas le langage mais (a) la complexité de quelques fichiers, (b) des travaux O(n) répétés sur le thread principal, (c) l'absence totale de mesure.

## 2. Choix technologiques par sous-système

| Sous-système | Garder | Considéré | Décision |
|---|---|---|---|
| Capture Pencil | UIKit touches | PencilKit | **Garder.** PencilKit n'expose pas le modèle de données voulu (échantillons bruts, styles, fragments éditables). Coût de migration élevé, gain nul. |
| Rendu live | CAShapeLayer | Metal | **Garder pour l'instant.** Metal ne se justifie que si Instruments montre des frames > budget avec des pages très denses (milliers de traits visibles). Les layers sont déjà cachés par trait. Risque : réécrire masques sticky, gomme, export. |
| Traitement d'un trait | Swift | Rust | **Garder.** Le travail par trait est petit ; un appel FFI par `touchesMoved` ajoute copies et complexité sans gain démontré. |
| Gomme/booléens de chemins | CoreGraphics | Rust (`i_overlay`/Clipper) | **Hypothèse à mesurer** : les booléens `CGPath` sont le seul candidat plausible à un vrai gain, mais n'ont de sens que déplacés hors du thread principal, ce qui s'obtient aussi en Swift. Mesurer d'abord. |
| Validation/archive/sync | Swift + Node | Rust partagé | **Reporter** (cohérent avec l'audit hybride du 2026-11-02) : seulement s'il y a un 2ᵉ client. |
| PDF | PDFKit/CGPDF | — | **Garder.** Voir corrections ci-dessous. |
| Persistance | JSON atomique | SQLite/binaire | **Garder le format** ; envisager un encodage compact si la taille mesurée le justifie (voir risques). |

Conclusion franche : **aucun portage Rust n'est justifié par le code actuel.** Les gains disponibles sont algorithmiques/structurels en Swift.

## 3. Problèmes constatés

### Réels (code lu, comportement certain)
1. **PDF reparsé à chaque rafraîchissement d'aperçu** — `TiledPaperView` appelait `PageRenderer.image(... data:)` sans `pdfPage`/`images` ; `PageRenderer.background` refaisait donc `PDFDocument(data:)` (PDF entier) et redécodait les images à chaque aperçu (≈100 ms après chaque modification). **Corrigé.**
2. **Export PDF : un parse complet du PDF source par page exportée** (`PageRenderer.export`). O(pages × taille PDF). **Corrigé.**
3. **Scribble-erase : deux sérialisations JSON de la page entière sur le thread principal** à chaque fin de trait détecté comme gribouillis (`WritingCanvas.completed`). **Corrigé.**
4. `updateUIView` recalculait à chaque mise à jour SwiftUI un `Set` de tous les traits cachés et balayait toutes les layers (`hiddenStrokeIDs.didSet`), même sans post-it replié. **Corrigé** (court-circuit + écriture conditionnelle).

### Réels, non corrigés (risque/effort plus élevé)
5. **Aperçu live en O(n²) par trait** : chaque `touchesMoved` retraite tous les échantillons (`StrokeProcessing.process`) puis reconstruit `paintedPath` entier. Le filtre est causal (commentaire dans le code), donc un traitement incrémental est possible. Impact probable uniquement sur traits très longs.
6. **Sauvegarde proportionnelle à la bibliothèque** : chaque autosave (700 ms) ré-encode tout `library.json` (avec `pdfText`/`ocrText`), puis re-décode l'ancien fichier pour valider le backup (`DiskStore.save`). Acteur donc hors thread principal, mais coût CPU/IO croissant avec les PDF indexés.
7. **Miniatures de pages PDF** : `DiskStore.thumbnail` relit tout le fichier de fond et reparse le PDF pour chaque miss de cache.
8. **Format de dessin** : JSON avec `path` ET `rawSamples` (≈2× les échantillons), doubles en texte. Taille/temps d'encodage à mesurer sur un gros dessin.
9. **Gomme + masques sticky sur le thread principal** : `subtracting`/`intersection` de `CGPath` par trait touché à chaque mouvement.

### Bugs/qualité (pas de perf)
- `WritingCanvas.updateUIView` (~190 lignes) mélange configuration, closures de gestes, et logique de sélection : difficile à tester, source probable de régressions. `WritingCanvas.swift` fait 1 062 lignes (`PageScrollView` + coordinator).
- Plusieurs `try?` et comparaisons par sérialisation (`dataRepresentation()` encore utilisé comme « égalité ») : un échec d'encodage donne `Data()` et deux dessins invalides paraissent égaux.
- Duplication de la logique « masque sticky » entre `mask(for:)` et `visible(_:)`.

### Hypothèses à vérifier
- Budget de frame avec ~5 000 traits visibles (coût de composition des `CAShapeLayer`, pas de rasterisation de tuile).
- Latence perçue du preview (fréquence réelle des `touchesMoved` × coût de `makeStroke`).
- Mémoire avec plusieurs notebooks PDF ouverts (`PageArtwork` garde `Data` + images + `CGPDFPage`).

## 4. Mesurer (rien n'est inventé ici)
- Ajouter `OSSignposter` autour de : `showPreview`, `previewErasing`, `InkContentView.install`, `EditorSession.flush`, `DiskStore.save`, `PageRenderer.image`. Instruments : *Time Profiler* + *Animation Hitches* + *Allocations* sur iPad physique, build Release.
- Benchmarks `measure {}` XCTest (sans UI) : `StrokeProcessing.process` avec 200/1 000/5 000 échantillons ; `EraserEditing.erase` avec 1 000 traits ; `InkDrawing.encodedData` avec 100 000 échantillons ; `PageRenderer.export` sur un PDF de 100 pages.
- Scénario reproductible : fixtures de pages denses générées en code, mêmes entrées avant/après.

## 5. Architecture cible (incrémentale)
- **SwiftUI** : bibliothèque, réglages, barres d'outils, feuilles. Inchangé.
- **UIKit/natif** : capture Pencil, scroll/zoom, sélection, post-it. Inchangé ; découper `WritingCanvas.swift` (coordinator, `PageScrollView`, configuration) en fichiers distincts.
- **Core Graphics/CALayer** : rendu. Metal seulement si les mesures de l'item « hypothèses » l'exigent.
- **Rust** : aucun. Réévaluer uniquement pour (1) un second client, ou (2) booléens de chemins mesurés comme goulot *après* déplacement hors thread principal.
- **À refactoriser** : sortie de `updateUIView` de la logique de sélection ; remplacement des égalités par sérialisation ; traitement incrémental du preview.

## 6. Plan priorisé

| # | Action | Impact | Effort | Risque |
|---|---|---|---|---|
| 1 | Signposts + benchmarks (section 4) | Élevé (débloque tout) | Faible | Nul |
| 2 | Aperçu live incrémental (item 5) | Moyen–élevé sur traits longs | Moyen | Moyen (parité visuelle live/sauvegardé) |
| 3 | Cache `CGPDFDocument` par ressource dans `DiskStore.thumbnail` (item 7) | Moyen sur PDF | Faible | Faible |
| 4 | Backup sans re-décodage complet / séparer `pdfText` du snapshot (item 6) | Moyen | Moyen | Moyen (intégrité) |
| 5 | Gomme : déplacer booléens hors main thread (item 9) | À mesurer | Moyen | Moyen |
| 6 | Découper `WritingCanvas.swift` | Maintenabilité | Moyen | Faible |
| 7 | Format dessin compact (item 8) | À mesurer | Élevé (migration) | Élevé |
| 8 | Metal / Rust | Non démontré | Très élevé | Élevé |

## 7. Optimisations réalisées
Fichiers : `PageRenderer.swift` (paramètres `pdfPage`/`images` sur `image`, cache `CGPDFDocument` dans `export`), `TiledPaperView.swift` (passe `artwork.pdfPage`/`images`), `EraserEditing.swift` (`changed(_:_:)`), `WritingCanvas.swift` (comparaison sans JSON ; ensemble caché conditionnel). Test ajouté : `EraserGeometryTests.testChangedDetectsEveryEraseOutcomeWithoutEncoding`.

**Validation** : compilation iOS Simulator réussie (`xcodebuild test` a construit app + tests). Exécution : `EraserGeometryTests` (11 tests, dont le nouveau) passe sur iPhone 17 / iOS 27.0, 0 échec. La suite complète n'a **pas** été exécutée : sur iPhone 18 Pro l'hôte de test est tué au lancement (« signal kill before establishing connection »), deux fois, cause non établie. Aucun gain de performance n'est mesuré ni revendiqué ; les corrections 1–2 suppriment un travail redondant par construction.

## 8. Prochaines sessions
1. Faire passer la suite de tests (résoudre le crash de l'hôte de test) avant de fusionner ces changements.
2. Poser les signposts et benchmarks, puis relever des chiffres sur iPad.
3. Décider du preview incrémental sur la base des chiffres.
4. Découper `WritingCanvas.swift` quand une zone sera touchée de toute façon.

## 9. Second passe (2026-11-06) — corrections des points 5 à 9
- **Aperçu live** : `StrokeProcessing.Live` (même arithmétique que le traitement final, partagée) traite chaque échantillon une seule fois ; seules les prédictions sont refaites. Contour incrémental (`InkStroke.addOutline`) pour les styles pleins sans pointe ; patterns/pointes gardent la reconstruction complète (dépendent de la longueur totale). Test d'équivalence ajouté.
- **Gomme** : `InkVectorPath.cgPath` et `InkStroke.paintedPath`/`renderBounds` mis en cache (invalidation à la mutation) ; test d'intersection fait dans l'espace du trait (plus de copie du chemin entier par mouvement) ; pré-filtre par boîte englobante avant le calcul. Reste sur le thread principal (volontairement : l'asynchronisme change l'ordre aperçu/commit, non mesurable sans appareil).
- **Post-it** : `renderBounds` n'est plus recalculé pour chaque note dans `covers`.
- **Autosave** : plus de décodage de l'ancienne bibliothèque ni du backup quand le fichier est identique à ce que le store vient d'écrire. Le ré-encodage complet (pdfText/OCR inclus) subsiste : le supprimer demande de déplacer ces textes hors de `library.json` (changement de format, non fait).
- **Miniatures PDF** : un `CGPDFDocument` par ressource (max 3, invalidé par génération) au lieu d'une relecture + parse par miniature.
- **Autres** : recherche bibliothèque sans concaténation du texte de chaque page (un seul balayage au lieu d'un par note) ; `validate` en O(pages) au lieu de O(notes × pages).
- Validation : 275 tests XCTest passent sur iPhone 17 (iOS 27.0). Aucune mesure de performance sur appareil.
