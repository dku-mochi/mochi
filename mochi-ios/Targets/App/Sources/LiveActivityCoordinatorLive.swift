import ActivityKit
import Foundation

import CoreLiveActivity
import CoreNetworking
import CorePersistence

/// `LiveActivityCoordinator` 의 라이브 구현 — ActivityKit `Activity<MochiLiveActivityAttributes>` 직접 다룸.
///
/// 활성 Activity 는 `mochiItemID`(attributes 1급 필드) **정확 매칭 전용**으로 찾는다 — 전 채널이 LA 를
/// 시작하므로 캡처가 겹칠 수 있고, mostRecent 폴백은 다른 item 의 LA 를 잘못 건드릴 위험이 있어 쓰지 않는다.
///
/// **push 토큰 등록**: `Activity.request(pushType: .token)` 로 시작하면 토큰이 `pushTokenUpdates` 로
/// 비동기 도착한다. 한편 백엔드는 LA 토큰을 **server PK** 로 조회하는데 서버 PK 는 ingest 응답 후에야
/// 안다. ``LiveActivityPushRegistrar`` 가 (로컬 토큰)과 (serverID)를 짝지어 둘 다 모이면 1회 등록한다.
public struct LiveActivityCoordinatorLive: LiveActivityCoordinator {
    private let apiClient: any MochiAPIClient
    private let environment: PushEnvironment
    private let registrar: LiveActivityPushRegistrar

    public init(apiClient: any MochiAPIClient, environment: PushEnvironment) {
        self.apiClient = apiClient
        self.environment = environment
        self.registrar = LiveActivityPushRegistrar(apiClient: apiClient, environment: environment)
    }

    public func startAnalyzing(mochiItemID: UUID, caption: String, thumbnailRelativePath: String?) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Live Activities 비활성화 — 설정 > 모찌 > Live Activity 켜기")
            return
        }
        // 같은 mochiItemID 의 기존 activity 가 있으면 재사용, 없으면 새로 시작.
        if findActivity(for: mochiItemID) != nil { return }

        let attributes = MochiLiveActivityAttributes(
            mochiItemID: mochiItemID,
            captureCaption: caption,
            thumbnailRelativePath: thumbnailRelativePath
        )
        let initialState = MochiLiveActivityAttributes.ContentState(phase: .analyzing)
        do {
            let activity = try Activity<MochiLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: .token
            )
            observePushToken(activity, mochiItemID: mochiItemID)
            print("[LiveActivity] start .analyzing — id=\(activity.id) item=\(mochiItemID.uuidString.prefix(8))")
        } catch {
            print("[LiveActivity] start 실패: \(error)")
        }
    }

    public func registerPushToken(mochiItemID: UUID, serverID: UUID) async {
        await registrar.recordServerID(localID: mochiItemID, serverID: serverID)
    }

    public func transitionToReady(
        mochiItemID: UUID,
        needsReview: Bool,
        summary: String,
        candidates: [LiveActivityCandidate]
    ) async {
        let payload = candidates.map { c in
            MochiLiveActivityAttributes.Candidate(intentType: c.intentType, label: c.label, reasoning: c.reasoning)
        }
        let ready = MochiLiveActivityAttributes.ContentState(
            phase: .ready,
            needsReview: needsReview,
            summary: summary,
            candidates: payload
        )
        // 전 채널이 LA 를 시작하므로 캡처가 겹칠 수 있다 — **이 item 의 Activity 만** 정확 매칭으로 갱신
        // (mostRecent 폴백 금지: 다른 item 의 LA 를 잘못 건드릴 위험).
        guard let activity = findActivity(for: mochiItemID) else {
            // 시작이 누락된 시나리오: 이 item 의 ready Activity 를 새로 시작.
            await startReadyAsFallback(mochiItemID: mochiItemID, state: ready)
            return
        }
        await activity.update(.init(state: ready, staleDate: nil))
        print("[LiveActivity] transition .ready — item=\(mochiItemID.uuidString.prefix(8)), candidates=\(payload.count)")
    }

    public func endIfActive(mochiItemID: UUID, failed: Bool) async {
        // 이 item 의 Activity 만 종료(없으면 종료할 것 없음 — no-op).
        guard let activity = findActivity(for: mochiItemID) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        print("[LiveActivity] end (failed=\(failed)) item=\(mochiItemID.uuidString.prefix(8))")
    }

    // MARK: - private

    /// attributes 의 `mochiItemID`(1급 필드) 정확 매칭.
    private func findActivity(for mochiItemID: UUID) -> Activity<MochiLiveActivityAttributes>? {
        Activity<MochiLiveActivityAttributes>.activities.first { $0.attributes.mochiItemID == mochiItemID }
    }

    /// `pushTokenUpdates` 를 구독해 토큰(hex)을 registrar 에 적재 — serverID 가 모이면 등록(+rotation 재등록).
    private func observePushToken(_ activity: Activity<MochiLiveActivityAttributes>, mochiItemID: UUID) {
        let registrar = self.registrar
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                await registrar.recordToken(localID: mochiItemID, token: hex)
            }
        }
    }

    private func startReadyAsFallback(
        mochiItemID: UUID,
        state: MochiLiveActivityAttributes.ContentState
    ) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = MochiLiveActivityAttributes(
            mochiItemID: mochiItemID,
            captureCaption: "분류 완료"
        )
        do {
            let activity = try Activity<MochiLiveActivityAttributes>.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: .token
            )
            observePushToken(activity, mochiItemID: mochiItemID)
            print("[LiveActivity] fallback .ready start — item=\(mochiItemID.uuidString.prefix(8))")
        } catch {
            print("[LiveActivity] fallback start 실패: \(error)")
        }
    }
}

/// LA push 토큰 등록 상태 기계 — (로컬 토큰) ↔ (serverID) 를 짝지어 둘 다 모이면 1회 등록한다.
/// 토큰 rotation(같은 item 새 토큰)이면 키가 달라져 재등록한다. struct coordinator 가 값 복사돼도
/// 동일 actor 참조를 공유하도록 reference 타입.
actor LiveActivityPushRegistrar {
    private let apiClient: any MochiAPIClient
    private let environment: PushEnvironment
    private var tokens: [UUID: String] = [:]       // localID → 최신 hex 토큰
    private var serverIDs: [UUID: UUID] = [:]       // localID → serverID
    private var registered: Set<String> = []        // 중복 등록 방지 ("serverID:token")

    init(apiClient: any MochiAPIClient, environment: PushEnvironment) {
        self.apiClient = apiClient
        self.environment = environment
    }

    func recordToken(localID: UUID, token: String) async {
        tokens[localID] = token
        await registerIfReady(localID: localID)
    }

    func recordServerID(localID: UUID, serverID: UUID) async {
        serverIDs[localID] = serverID
        await registerIfReady(localID: localID)
    }

    private func registerIfReady(localID: UUID) async {
        guard let token = tokens[localID], let serverID = serverIDs[localID] else { return }
        let key = "\(serverID.uuidString):\(token)"
        guard !registered.contains(key) else { return }
        registered.insert(key)
        // best-effort — 실패하면 background LA 갱신만 누락(앱 내 폴링/SSE 가 메움). registered 에서 빼
        // 다음 token/serverID 갱신 시 재시도 여지를 둔다.
        do {
            try await apiClient.registerPushToken(
                token: token, kind: .liveActivity, environment: environment, mochiItemID: serverID
            )
        } catch {
            registered.remove(key)
        }
    }
}
