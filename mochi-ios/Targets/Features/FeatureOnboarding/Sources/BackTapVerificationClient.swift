import Dependencies

/// 온보딩 "지금 백탭 해보세요" 단계가 백탭 동작을 검증하기 위해 쓰는 얇은 의존성.
///
/// 검증의 본질은 "사용자가 단축어를 추가하고 뒷면 탭에 연결했는가" 를 *간접 ack* 가 아니라
/// **백탭이 실제로 모찌 intent 에 도달하는가** 로 확인하는 것이다. 실제 신호는 App Group
/// 파일 마커 핸드셰이크(`AppGroup.beginBackTapVerification` 등)로 오가는데,
/// `FeatureOnboarding` 은 `CorePersistence` 를 의존하지 않으므로 그 호출을 여기서 추상화하고
/// App 타겟이 `withDependencies { $0.backTapVerification = .live }` 로 실제 구현을 주입한다.
public struct BackTapVerificationClient: Sendable {
    /// 검증 단계 진입 시 — 검증 창(start)을 연다. (이전 hit 은 strict 비교로 가려지므로 지우지 않음)
    public var begin: @Sendable () -> Void
    /// 폴링 — 백탭이 우리 intent 에 도달했는가 (현재 창 기준).
    public var didHit: @Sendable () -> Bool
    /// 검증 종료(감지 성공 / 타임아웃 / 단계 이탈) 시 — 창을 닫는다.
    public var end: @Sendable () -> Void

    public init(
        begin: @escaping @Sendable () -> Void,
        didHit: @escaping @Sendable () -> Bool,
        end: @escaping @Sendable () -> Void
    ) {
        self.begin = begin
        self.didHit = didHit
        self.end = end
    }
}

extension BackTapVerificationClient: DependencyKey {
    /// 기본은 no-op — App 타겟이 App Group 연동 구현을 주입하지 않으면 검증은 진행되지 않는다
    /// (감지 영영 없음 → 사용자는 "건너뛰기" 로 진행). 의도된 안전 기본값.
    public static let liveValue = Self(begin: {}, didHit: { false }, end: {})
    public static let testValue = Self(begin: {}, didHit: { false }, end: {})
}

public extension DependencyValues {
    var backTapVerification: BackTapVerificationClient {
        get { self[BackTapVerificationClient.self] }
        set { self[BackTapVerificationClient.self] = newValue }
    }
}
