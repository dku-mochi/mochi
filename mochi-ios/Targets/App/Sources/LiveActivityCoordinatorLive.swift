import ActivityKit
import Foundation

import CoreLiveActivity
import CorePersistence

/// `LiveActivityCoordinator` 의 라이브 구현 — ActivityKit `Activity<MockUseCaseActivityAttributes>` 직접 다룸.
///
/// 가정 — **동시 활성 Activity 1건만**: 사용자가 백탭을 연달아 누르고 분류가 동시에 진행될 수 있으나,
/// MVP 에서는 가장 최근 1건만 표시. mochiItemID 매칭으로 찾되, 없으면 가장 최근 활성 Activity 사용.
///
/// **prototype 정합**: `MockUseCaseActivityAttributes` schema 는 5-25 prototype 그대로 재사용 — Widget UI
/// (`MockUseCaseLiveActivity.swift`) 도 동일하므로 추가 변경 없이 실제 분류 데이터로 driving.
public struct LiveActivityCoordinatorLive: LiveActivityCoordinator {
    public init() {}

    public func startAnalyzing(mochiItemID: UUID, caption: String, thumbnailRelativePath: String?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Live Activities 비활성화 — 설정 > 모찌 > Live Activity 켜기")
            return
        }
        // 같은 mochiItemID 의 기존 activity 가 있으면 재사용, 없으면 새로 시작.
        if findActivity(for: mochiItemID) != nil { return }

        let attributes = MockUseCaseActivityAttributes(
            captureCaption: caption,
            thumbnailRelativePath: thumbnailRelativePath
        )
        let initialState = MockUseCaseActivityAttributes.ContentState(
            phase: .analyzing,
            candidates: [],
            selectedLabel: nil
        )
        do {
            let activity = try Activity<MockUseCaseActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            print("[LiveActivity] start .analyzing — id=\(activity.id) item=\(mochiItemID.uuidString.prefix(8))")
        } catch {
            print("[LiveActivity] start 실패: \(error)")
        }
    }

    public func transitionToReady(
        mochiItemID: UUID,
        candidates: [LiveActivityCandidate]
    ) async {
        let payload = candidates.map { c in
            MockUseCaseActivityAttributes.Candidate(
                label: c.label,
                intent: c.intent,
                applicability: c.applicability
            )
        }
        let activity = findActivity(for: mochiItemID) ?? mostRecentActivity()
        guard let activity else {
            // 시작이 누락된 시나리오: ready 부터 시작.
            await startReadyAsFallback(mochiItemID: mochiItemID, candidates: payload)
            return
        }
        let ready = MockUseCaseActivityAttributes.ContentState(
            phase: .ready,
            candidates: payload,
            selectedLabel: nil
        )
        await activity.update(.init(state: ready, staleDate: nil))
        print("[LiveActivity] transition .ready — item=\(mochiItemID.uuidString.prefix(8)), candidates=\(payload.count)")
    }

    public func endIfActive(mochiItemID: UUID, failed: Bool) async {
        let activity = findActivity(for: mochiItemID) ?? mostRecentActivity()
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        print("[LiveActivity] end (failed=\(failed)) item=\(mochiItemID.uuidString.prefix(8))")
    }

    // MARK: - private

    /// `captureCaption` 마지막 8 chars 가 mochiItemID prefix 와 매칭되면 같은 item 의 activity.
    /// (attributes 에 mochiItemID 필드를 추가하지 않기 위한 best-effort.)
    private func findActivity(for mochiItemID: UUID) -> Activity<MockUseCaseActivityAttributes>? {
        let needle = mochiItemID.uuidString.prefix(8)
        return Activity<MockUseCaseActivityAttributes>.activities.first { activity in
            activity.attributes.captureCaption.contains("[\(needle)]")
        }
    }

    private func mostRecentActivity() -> Activity<MockUseCaseActivityAttributes>? {
        Activity<MockUseCaseActivityAttributes>.activities.first
    }

    private func startReadyAsFallback(
        mochiItemID: UUID,
        candidates: [MockUseCaseActivityAttributes.Candidate]
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = MockUseCaseActivityAttributes(
            captureCaption: "[\(mochiItemID.uuidString.prefix(8))] 분류 완료"
        )
        let state = MockUseCaseActivityAttributes.ContentState(
            phase: .ready,
            candidates: candidates,
            selectedLabel: nil
        )
        do {
            _ = try Activity<MockUseCaseActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            print("[LiveActivity] fallback .ready start — item=\(mochiItemID.uuidString.prefix(8))")
        } catch {
            print("[LiveActivity] fallback start 실패: \(error)")
        }
    }
}
