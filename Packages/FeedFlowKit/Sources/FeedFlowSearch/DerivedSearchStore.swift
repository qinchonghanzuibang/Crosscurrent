import Foundation
import FeedFlowStorage
import GRDB

public actor DerivedSearchStore {
    private let database: DatabaseQueue

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }
        database = try DatabaseQueue(path: directory.appending(path: "Lexical.sqlite").path, configuration: configuration)
        try database.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS index_state (key TEXT PRIMARY KEY, value TEXT NOT NULL) STRICT")
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS current_fts USING fts5(kind UNINDEXED, stable_id UNINDEXED, revision_id UNINDEXED, language_code UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2')")
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS current_trigram USING fts5(kind UNINDEXED, stable_id UNINDEXED, revision_id UNINDEXED, title, body, tokenize='trigram')")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS current_short_cjk (token TEXT NOT NULL, token_length INTEGER NOT NULL, kind TEXT NOT NULL, stable_id TEXT NOT NULL, revision_id TEXT, title TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(token, token_length, kind, stable_id)) WITHOUT ROWID, STRICT")
            try db.execute(sql: "CREATE INDEX IF NOT EXISTS current_short_cjk_document ON current_short_cjk(kind, stable_id)")
            try db.execute(sql: "CREATE VIRTUAL TABLE IF NOT EXISTS historical_fts USING fts5(kind UNINDEXED, stable_id UNINDEXED, revision_id UNINDEXED, language_code UNINDEXED, title, body, tokenize='unicode61 remove_diacritics 2')")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS historical_short_cjk (token TEXT NOT NULL, token_length INTEGER NOT NULL, kind TEXT NOT NULL, stable_id TEXT NOT NULL, revision_id TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(token, token_length, kind, stable_id, revision_id)) WITHOUT ROWID, STRICT")
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS indexed_documents (document_key TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, stable_id TEXT NOT NULL, revision_id TEXT, is_historical INTEGER NOT NULL) STRICT")
        }
    }

    public func index(_ document: SearchDocument) throws {
        try database.write { db in
            try index(document, db: db)
            try remember(document, db: db)
        }
    }

    public func synchronize(_ documents: [SearchDocument], canonicalGeneration: Int64) throws {
        try database.write { db in
            let desired = Dictionary(uniqueKeysWithValues: documents.map { (Self.documentKey($0), $0) })
            let existing = try Row.fetchAll(db, sql: "SELECT * FROM indexed_documents")
            for row in existing where desired[row["document_key"] as String] == nil {
                let kind: String = row["kind"]
                let stableID: String = row["stable_id"]
                let historical: Bool = row["is_historical"]
                if historical, let revisionID: String = row["revision_id"] {
                    try db.execute(sql: "DELETE FROM historical_fts WHERE kind=? AND stable_id=? AND revision_id=?", arguments: [kind, stableID, revisionID])
                    try db.execute(sql: "DELETE FROM historical_short_cjk WHERE kind=? AND stable_id=? AND revision_id=?", arguments: [kind, stableID, revisionID])
                } else {
                    try db.execute(sql: "DELETE FROM current_fts WHERE kind=? AND stable_id=?", arguments: [kind, stableID])
                    try db.execute(sql: "DELETE FROM current_trigram WHERE kind=? AND stable_id=?", arguments: [kind, stableID])
                    try db.execute(sql: "DELETE FROM current_short_cjk WHERE kind=? AND stable_id=?", arguments: [kind, stableID])
                }
                try db.execute(sql: "DELETE FROM indexed_documents WHERE document_key=?", arguments: [row["document_key"] as String])
            }
            for document in documents {
                try index(document, db: db)
                try remember(document, db: db)
            }
            try db.execute(sql: "INSERT INTO index_state (key, value) VALUES ('canonical_generation', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [String(canonicalGeneration)])
        }
    }

    public func removeCurrent(kind: SearchDocumentKind, stableID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM current_fts WHERE kind=? AND stable_id=?", arguments: [kind.rawValue, stableID])
            try db.execute(sql: "DELETE FROM current_trigram WHERE kind=? AND stable_id=?", arguments: [kind.rawValue, stableID])
            try db.execute(sql: "DELETE FROM current_short_cjk WHERE kind=? AND stable_id=?", arguments: [kind.rawValue, stableID])
        }
    }

    public func search(_ query: SearchQuery) throws -> [SearchResult] {
        let trimmed = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !query.kinds.isEmpty else { return [] }
        let limit = max(1, min(query.limit, 200))
        return try database.read { db in
            var results: [SearchResult] = []
            if let short = BilingualTokenizer.shortHanQueryToken(trimmed) {
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT kind, stable_id, revision_id, title, body FROM current_short_cjk WHERE token=? AND token_length=? LIMIT ?",
                    arguments: [short.token, short.length, limit * 3]
                )
                results += rows.compactMap { makeResult(row: $0, score: short.length == 2 ? 2.0 : 1.7, historical: false, query: trimmed) }
                if query.includeHistory {
                    let historyRows = try Row.fetchAll(
                        db,
                        sql: "SELECT kind, stable_id, revision_id, title, body FROM historical_short_cjk WHERE token=? AND token_length=? LIMIT ?",
                        arguments: [short.token, short.length, limit]
                    )
                    results += historyRows.compactMap { makeResult(row: $0, score: short.length == 2 ? 1.2 : 1.0, historical: true, query: trimmed) }
                }
            } else {
                let ftsExpression = Self.ftsExpression(trimmed)
                let wordRows = try Row.fetchAll(
                    db,
                    sql: "SELECT kind, stable_id, revision_id, title, body, bm25(current_fts, 6.0, 1.0) AS rank FROM current_fts WHERE current_fts MATCH ? ORDER BY rank LIMIT ?",
                    arguments: [ftsExpression, limit * 2]
                )
                results += wordRows.compactMap { row in makeResult(row: row, score: 1 / (1 + abs(row["rank"] as Double)), historical: false, query: trimmed) }
                if Array(trimmed).count >= 3 {
                    let trigramRows = try Row.fetchAll(
                        db,
                        sql: "SELECT kind, stable_id, revision_id, title, body, bm25(current_trigram, 5.0, 1.0) AS rank FROM current_trigram WHERE current_trigram MATCH ? ORDER BY rank LIMIT ?",
                        arguments: [Self.ftsExpression(trimmed), limit]
                    )
                    results += trigramRows.compactMap { row in makeResult(row: row, score: 0.8 / (1 + abs(row["rank"] as Double)), historical: false, query: trimmed) }
                }
            }

            if query.includeHistory, BilingualTokenizer.shortHanQueryToken(trimmed) == nil {
                let historyRows = try Row.fetchAll(
                    db,
                    sql: "SELECT kind, stable_id, revision_id, title, body, bm25(historical_fts, 6.0, 1.0) AS rank FROM historical_fts WHERE historical_fts MATCH ? ORDER BY rank LIMIT ?",
                    arguments: [Self.ftsExpression(trimmed), limit]
                )
                results += historyRows.compactMap { row in makeResult(row: row, score: 0.6 / (1 + abs(row["rank"] as Double)), historical: true, query: trimmed) }
            }

            let allowedKinds = Set(query.kinds.map(\.rawValue))
            var best: [String: SearchResult] = [:]
            for result in results where allowedKinds.contains(result.kind.rawValue) {
                let groupingKey = result.isHistorical ? result.id : "\(result.kind.rawValue):\(result.stableID):current"
                if result.score > best[groupingKey]?.score ?? -.infinity { best[groupingKey] = result }
            }
            return best.values.sorted { lhs, rhs in lhs.score == rhs.score ? lhs.title < rhs.title : lhs.score > rhs.score }.prefix(limit).map { $0 }
        }
    }

    public func setIndexedGeneration(_ generation: Int64) throws {
        try database.write { db in
            try db.execute(sql: "INSERT INTO index_state (key, value) VALUES ('canonical_generation', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", arguments: [String(generation)])
        }
    }

    public func indexedGeneration() throws -> Int64 {
        try database.read { db in
            Int64(try String.fetchOne(db, sql: "SELECT value FROM index_state WHERE key='canonical_generation'") ?? "0") ?? 0
        }
    }

    private func insertShort(token: String, length: Int, document: SearchDocument, db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO current_short_cjk (token, token_length, kind, stable_id, revision_id, title, body) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [token, length, document.kind.rawValue, document.stableID, document.revisionID, document.title, document.body]
        )
    }

    private func index(_ document: SearchDocument, db: Database) throws {
        if document.isHistorical {
            guard let revisionID = document.revisionID else { return }
            try db.execute(sql: "DELETE FROM historical_fts WHERE kind=? AND stable_id=? AND revision_id=?", arguments: [document.kind.rawValue, document.stableID, revisionID])
            try db.execute(sql: "DELETE FROM historical_short_cjk WHERE kind=? AND stable_id=? AND revision_id=?", arguments: [document.kind.rawValue, document.stableID, revisionID])
            try db.execute(sql: "INSERT INTO historical_fts (kind, stable_id, revision_id, language_code, title, body) VALUES (?, ?, ?, ?, ?, ?)", arguments: [document.kind.rawValue, document.stableID, revisionID, document.languageCode, document.title, document.body])
            let tokens = BilingualTokenizer.tokenize(document.title + " " + document.body, languageCode: document.languageCode)
            for token in tokens.hanUnigrams { try insertHistoricalShort(token: token, length: 1, revisionID: revisionID, document: document, db: db) }
            for token in tokens.hanBigrams { try insertHistoricalShort(token: token, length: 2, revisionID: revisionID, document: document, db: db) }
            return
        }
        try db.execute(sql: "DELETE FROM current_fts WHERE kind=? AND stable_id=?", arguments: [document.kind.rawValue, document.stableID])
        try db.execute(sql: "DELETE FROM current_trigram WHERE kind=? AND stable_id=?", arguments: [document.kind.rawValue, document.stableID])
        try db.execute(sql: "DELETE FROM current_short_cjk WHERE kind=? AND stable_id=?", arguments: [document.kind.rawValue, document.stableID])
        try db.execute(sql: "INSERT INTO current_fts (kind, stable_id, revision_id, language_code, title, body) VALUES (?, ?, ?, ?, ?, ?)", arguments: [document.kind.rawValue, document.stableID, document.revisionID, document.languageCode, document.title, document.body])
        try db.execute(sql: "INSERT INTO current_trigram (kind, stable_id, revision_id, title, body) VALUES (?, ?, ?, ?, ?)", arguments: [document.kind.rawValue, document.stableID, document.revisionID, document.title, document.body])
        let tokens = BilingualTokenizer.tokenize(document.title + " " + document.body, languageCode: document.languageCode)
        for token in tokens.hanUnigrams { try insertShort(token: token, length: 1, document: document, db: db) }
        for token in tokens.hanBigrams { try insertShort(token: token, length: 2, document: document, db: db) }
    }

    private func remember(_ document: SearchDocument, db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO indexed_documents (document_key, kind, stable_id, revision_id, is_historical) VALUES (?, ?, ?, ?, ?)",
            arguments: [Self.documentKey(document), document.kind.rawValue, document.stableID, document.revisionID, document.isHistorical]
        )
    }

    private static func documentKey(_ document: SearchDocument) -> String {
        "\(document.isHistorical ? "history" : "current"):\(document.kind.rawValue):\(document.stableID):\(document.revisionID ?? "")"
    }

    private func insertHistoricalShort(token: String, length: Int, revisionID: String, document: SearchDocument, db: Database) throws {
        try db.execute(
            sql: "INSERT OR REPLACE INTO historical_short_cjk (token, token_length, kind, stable_id, revision_id, title, body) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [token, length, document.kind.rawValue, document.stableID, revisionID, document.title, document.body]
        )
    }

    private func makeResult(row: Row, score: Double, historical: Bool, query: String) -> SearchResult? {
        guard let kind = SearchDocumentKind(rawValue: row["kind"]) else { return nil }
        let body: String = row["body"]
        return SearchResult(
            stableID: row["stable_id"],
            kind: kind,
            revisionID: row["revision_id"],
            title: row["title"],
            snippet: Self.snippet(body, around: query),
            score: score,
            isHistorical: historical
        )
    }

    private static func ftsExpression(_ input: String) -> String {
        let tokens = BilingualTokenizer.tokenize(input).words
        let safe = tokens.isEmpty ? [input] : tokens
        return safe.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " AND ")
    }

    private static func snippet(_ body: String, around query: String, maximum: Int = 220) -> String {
        guard body.count > maximum else { return body }
        let range = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        let center = range?.lowerBound ?? body.startIndex
        let distance = min(maximum / 2, body.distance(from: body.startIndex, to: center))
        let start = body.index(center, offsetBy: -distance)
        let end = body.index(start, offsetBy: min(maximum, body.distance(from: start, to: body.endIndex)))
        return (start > body.startIndex ? "…" : "") + body[start..<end] + (end < body.endIndex ? "…" : "")
    }
}

public enum ReciprocalRankFusion {
    public static func fuse(lexical: [SearchResult], semantic: [(String, Double)], constant: Double = 60) -> [String: Double] {
        var scores: [String: Double] = [:]
        for (index, result) in lexical.enumerated() { scores[result.stableID, default: 0] += 1 / (constant + Double(index + 1)) }
        for (index, result) in semantic.enumerated() { scores[result.0, default: 0] += 1 / (constant + Double(index + 1)) }
        return scores
    }
}
