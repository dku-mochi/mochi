import Foundation
import ComposableArchitecture
import CoreDomain

/// 검색 서비스 추상 — 로컬 literal 검색(키 입력 즉답)의 시그니처.
///
/// 로컬: 실데이터 dataset 위에서 token-contains + intent EXISTS 필터.
/// 서버 의미 검색(RAG citations)은 SearchFeature.semanticSearch 가 return 제출 시 보강한다.
public protocol SearchService: Sendable {
    func search(
        query: String,
        intent: Intent?,
        in dataset: [MochiItem]
    ) async -> [SearchResult]
}

public struct LocalSearchService: SearchService {
    public init() {}

    public func search(
        query: String,
        intent: Intent?,
        in dataset: [MochiItem]
    ) async -> [SearchResult] {
        let tokens = Self.tokenize(query)

        let candidates = dataset.filter { item in
            if let intent {
                guard item.instances.contains(where: { $0.intentType == intent }) else {
                    return false
                }
            }
            if tokens.isEmpty { return true }
            let haystack = Self.haystackText(for: item)
            return tokens.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
        }

        let sorted = candidates.sorted { $0.source.capturedAt > $1.source.capturedAt }

        return sorted.map { item in
            let title = item.instances.first?.label
                ?? item.analysis?.summary
                ?? item.source.text
                ?? ""
            return SearchResult(
                item: item,
                titleHighlights: Self.highlights(in: title, tokens: tokens),
                summaryHighlights: Self.highlights(in: item.analysis?.summary ?? "", tokens: tokens)
            )
        }
    }

    // MARK: - Helpers

    private static func tokenize(_ query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func haystackText(for item: MochiItem) -> String {
        var parts: [String] = []
        if let summary = item.analysis?.summary { parts.append(summary) }
        if let text = item.source.text { parts.append(text) }
        if let url = item.source.url { parts.append(url.absoluteString) }
        if let memo = item.source.userMemo { parts.append(memo) }
        for instance in item.instances {
            if let title = instance.payload.title { parts.append(title) }
            if let note = instance.payload.note { parts.append(note) }
            if let topic = instance.payload.topic { parts.append(topic) }
            if let person = instance.payload.person { parts.append(person) }
            if let label = instance.label { parts.append(label) }
        }
        return parts.joined(separator: " ")
    }

    private static func highlights(in text: String, tokens: [String]) -> [HighlightRange] {
        guard !text.isEmpty, !tokens.isEmpty else { return [] }
        let nsText = text as NSString
        var ranges: [HighlightRange] = []
        for token in tokens {
            var searchFrom = 0
            while searchFrom < nsText.length {
                let found = nsText.range(
                    of: token,
                    options: [.caseInsensitive],
                    range: NSRange(location: searchFrom, length: nsText.length - searchFrom)
                )
                if found.location == NSNotFound { break }
                ranges.append(HighlightRange(location: found.location, length: found.length))
                searchFrom = found.location + max(found.length, 1)
            }
        }
        return ranges.sorted { $0.location < $1.location }
    }
}

// MARK: - DI

private enum SearchServiceKey: DependencyKey {
    static let liveValue: any SearchService = LocalSearchService()
    static let previewValue: any SearchService = LocalSearchService()
    static let testValue: any SearchService = LocalSearchService()
}

public extension DependencyValues {
    var searchService: any SearchService {
        get { self[SearchServiceKey.self] }
        set { self[SearchServiceKey.self] = newValue }
    }
}
