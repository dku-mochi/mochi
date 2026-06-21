import Foundation

/// 한 캡처에서 감지된 민감 정보의 종류.
///
/// NER(사람 이름·조직명)은 제외한다 — Apple `NaturalLanguage` 의 `.nameType` 이 한국어를
/// 지원하지 않고, 한국어 NER 커스텀 모델은 Share Extension 120MB 메모리 한도와 충돌하기
/// 때문이다. 민감 캡처 판정의 핵심(주민번호·카드·OTP·계좌·토큰)은 검증기+문맥으로 충분히
/// 잡히며 이름은 본래 가중치가 가장 낮다(`PRIVACY_SENSITIVE_CAPTURE.md §3.4`).
public enum SensitivityType: String, Sendable, Hashable, CaseIterable {
    case nationalID        // 주민등록번호
    case cardNumber        // 신용/체크카드
    case businessNumber    // 사업자등록번호
    case bankAccount       // 계좌번호
    case otpCode           // 인증번호/OTP/보안코드
    case passwordOrToken   // 비밀번호/API key/token
    case phoneNumber       // 휴대폰/전화번호
    case email             // 이메일
    case address           // 주소
    case medical           // 병원/처방/진단/보험 문맥
    case finance           // 급여/세금/계약/송금/결제 문맥
}

public extension SensitivityType {
    /// 단일 신호 기본 가중치 (`PRIVACY_SENSITIVE_CAPTURE.md §4.2`).
    var baseScore: Int {
        switch self {
        case .nationalID, .cardNumber, .passwordOrToken: return 5
        case .otpCode, .medical: return 4
        case .bankAccount, .address, .finance, .businessNumber: return 3
        case .phoneNumber, .email: return 2
        }
    }

    /// 감지 유형 칩에 쓸 짧은 라벨(원문 미노출).
    var chipLabel: String {
        switch self {
        case .nationalID: return "주민번호"
        case .cardNumber: return "카드번호"
        case .businessNumber: return "사업자번호"
        case .bankAccount: return "계좌번호"
        case .otpCode: return "인증번호"
        case .passwordOrToken: return "비밀번호"
        case .phoneNumber: return "전화번호"
        case .email: return "이메일"
        case .address: return "주소"
        case .medical: return "건강정보"
        case .finance: return "금융정보"
        }
    }

    /// 사용자에게 보여줄 유형 중심 설명 — 원문은 절대 노출하지 않는다(`§5.3`).
    var displayReason: String {
        switch self {
        case .nationalID: return "주민등록번호로 보이는 번호"
        case .cardNumber: return "카드번호로 보이는 번호"
        case .businessNumber: return "사업자등록번호로 보이는 번호"
        case .bankAccount: return "계좌번호로 보이는 번호"
        case .otpCode: return "인증번호로 보이는 숫자"
        case .passwordOrToken: return "비밀번호·인증키로 보이는 값"
        case .phoneNumber: return "전화번호"
        case .email: return "이메일 주소"
        case .address: return "주소"
        case .medical: return "건강·의료 관련 내용"
        case .finance: return "금융·결제 관련 내용"
        }
    }
}

/// 감지된 민감 신호 하나. 점수 합산·차단 판정·블러 영역 계산의 단위.
public struct SensitivitySignal: Equatable, Sendable, Hashable {
    public let type: SensitivityType
    /// 이 신호의 점수 기여(기본 `type.baseScore`, 검증 결과에 따라 가감 가능).
    public let score: Int
    /// OCR 텍스트 내 위치 — 블러 영역(`RedactionPlanner`)과 매핑한다. 텍스트 직접 입력이면 `nil` 가능.
    public let textRange: Range<String.Index>?
    /// 검증기를 통과한(우연의 일치가 아닌) 고신뢰 신호인지.
    ///
    /// `true` 인 신호만 저장 흐름에 끼어들어 사용자에게 시트를 띄울 자격이 있다 —
    /// false positive 가 저장을 막는 UX 마찰을 차단하기 위함(`PRIVACY_SENSITIVE_CAPTURE.md §5.2`).
    /// low-precision 신호(문맥 없는 짧은 숫자 등)는 점수에만 기여하고 단독으로는 막지 않는다.
    public let isHighPrecision: Bool
    /// 유형 중심 설명(원문 미노출).
    public let reason: String

    public init(
        type: SensitivityType,
        score: Int,
        textRange: Range<String.Index>? = nil,
        isHighPrecision: Bool,
        reason: String? = nil
    ) {
        self.type = type
        self.score = score
        self.textRange = textRange
        self.isHighPrecision = isHighPrecision
        self.reason = reason ?? type.displayReason
    }
}
