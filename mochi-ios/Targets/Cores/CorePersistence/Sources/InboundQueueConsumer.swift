import Dependencies
import Foundation
import CoreDomain

/// App Group inbound 큐에 ShareExtension 이 떨군 JSON 페이로드를 흡수한다.
///
/// 백탭 화면 캡처도 ShareExtension(`Take Screenshot → Share → 모찌`)으로 들어와 같은 경로를 쓴다 —
/// 옛 AppIntent snippet 직행 경로는 제거됐다(2026-06-25, ARCHITECTURE.md §2.3).
///
/// 메인 앱은 부팅 시 (그리고 foreground 전이 시) ``drain()`` 을 한 번 호출하여 큐를 비운다.
public actor InboundQueueConsumer {
    private let repository: any MochiItemRepository
    private let fileManager: FileManager

    public init(repository: any MochiItemRepository, fileManager: FileManager = .default) {
        self.repository = repository
        self.fileManager = fileManager
    }

    @discardableResult
    public func drain() async -> InboundDrainResult {
        let dir = AppGroup.inboundQueueURL
        let files = (try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var consumed = 0
        var failures: [URL] = []

        for fileURL in files where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let payload = try JSONDecoder().decode(InboundIngestPayload.self, from: data)
                let source = IngestSource(
                    id: payload.id,
                    channel: payload.channelGuess,
                    url: payload.url,
                    text: payload.text,
                    imageRefs: payload.imageRefs,
                    userMemo: payload.userMemo,
                    privacy: payload.privacy,
                    analysisOcrText: payload.analysisOcrText
                )
                try await repository.enqueueIngestedFromExtension(source)
                try? fileManager.removeItem(at: fileURL)
                consumed += 1
            } catch {
                failures.append(fileURL)
            }
        }

        return InboundDrainResult(consumed: consumed, failedFiles: failures)
    }
}

public struct InboundDrainResult: Equatable, Sendable {
    public let consumed: Int
    public let failedFiles: [URL]
}

// MARK: - DI

/// silent push 백그라운드 핸들러(`MochiAppDelegate`)가 inbound 큐를 흡수하기 위한 추상화 —
/// ShareExt 캡처는 push 도착 시점에 로컬 Realm 에 없고 큐 JSON 에만 있으므로, drain 없이는
/// reconcile 이 항목을 못 찾는다. ``MochiApp`` 이 실제 consumer 를 주입한다(`syncTrigger` 와 동일 패턴).
public protocol InboundQueueDraining: Sendable {
    @discardableResult
    func drain() async -> InboundDrainResult
}

extension InboundQueueConsumer: InboundQueueDraining {}

/// 주입 누락 시 no-op. 기본값을 실제 consumer 로 두면 안 된다 — 잘못된 repository 로 drain 하면
/// 큐 파일이 삭제돼 캡처가 유실된다.
public struct NoopInboundQueueDrainer: InboundQueueDraining {
    public init() {}
    @discardableResult
    public func drain() async -> InboundDrainResult {
        InboundDrainResult(consumed: 0, failedFiles: [])
    }
}

public enum InboundQueueDrainerKey: DependencyKey {
    public static let liveValue: any InboundQueueDraining = NoopInboundQueueDrainer()
    public static let testValue: any InboundQueueDraining = NoopInboundQueueDrainer()
}

public extension DependencyValues {
    var inboundQueueDrainer: any InboundQueueDraining {
        get { self[InboundQueueDrainerKey.self] }
        set { self[InboundQueueDrainerKey.self] = newValue }
    }
}

/// ShareExtension 이 사용하는 inbound payload 포맷.
///
/// **이 ID 가 그대로 ``IngestSource.id`` 와 백엔드 mochiItem id가 된다** — 확장이 만든 시점에 결정한
/// UUID 를 메인 앱·백엔드까지 일관되게 사용해 멱등키·중복 방지에 활용한다.
public struct InboundIngestPayload: Codable, Sendable, Equatable {
    public let id: UUID
    public let url: URL?
    public let text: String?
    public let userMemo: String?
    public let channelGuess: IngestChannel
    public let imageRefs: [ImageRef]
    /// 저장 시점 민감 감지 + 사용자 선택의 결과. `nil` = 비민감/감지 비대상(기존 원본 업로드).
    /// ShareExtension 직접 전송과 메인 앱 drain 양 경로가 같은 정책을 적용하도록 큐 JSON 에 함께 싣는다.
    public let privacy: PrivacyDecision?
    /// OCR 화면 transcript — **분석 전용 ephemeral**(서버가 추론 후 삭제). privacy 와 동일하게 큐 JSON 에
    /// 실어 양 업로드 경로가 정책에 따라 동봉 여부를 고른다(originalUpload 일 때만 — PRIVACY §9).
    public let analysisOcrText: String?

    public init(
        id: UUID = UUID(),
        url: URL?,
        text: String?,
        userMemo: String?,
        channelGuess: IngestChannel,
        imageRefs: [ImageRef] = [],
        privacy: PrivacyDecision? = nil,
        analysisOcrText: String? = nil
    ) {
        self.id = id
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.channelGuess = channelGuess
        self.imageRefs = imageRefs
        self.privacy = privacy
        self.analysisOcrText = analysisOcrText
    }
}
