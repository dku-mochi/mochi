import CorePersistence
import FeatureOnboarding

/// `BackTapVerificationClient` 의 실제 구현 — App Group 핸드셰이크를 감싼다.
///
/// `FeatureOnboarding` 은 `CorePersistence` 를 의존하지 않으므로 `AppGroup` 을 직접 호출하지
/// 못한다. App 타겟이 이 `.live` 값을 온보딩 스토어에 `withDependencies` 로 주입한다.
extension BackTapVerificationClient {
    static let live = Self(
        begin: { AppGroup.beginBackTapVerification() },
        didHit: { AppGroup.backTapVerificationDidHit },
        end: { AppGroup.endBackTapVerification() }
    )
}
