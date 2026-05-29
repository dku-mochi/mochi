import Foundation
import CoreDomain

/// App Group inbound 큐에 ShareExtension 또는 `QuickCaptureIntent` 가 떨군 JSON 페이로드를 흡수한다.
///
/// **백탭은 큐를 거치지 않는다** — `CaptureScreenshotIntent` 가 PNG 만 `pending-backtap/` 에
/// stash 하고 snippet 카드를 띄우면, "캡쳐" 분기 (`CommitBackTapCaptureIntent`) 가 Realm 직접
/// upsert 하거나 "메모" 분기 (`OpenBackTapMemoIntent` → `BackTapModalFeature`) 가 사용자 입력 후
/// Realm upsert 한다 (ARCHITECTURE.md §2.3).
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
                    userMemo: payload.userMemo
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

/// ShareExtension 및 메인 App 의 `QuickCaptureIntent` 가 사용하는 inbound payload 포맷.
///
/// 백탭 (`CaptureScreenshotIntent` → snippet → `CommitBackTapCaptureIntent` / `OpenBackTapMemoIntent`)
/// 은 이 포맷을 사용하지 않는다 — pending-backtap stash + Realm 직접 upsert 경로.
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

    public init(
        id: UUID = UUID(),
        url: URL?,
        text: String?,
        userMemo: String?,
        channelGuess: IngestChannel,
        imageRefs: [ImageRef] = []
    ) {
        self.id = id
        self.url = url
        self.text = text
        self.userMemo = userMemo
        self.channelGuess = channelGuess
        self.imageRefs = imageRefs
    }
}
