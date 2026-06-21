import Foundation

/// 캡처의 민감도 등급 (0-10 점수의 4구간 매핑 — `PRIVACY_SENSITIVE_CAPTURE.md §2.2`).
///
/// 등급 자체는 **사용자에게 보여줄 경고 강도**와 **기본 정책 추천**에만 쓴다. 서버로는
/// 전송하지 않는다(서버는 올라온 이미지가 원본인지 블러본인지 구분할 필요가 없다 — 올라온 게 진실).
public enum SensitivityLevel: String, Codable, Sendable, CaseIterable, Hashable {
    case low              // 0-2
    case caution          // 3-5
    case sensitive        // 6-8
    case highlySensitive  // 9-10
}

/// 한 캡처를 서버에 어떻게 보낼지의 결정 — 저장 시점 사용자 선택의 결과.
///
/// 민감 영역을 저장 시점에 블러 처리해서 올리면 서버 이미지 자체가 안전하므로, 다운스트림
/// 노출 표면(채팅 이미지 재조회·유사 회수·즐겨찾기·사진앱 저장·회수 알림)에 별도 게이트를
/// 둘 필요가 없다(2026-06-21 결정 — `PRIVACY_SENSITIVE_CAPTURE.md §2`).
public enum PrivacyPolicy: String, Codable, Sendable, CaseIterable, Hashable {
    /// 원본 그대로 업로드 — 비민감이거나 사용자가 명시적으로 원본 분석을 허용.
    case originalUpload
    /// 민감 영역을 블러 처리한 파생본을 업로드 (원본은 로컬에만 보존).
    case blurredUpload
    /// 서버 미전송 — 기기에만 보관(사용자가 "저장 안 함/기기에만" 선택).
    case localOnly
}

/// 저장 시점 민감도 감지 + 사용자 선택의 산출물. iOS 내부 전용(서버 미전송).
///
/// `nil` 인 `IngestSource.privacy` 는 "감지 비대상 또는 비민감" 을 뜻하며 기존 원본 업로드 동작과 동일.
public struct PrivacyDecision: Equatable, Sendable, Hashable, Codable {
    /// 적용할 업로드 동작.
    public let policy: PrivacyPolicy
    /// 감지된 민감도 등급 — 경고 UI·디버깅용 기록.
    public let level: SensitivityLevel

    public init(policy: PrivacyPolicy, level: SensitivityLevel) {
        self.policy = policy
        self.level = level
    }
}
