import ActivityKit
import AppIntents
import Foundation

import CoreAuth
import CoreLiveActivity
import CoreNetworking
import CorePersistence

/// Live Activity 후보 버튼이 호출하는 App Intent — 후보 하나를 선택해 **백엔드 reanalyze** 를 트리거한다.
///
/// iOS 17+ 의 `Button(intent:)` 가 Live Activity 안에서 작동. 사용자가 Lock Screen / Dynamic Island
/// 의 후보 버튼을 누르면 본 intent 가 위젯 익스텐션 프로세스에서 실행된다(앱 안 깨움).
///
/// **흐름**: ① 해당 Activity 를 `.confirmed` 로 갱신(즉시 피드백) → ② 선택 라벨을 hint 로
/// `reanalyzeMochiItem` 호출 — 기존 분석 파이프라인을 그 의도 우선으로 재실행한다(결과는 분석완료
/// push 로 다시 온다). ``ShareExtDirectUpload`` 와 동일하게 App Group baseURL + Keychain access token
/// 을 쓰며, 토큰 만료/네트워크 실패면 best-effort 로 그친다(사용자가 앱에서 needs_review 를 그대로 재분류).
///
/// `mochiItemID` 는 attributes 의 `mochiItemID` = **서버 PK** 다 — push-to-start 로 백엔드가 LA 를
/// 시작하므로 그 값이 곧 reanalyze 대상 server id 가 된다.
public struct SelectCandidateIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "모찌 후보 선택"
    public static let description = IntentDescription("Live Activity 에서 use case 후보를 한 탭으로 선택")

    @Parameter(title: "mochiItemID")
    public var mochiItemID: String

    @Parameter(title: "label")
    public var label: String

    public init() {}
    public init(mochiItemID: String, label: String) {
        self.mochiItemID = mochiItemID
        self.label = label
    }

    public func perform() async throws -> some IntentResult {
        let itemID = UUID(uuidString: mochiItemID)
        // ① 해당 Activity 를 confirmed 로 즉시 갱신(피드백) 후 잠시 뒤 dismiss.
        for activity in Activity<MochiLiveActivityAttributes>.activities
        where itemID == nil || activity.attributes.mochiItemID == itemID {
            let prev = activity.content.state
            let newState = MochiLiveActivityAttributes.ContentState(
                phase: .confirmed,
                needsReview: prev.needsReview,
                summary: prev.summary,
                candidates: prev.candidates,
                selectedLabel: label
            )
            await activity.update(ActivityContent(state: newState, staleDate: nil))
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        // ② 선택 라벨을 hint 로 reanalyze 트리거 (best-effort).
        if let itemID { await Self.submitReanalyze(serverID: itemID, hint: label) }
        return .result()
    }

    /// App Group 으로 공유된 baseURL + Keychain access token 으로 reanalyze 를 직접 전송한다.
    /// (``ShareExtDirectUpload`` 와 동일 패턴 — refresh 는 시도하지 않는다. 만료/부재/네트워크 실패면
    /// 그대로 종료하고, 사용자가 앱에서 needs_review 를 재분류한다.)
    static func submitReanalyze(serverID: UUID, hint: String) async {
        guard let baseURL = AppGroup.sharedAPIBaseURL else { return }  // 앱 미실행이면 nil
        let sessionStore = AuthSessionStore(store: KeychainTokenStore())
        guard let token = await sessionStore.accessTokenIfValid() else { return }
        let client = OpenAPIMochiClient(baseURL: baseURL, tokenProvider: StaticTokenProvider(token: token))
        try? await client.reanalyzeMochiItem(id: serverID, userHint: hint)
    }
}

/// 고정 access token 을 주입하는 경량 ``AuthTokenProvider`` — 위젯 직접 전송 전용(refresh 없음).
private struct StaticTokenProvider: AuthTokenProvider {
    let token: String
    func bearerToken() async -> String? { token }
}

/// "다른 의도" 버튼 — 모찌 앱을 foreground 로 열어 자유 입력 받는 흐름.
///
/// `openAppWhenRun = true` 로 모찌 앱 진입. 자유 입력 UI(needs_review 카드의 "다른 의도")로 잇는다.
public struct OpenMochiOtherIntentIntent: AppIntent {
    public static let title: LocalizedStringResource = "다른 의도 입력"
    public static let description = IntentDescription("모찌 앱을 열어 자유 입력 받기")
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        return .result()
    }
}
