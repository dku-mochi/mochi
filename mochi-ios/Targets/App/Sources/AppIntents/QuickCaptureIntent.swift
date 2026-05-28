import AppIntents
import Foundation
import CoreDomain
import CorePersistence

/// Siri / Spotlight / 사용자 단축어에서 호출 가능한 텍스트·URL 메모 진입점.
///
/// 백탭 화면 캡처는 별도 ``CaptureScreenshotIntent`` 가 담당한다 (사용자 단축어가
/// `Take Screenshot → 앱과 공유 → 모찌 → 모찌 화면 캡처` 로 직행).
/// 이 Intent 는 음성/검색에서 빠른 메모(`memo`) 와 URL(`urlString`) 만 받는다.
/// 자세한 surface 분리 근거는 `docs/ARCHITECTURE.md` §2.3 참고.
///
/// `InboundCapturePayload` 를 그대로 App Group inbound 큐에 적재해
/// 메인 앱이 다음 부팅·foreground 진입 시 ``InboundQueueConsumer`` 로 흡수한다.
@available(iOS 17.0, *)
public struct QuickCaptureIntent: AppIntent {
    public static let title: LocalizedStringResource = "모찌 빠른 캡처"
    public static let description = IntentDescription("Siri / Spotlight 에서 텍스트 메모와 URL 을 모찌에 즉시 흡수")

    @Parameter(title: "메모", default: "")
    public var memo: String

    @Parameter(title: "URL", default: "")
    public var urlString: String

    public init() {}

    public func perform() async throws -> some IntentResult {
        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL  = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedMemo.isEmpty || !trimmedURL.isEmpty else {
            throw QuickCaptureIntentError.emptyInput
        }

        let url: URL?
        if trimmedURL.isEmpty {
            url = nil
        } else {
            guard let parsed = URL(string: trimmedURL) else {
                throw QuickCaptureIntentError.invalidURL(trimmedURL)
            }
            url = parsed
        }

        let payload = InboundCapturePayload(
            url: url,
            text: nil,
            userMemo: trimmedMemo.isEmpty ? nil : trimmedMemo,
            channelGuess: .appIntent,
            imageRefs: []
        )
        let fileURL = AppGroup.inboundQueueURL.appendingPathComponent("\(payload.id.uuidString).json")
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: [.atomic])

        return .result()
    }
}

enum QuickCaptureIntentError: Error, CustomLocalizedStringResourceConvertible {
    case emptyInput
    case invalidURL(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .emptyInput: "메모나 URL 중 하나는 입력해야 합니다"
        case .invalidURL(let raw): "유효한 URL 이 아닙니다: \(raw)"
        }
    }
}

/// Shortcuts 앱·"앱과 공유" 액션 리스트·Siri·Spotlight 에 자동 노출되는 단축어 묶음.
///
/// 두 Intent 가 의도가 다른 surface 로 노출된다:
/// - ``QuickCaptureIntent`` — 텍스트/URL 메모 (Siri/Spotlight 검색 진입)
/// - ``CaptureScreenshotIntent`` — 이미지 (백탭 단축어가 "앱과 공유" 로 직행)
@available(iOS 17.0, *)
public struct MochiShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: QuickCaptureIntent(),
            phrases: [
                "\(.applicationName)에 빠른 메모",
                "\(.applicationName) 메모 추가",
            ],
            shortTitle: "빠른 메모",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: CaptureScreenshotIntent(),
            phrases: [
                "\(.applicationName)에 화면 저장",
                "\(.applicationName) 스크린샷 저장",
            ],
            shortTitle: "화면 캡처",
            systemImageName: "camera.viewfinder"
        )
    }
}
