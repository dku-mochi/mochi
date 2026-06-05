import ActivityKit
import AppIntents
import Foundation

import CoreLiveActivity

/// Live Activity 의 interactive button 이 호출하는 App Intent — 후보 라벨 하나를 선택.
///
/// iOS 17+ 의 `Button(intent:)` 가 Live Activity 안에서 작동. 사용자가 Lock Screen /
/// Dynamic Island 의 후보 버튼을 누르면 본 intent 가 background 에서 실행되고, Activity 의
/// ContentState 를 `.confirmed` 로 갱신한다.
///
/// 사용자 선택은 App Group 의 marker(`live-activity-selection.json`)에 기록되고, 모찌 앱이
/// 다음 active tick 에 그 marker 를 흡수해 실제 commit 흐름으로 잇는다.
public struct SelectCandidateIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "모찌 후보 선택"
    public static let description = IntentDescription("Live Activity 에서 use case 후보를 한 탭으로 선택")

    @Parameter(title: "label")
    public var label: String

    public init() {}
    public init(label: String) {
        self.label = label
    }

    public func perform() async throws -> some IntentResult {
        // 현재 활성 Activity 를 찾아 confirmed 로 update.
        for activity in Activity<MochiLiveActivityAttributes>.activities {
            let prev = activity.content.state
            let newState = MochiLiveActivityAttributes.ContentState(
                phase: .confirmed,
                needsReview: prev.needsReview,
                summary: prev.summary,
                candidates: prev.candidates,
                selectedLabel: label
            )
            await activity.update(
                ActivityContent(state: newState, staleDate: nil)
            )
            // 짧게 보여준 뒤 dismiss.
            Task.detached {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        // 사용자 선택을 App Group 에 기록 — 모찌 앱이 launch 시 흡수.
        Self.writeSelectionMarker(label: label)
        return .result()
    }

    /// App Group container 의 `live-activity-selection.json` 에 선택 결과 stash.
    private static func writeSelectionMarker(label: String) {
        let appGroupID = "group.app.mochi"
        guard let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent("live-activity-selection.json")
        else { return }
        let payload: [String: Any] = [
            "label": label,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            try? data.write(to: url, options: [.atomic])
        }
    }
}

/// "다른 의도" 버튼 — 모찌 앱을 foreground 로 열어 자유 입력 받는 흐름.
///
/// `openAppWhenRun = true` 로 모찌 앱 진입. prototype 은 앱 진입까지만 표현하고
/// 자유 입력 UI 는 별도 작업.
public struct OpenMochiOtherIntentIntent: AppIntent {
    public static let title: LocalizedStringResource = "다른 의도 입력"
    public static let description = IntentDescription("모찌 앱을 열어 자유 입력 받기")
    public static let openAppWhenRun: Bool = true

    public init() {}

    public func perform() async throws -> some IntentResult {
        return .result()
    }
}
