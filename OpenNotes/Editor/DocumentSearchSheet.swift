import SwiftUI

struct DocumentSearchHit: Identifiable, Sendable {
    let id: Int
    let pageID: UUID
    let pageIndex: Int
    let snippet: String
    /// The text actually matched (may differ from the query in smart search), used for highlighting.
    var term: String = ""
    var exact = true
}

enum DocumentSearch {
    static let limit = 200
    private static let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    // Nonisolated async: runs off the main actor, and checks cancellation so stale queries stop early.
    /// Always ignores case and accents. `smart` also finds pages holding every word of the query in any order,
    /// and words that differ by a plural or a small typo; exact matches are listed first.
    static func run(_ pages: [NotePage], query: String, smart: Bool = AppPreferences.smartSearch) async -> [DocumentSearchHit] {
        var hits: [DocumentSearchHit] = []
        for page in pages {
            if Task.isCancelled || hits.count >= limit { break }
            let text = page.searchableText as NSString
            var range = NSRange(location: 0, length: text.length)
            while hits.count < limit {
                let found = text.range(of: query, options: options, range: range)
                guard found.location != NSNotFound, found.length > 0 else { break }
                hits.append(.init(id: hits.count, pageID: page.id, pageIndex: page.index, snippet: snippet(text, found), term: query))
                range = NSRange(location: found.upperBound, length: text.length - found.upperBound)
            }
        }
        guard smart, hits.count < limit else { return hits }
        let words = tokens(query).filter { $0.count >= 2 }
        guard !words.isEmpty else { return hits }
        let exactPages = Set(hits.map(\.pageID))
        for page in pages where !exactPages.contains(page.id) {
            if Task.isCancelled || hits.count >= limit { break }
            let text = page.searchableText as NSString
            // ponytail: tokenizes each page per query; cache tokens per page revision if large PDFs feel slow.
            let pageWords = Set(tokens(page.searchableText))
            var matched: [String] = []
            for word in words {
                guard let hit = pageWords.first(where: { similar(word, $0) }) else { matched = []; break }
                matched.append(hit)
            }
            guard let first = matched.first else { continue }
            let found = text.range(of: first, options: options)
            guard found.location != NSNotFound else { continue }
            hits.append(.init(id: hits.count, pageID: page.id, pageIndex: page.index, snippet: snippet(text, found), term: first, exact: false))
        }
        return hits
    }
    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    /// Same word, a prefix of it (3+ letters), a plural, or up to 1 (2 for long words) typos. Inputs are folded.
    static func similar(_ query: String, _ word: String) -> Bool {
        if query == word { return true }
        if query.count >= 3, word.hasPrefix(query) { return true }
        func stem(_ value: String) -> Substring { value.count > 3 && (value.hasSuffix("s") || value.hasSuffix("x")) ? value.dropLast() : Substring(value) }
        if stem(query) == stem(word) { return true }
        let allowed = query.count >= 8 ? 2 : query.count >= 4 ? 1 : 0
        guard allowed > 0, abs(query.count - word.count) <= allowed else { return false }
        return distance(Array(query), Array(word), limit: allowed) <= allowed
    }
    /// Levenshtein distance, giving up once every path exceeds `limit`.
    static func distance(_ a: [Character], _ b: [Character], limit: Int) -> Int {
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1))
            }
            if current.min()! > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
    static func snippet(_ text: NSString, _ match: NSRange, context: Int = 40) -> String {
        let start = max(0, match.location - context), end = min(text.length, match.upperBound + context)
        let body = text.substring(with: NSRange(location: start, length: end - start))
            .components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (start > 0 ? "…" : "") + body + (end < text.length ? "…" : "")
    }
}

struct DocumentSearchPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var store: LibraryStore
    let closeOnSelection: Bool
    let close: () -> Void
    @State private var query = ""
    @State private var searchedQuery = ""
    @State private var hits: [DocumentSearchHit] = []
    @State private var indexing = false
    @State private var searching = false
    @FocusState private var focused: Bool
    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var groups: [(page: Int, hits: [DocumentSearchHit])] {
        var result: [(page: Int, hits: [DocumentSearchHit])] = []
        for hit in hits {
            if result.last?.page == hit.pageIndex { result[result.count - 1].hits.append(hit) }
            else { result.append((hit.pageIndex, [hit])) }
        }
        return result
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Search").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                Button(action: close) {
                    Label("Close search", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.accessibilityIdentifier("editor.search.close")
            }.padding(.horizontal, 8).padding(.vertical, 4).background(Color(uiColor: .secondarySystemBackground))
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Document text", text: $query)
                    .focused($focused).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("editor.search.field")
                if !query.isEmpty {
                    Button { query = "" } label: { Label("Clear text", systemImage: "xmark.circle.fill").labelStyle(.iconOnly) }
                        .foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
                }
            }.padding(.horizontal, 10).frame(minHeight: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                .padding(8)
            Divider()
            List {
                if indexing { ProgressView("Reading PDF text…") }
                ForEach(groups, id: \.page) { group in
                    Section("Page \(group.page + 1)") {
                        ForEach(group.hits) { hit in
                            Button { Task { await select(hit) } } label: {
                                Text(hit.snippet).font(.callout).foregroundStyle(hit.exact ? .primary : .secondary).lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityHint("Opens page \(group.page + 1) and highlights the match")
                        }
                    }
                }
                if hits.count >= DocumentSearch.limit { Text("Showing the first \(DocumentSearch.limit) results").font(.footnote).foregroundStyle(.secondary) }
                if hits.isEmpty && !trimmed.isEmpty && !indexing && !searching && searchedQuery == trimmed { Text("No results") }
                Text("Search uses PDF text, typed notes and recognized handwriting.").font(.footnote).foregroundStyle(.secondary)
            }.listStyle(.plain)
        }
        .task { focused = true; indexing = true; await store.indexPDFText(in: session.noteID); indexing = false }
        .task(id: "\(trimmed)|\(indexing)") {
            let current = trimmed
            guard !current.isEmpty else { hits = []; searchedQuery = ""; return }
            searching = true; defer { searching = false }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await DocumentSearch.run(store.library.pages(in: session.noteID), query: current)
            guard !Task.isCancelled else { return }
            hits = found; searchedQuery = current
        }
    }
    private func select(_ hit: DocumentSearchHit) async {
        let term = hit.term.isEmpty ? searchedQuery : hit.term
        await session.open(hit.pageID)
        guard let page = session.page, page.id == hit.pageID else { return }
        var rects: [CGRect] = []
        if let index = page.pdfIndex, let name = page.backgroundID {
            rects = await PDFMatchFinder.shared.rects(resource: name, disk: store.disk, pageIndex: index, query: term, size: PageRenderer.size(page))
        }
        if rects.isEmpty {
            // ponytail: OCR/non-PDF sources only have line blocks, so the whole line is highlighted.
            let blocks = (page.pdfText?.blocks ?? []) + (page.ocrText?.drawingRevision == (page.drawingRevision ?? 0) ? page.ocrText?.blocks ?? [] : [])
            rects = blocks.filter { $0.text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
                .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        }
        guard session.page?.id == hit.pageID else { return }
        session.searchHighlights = rects
        if closeOnSelection { close() }
    }
}
