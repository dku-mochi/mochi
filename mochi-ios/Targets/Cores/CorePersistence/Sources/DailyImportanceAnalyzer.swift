import Foundation
import Dependencies
import CoreDomain

/// 홈 "중요해 보여요" 섹션을 위한 **1일 1회 lazy** 분석기.
///
/// **현 단계 (디자인 + 백엔드 sync stage)**:
/// - 실제 Gemini 호출은 stub. 기존 `MochiItemAnalysis.importance` 값을 그대로 활용.
/// - 24시간 안에 이미 돌렸으면 캐시된 ID 리스트만 반환.
/// - 결과는 App Group `daily-importance/` 디렉토리에 `YYYY-MM-DD.json` 으로 저장
///   (사용자 요청: GCS 업로드 우회, filepath 만 저장).
///
/// **추후 (Gemini 1일 재분석 단계)**:
/// - `analyze()` 안에서 최근 24시간 항목 묶음을 Gemini 에 보내 importance 재산출.
/// - 항목 이미지는 GCS 업로드 없이 로컬 URI 만 참조 → 텍스트·메타데이터 기반 분석.
public protocol DailyImportanceAnalyzer: Sendable {
    /// 마지막 분석으로부터 24시간이 지났으면 재계산, 아니면 캐시 반환.
    /// 결과는 importance 내림차순으로 정렬된 mochiItem ID 리스트.
    func todaysImportant(limit: Int) async -> [UUID]
}

// MARK: - DI

public enum DailyImportanceAnalyzerKey: DependencyKey {
    public static let liveValue: any DailyImportanceAnalyzer = LiveDailyImportanceAnalyzer()
    public static let testValue: any DailyImportanceAnalyzer = StubDailyImportanceAnalyzer()
}

public extension DependencyValues {
    var dailyImportanceAnalyzer: any DailyImportanceAnalyzer {
        get { self[DailyImportanceAnalyzerKey.self] }
        set { self[DailyImportanceAnalyzerKey.self] = newValue }
    }
}

// MARK: - Live

/// Live 구현. Repository 는 직접 알지 못하고, 호출 시점에 `@Dependency(\.mochiItemRepository)` 로 가져옴.
public actor LiveDailyImportanceAnalyzer: DailyImportanceAnalyzer {
    public init() {}

    @Dependency(\.mochiItemRepository) private var repository

    public func todaysImportant(limit: Int) async -> [UUID] {
        if let cached = readCacheIfFresh() { return Array(cached.prefix(limit)) }
        return await recompute(limit: limit)
    }

    // MARK: - Cache

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = .init(identifier: .gregorian)
        f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    private static var cacheDirectory: URL {
        let url = AppGroup.containerURL.appendingPathComponent("daily-importance", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func cacheFile(for date: Date) -> URL {
        cacheDirectory.appendingPathComponent("\(dateFormatter.string(from: date)).json")
    }

    private struct CachePayload: Codable {
        var generatedAt: Date
        var mochiItemIDs: [UUID]
    }

    /// 24시간 안에 생성된 캐시가 있으면 반환, 아니면 nil.
    private func readCacheIfFresh() -> [UUID]? {
        let url = Self.cacheFile(for: Date())
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder.iso8601.decode(CachePayload.self, from: data) else {
            return nil
        }
        let age = Date().timeIntervalSince(payload.generatedAt)
        guard age < 60 * 60 * 24 else { return nil }
        return payload.mochiItemIDs
    }

    /// 1일 분석 본체. 현 단계는 stub — 기존 `importance` 점수로 단순 정렬.
    private func recompute(limit: Int) async -> [UUID] {
        do {
            // medium 이상만 가져오는 repository 메서드를 그대로 활용.
            // 추후 Gemini 호출로 교체되어도 호출 시그니처는 유지된다.
            let items = try await repository.listByImportance(limit: max(limit, 50))
            let ids = items.map(\.id)
            persist(ids: ids)
            return Array(ids.prefix(limit))
        } catch {
            return []
        }
    }

    private func persist(ids: [UUID]) {
        let payload = CachePayload(generatedAt: Date(), mochiItemIDs: ids)
        guard let data = try? JSONEncoder.iso8601.encode(payload) else { return }
        try? data.write(to: Self.cacheFile(for: Date()), options: .atomic)
    }
}

// MARK: - Stub (tests / previews)

public struct StubDailyImportanceAnalyzer: DailyImportanceAnalyzer {
    private let result: [UUID]
    public init(result: [UUID] = []) { self.result = result }
    public func todaysImportant(limit: Int) async -> [UUID] {
        Array(result.prefix(limit))
    }
}

// MARK: - JSON helpers

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
