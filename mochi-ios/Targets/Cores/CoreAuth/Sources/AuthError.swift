import Foundation
import CoreNetworking

/// 인증 영역 에러 — 사용자에게 노출되는 메시지를 한국어로 매핑하기 위한 단일 출구.
///
/// 모든 lower-level 에러 (Apple/Google SDK, URLSession, 백엔드 envelope) 가 본 타입으로 정규화된다.
public enum AuthError: Error, Equatable, Sendable {
    /// 사용자가 시스템 시트에서 직접 취소. 별도 알림 없이 조용히 처리.
    case canceled

    /// Apple/Google SDK 가 토큰을 발급하지 못함 (네트워크/계정 미설정 등).
    case providerFailed(message: String)

    /// 백엔드가 401 (`auth.*`) envelope 으로 응답 — 자체 message 그대로 노출.
    case backendRejected(code: String, message: String)

    /// 네트워크 자체 실패.
    case network(message: String)

    /// 응답 디코딩 실패 — 계약 mismatch.
    case decoding(message: String)

    /// 그 외 분류 불가.
    case unknown(message: String)

    public var userMessage: String {
        switch self {
        case .canceled:
            return "로그인을 취소했습니다."
        case .providerFailed(let m), .network(let m), .decoding(let m), .unknown(let m):
            return m
        case .backendRejected(_, let m):
            return m
        }
    }

    public static func from(_ envelope: APIErrorEnvelope) -> AuthError {
        if envelope.code.hasPrefix("auth.") {
            return .backendRejected(code: envelope.code, message: envelope.message)
        }
        return .unknown(message: envelope.message)
    }
}
