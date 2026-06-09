import ActivityKit
import Foundation

import CoreLiveActivity
import CoreNetworking

/// Live Activity push-to-start 토큰 등록기 (App 타겟 — ActivityKit 보유).
///
/// 모찌는 **needs_review=true 분석완료에서만** LA 를 띄운다(팀 결정 2026-06-09). iOS 가 LA 를 직접
/// 시작하지 않고, 백엔드가 push-to-start 로 background(잠금)에서 시작하는 단일 경로다. 진행중/완료 LA
/// 와 per-item content-state update push 는 폐기됐다 — needs_review 가 아닌 분석완료는 alert push 가
/// 알린다.
///
/// 이 타입의 책임은 하나: 앱 시작 시 push-to-start 토큰을 관찰해 owner-scoped `la_start` 토큰으로
/// 백엔드에 등록한다. push-to-start 는 iOS 17.2+ 라 미만 단말은 토큰을 못 받아 LA 가 안 뜨지만,
/// 분석완료 alert push 가 needs_review 를 fallback 으로 알린다.
public final class LiveActivityCoordinatorLive: Sendable {
    private let apiClient: any MochiAPIClient
    private let environment: PushEnvironment

    public init(apiClient: any MochiAPIClient, environment: PushEnvironment) {
        self.apiClient = apiClient
        self.environment = environment
    }

    /// 앱 시작 시 1회 호출. `pushToStartTokenUpdates`(iOS 17.2+) 를 관찰해 토큰이 도착/회전할 때마다
    /// owner-scoped `la_start` 토큰으로 백엔드에 등록한다(upsert 멱등). best-effort — 실패해도 다음
    /// 토큰 갱신 때 재시도된다. 토큰은 단말+attributes 타입 단위라 item 무관(mochiItemID=nil).
    public func observePushToStartToken() {
        let apiClient = self.apiClient
        let environment = self.environment
        Task {
            if #available(iOS 17.2, *) {
                for await tokenData in Activity<MochiLiveActivityAttributes>.pushToStartTokenUpdates {
                    let hex = tokenData.map { String(format: "%02x", $0) }.joined()
                    try? await apiClient.registerPushToken(
                        token: hex, kind: .laStart, environment: environment, mochiItemID: nil
                    )
                }
            }
        }
    }
}
