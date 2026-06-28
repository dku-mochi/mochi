import Foundation

/// OCR 텍스트(또는 사용자 입력 텍스트)에서 민감 패턴을 감지한다 — **모델 0, 완전 결정론적**.
///
/// 설계 원칙(`PRIVACY_SENSITIVE_CAPTURE.md §3.4`):
/// - 정밀도의 핵심은 **검증기**(Luhn·주민번호/사업자번호 체크섬)와 **문맥 근접**이다. 우연의
///   숫자 일치를 체크섬과 문맥어로 걸러 false positive 를 억제한다.
/// - 검증을 통과한 신호만 `isHighPrecision = true` 로 표시해, 저장 흐름에 끼어들어 사용자에게
///   시트를 띄울 자격을 준다. 흔하고 덜 민감한 신호(전화·이메일·문맥 단독)는 점수에만 기여한다.
/// - 입력은 `OCRTextNormalizer` 로 길이 보존 정규화(전각·유니코드 대시/공백)해 매칭률을 높이되,
///   `textRange` 는 원본 offset 으로 되돌려 블러 영역 매핑을 보존한다.
/// - NER(이름·조직) 미도입(원리적 제외) — 이름은 식별자와 결합할 때만 위험하고 그 결합은 조합
///   가중이 잡으며, 이름 단독 감지는 FP 비용만 크다(`PRIVACY_SENSITIVE_CAPTURE.md §3.4`).
public struct SensitiveDataDetector {
    public init() {}

    public func detect(in original: String) -> [SensitivitySignal] {
        guard !original.isEmpty else { return [] }
        // OCR 표면 변형(전각·유니코드 대시/공백)을 정규화해 매칭률을 높인다. 정규화는 **길이 보존**이라
        // 아래 textRange 를 같은 offset 으로 원본에 되돌릴 수 있다(블러 영역 매핑 보호 — `OCRTextNormalizer`).
        let text = OCRTextNormalizer.normalize(original)
        var signals: [SensitivitySignal] = []
        signals += detectNationalIDs(in: text)
        signals += detectCardNumbers(in: text)
        signals += detectBusinessNumbers(in: text)
        signals += detectOTPCodes(in: text)
        signals += detectPasswordsOrTokens(in: text)
        signals += detectBankAccounts(in: text)
        signals += detectPhoneNumbers(in: text)
        signals += detectEmails(in: text)
        signals += detectLabeledSecrets(in: text)
        signals += detectContextual(in: text)
        // textRange 는 정규화본 기준 — 원본 기준으로 되돌린다(같은 UTF-16 offset, 길이 보존이라 1:1).
        return signals.map { Self.remappingRange($0, from: text, to: original) }
    }

    /// 정규화본에서 잡은 `textRange` 를 같은 offset 으로 원본 문자열의 Range 로 되돌린다.
    /// 정규화가 UTF-16 길이를 보존하므로 offset 이 1:1 대응한다(`OCRTextNormalizer`).
    private static func remappingRange(
        _ signal: SensitivitySignal,
        from normalized: String,
        to original: String
    ) -> SensitivitySignal {
        guard let range = signal.textRange,
              let originalRange = Range(NSRange(range, in: normalized), in: original)
        else { return signal }
        return SensitivitySignal(
            type: signal.type,
            score: signal.score,
            textRange: originalRange,
            isHighPrecision: signal.isHighPrecision,
            reason: signal.reason
        )
    }

    // MARK: - 검증기 (테스트 대상 — 순수 함수)

    /// 주민등록번호 체크섬. 2020-10 이후 발급분은 뒷자리 임의화로 이 검증이 무력화되므로,
    /// 감지 자체는 형식+생년월일로 하고 체크섬은 신뢰도 보강 신호로만 쓴다.
    public static func isValidNationalIDChecksum(_ digits13: [Int]) -> Bool {
        guard digits13.count == 13 else { return false }
        let weights = [2, 3, 4, 5, 6, 7, 8, 9, 2, 3, 4, 5]
        let sum = zip(digits13.prefix(12), weights).reduce(0) { $0 + $1.0 * $1.1 }
        let check = (11 - (sum % 11)) % 10
        return check == digits13[12]
    }

    /// 카드번호 Luhn 검증.
    public static func isValidLuhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 12 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    /// 사업자등록번호 가중치 체크섬.
    public static func isValidBusinessNumberChecksum(_ digits10: [Int]) -> Bool {
        guard digits10.count == 10 else { return false }
        let weights = [1, 3, 7, 1, 3, 7, 1, 3, 5]
        var sum = zip(digits10.prefix(9), weights).reduce(0) { $0 + $1.0 * $1.1 }
        sum += (digits10[8] * 5) / 10
        let check = (10 - (sum % 10)) % 10
        return check == digits10[9]
    }

    // MARK: - 개별 검출기

    private func detectNationalIDs(in text: String) -> [SensitivitySignal] {
        // YYMMDD - [1-8](세기·성별) + 6자리. 1-8 = 내/외국인 1900s·2000s.
        let pattern = #"\b\d{6}[-\s]?[1-8]\d{6}\b"#
        return Self.regexMatches(pattern, in: text).compactMap { range in
            let ds = Self.digits(of: text[range])
            guard ds.count == 13, Self.hasValidBirthdate(ds) else { return nil }
            // 형식+생일이 맞으면 주민번호로 본다(13자리 + 특이 형식이라 우연 일치 극히 드묾).
            // 체크섬까지 통과하면 더 확실하지만, 2020-10 이후 임의화분도 보호 대상이다.
            return SensitivitySignal(
                type: .nationalID,
                score: SensitivityType.nationalID.baseScore,
                textRange: range,
                isHighPrecision: true
            )
        }
    }

    private func detectCardNumbers(in text: String) -> [SensitivitySignal] {
        // 카드번호 후보 — (a) 4-4-4-(1~7), (b) 4-6-5(Amex), (c) 구분자 없는 13~19 연속.
        // 구분자는 공백/하이픈 허용. 어느 패턴이든 13~19자리 + Luhn 통과만 신호로 채택(FP 억제).
        let patterns = [
            #"\b\d{4}[-\s]?\d{4}[-\s]?\d{4}[-\s]?\d{1,7}\b"#,
            #"\b\d{4}[-\s]?\d{6}[-\s]?\d{5}\b"#,
            #"\b\d{13,19}\b"#,
        ]
        var seen = Set<Range<String.Index>>()
        var signals: [SensitivitySignal] = []
        for pattern in patterns {
            for range in Self.regexMatches(pattern, in: text) where !seen.contains(range) {
                let ds = Self.digits(of: text[range])
                guard (13...19).contains(ds.count), Self.isValidLuhn(ds) else { continue }
                seen.insert(range)
                signals.append(SensitivitySignal(
                    type: .cardNumber,
                    score: SensitivityType.cardNumber.baseScore,
                    textRange: range,
                    isHighPrecision: true
                ))
            }
        }
        return signals
    }

    private func detectBusinessNumbers(in text: String) -> [SensitivitySignal] {
        // 3-2-5. 10자리 숫자는 흔하므로 체크섬 통과만 신호로 채택(FP 방지).
        let pattern = #"\b\d{3}-?\d{2}-?\d{5}\b"#
        return Self.regexMatches(pattern, in: text).compactMap { range in
            let ds = Self.digits(of: text[range])
            guard ds.count == 10, Self.isValidBusinessNumberChecksum(ds) else { return nil }
            return SensitivitySignal(
                type: .businessNumber,
                score: SensitivityType.businessNumber.baseScore,
                textRange: range,
                isHighPrecision: true
            )
        }
    }

    private func detectOTPCodes(in text: String) -> [SensitivitySignal] {
        // 인증/보안 문맥어 근처 4-8자리 숫자. 문맥이 있어야 채택(맨 숫자는 무시). 문맥어가 숫자
        // **앞·뒤** 어느 쪽이든 잡는다(`인증번호 123456` 과 `123456 이 인증번호입니다` 모두).
        let context = #"인증\s?번호|인증\s?코드|보안\s?코드|확인\s?코드|OTP|verification\s?code"#
        let patterns = [
            "(?:\(context))[^\\d]{0,25}(\\d{4,8})",
            "(\\d{4,8})[^\\d]{0,10}(?:\(context))",
        ]
        var seen = Set<Range<String.Index>>()
        var signals: [SensitivitySignal] = []
        for pattern in patterns {
            for range in Self.regexMatches(pattern, in: text, captureGroup: 1, options: [.caseInsensitive])
            where !seen.contains(range) {
                seen.insert(range)
                signals.append(SensitivitySignal(
                    type: .otpCode,
                    score: SensitivityType.otpCode.baseScore,
                    textRange: range,
                    isHighPrecision: true
                ))
            }
        }
        return signals
    }

    private func detectPasswordsOrTokens(in text: String) -> [SensitivitySignal] {
        func signal(_ range: Range<String.Index>) -> SensitivitySignal {
            SensitivitySignal(
                type: .passwordOrToken,
                score: SensitivityType.passwordOrToken.baseScore,
                textRange: range,
                isHighPrecision: true
            )
        }
        var signals: [SensitivitySignal] = []
        // 키워드 + 구분자(`:` 또는 `=`) + 값(6자 이상 공백없는 문자열).
        let kvPattern = #"(?:비밀번호|password|passwd|pwd|api[\s_-]?key|secret|access[\s_-]?token|token)\s*[:=]\s*(\S{6,})"#
        signals += Self.regexMatches(kvPattern, in: text, captureGroup: 1, options: [.caseInsensitive]).map(signal)
        // `Bearer <token>` 형식 — 구분자 없이 공백으로 이어진다(`[:=]` 패턴이 못 잡음).
        let bearerPattern = #"[Bb]earer\s+([A-Za-z0-9._\-]{8,})"#
        signals += Self.regexMatches(bearerPattern, in: text, captureGroup: 1).map(signal)
        return signals
    }

    private func detectBankAccounts(in text: String) -> [SensitivitySignal] {
        // 은행명/계좌 문맥어 근처 숫자그룹. 그룹 수를 2~5(가상계좌·다양한 포맷)로 넓히고, 구분자 없는
        // 단일 긴 숫자도 허용한다. 문맥이 있어야 채택 + 합산 8~16자리로 FP 억제.
        let pattern = #"(?:은행|뱅크|신한|국민|우리|하나|농협|기업|카카오뱅크|토스뱅크|새마을금고|우체국|계좌|입금|이체|예금주)[^\d]{0,15}(\d{2,6}(?:[-\s]?\d{1,7}){1,4})"#
        return Self.regexMatches(pattern, in: text, captureGroup: 1).compactMap { range in
            let ds = Self.digits(of: text[range])
            guard (8...16).contains(ds.count) else { return nil }
            return SensitivitySignal(
                type: .bankAccount,
                score: SensitivityType.bankAccount.baseScore,
                textRange: range,
                isHighPrecision: true
            )
        }
    }

    private func detectPhoneNumbers(in text: String) -> [SensitivitySignal] {
        // 한국 휴대폰. 흔하고 덜 민감하므로 low-precision(점수만, 단독 차단 안 함).
        let pattern = #"\b01[016789][-\s]?\d{3,4}[-\s]?\d{4}\b"#
        return Self.regexMatches(pattern, in: text).map { range in
            SensitivitySignal(
                type: .phoneNumber,
                score: SensitivityType.phoneNumber.baseScore,
                textRange: range,
                isHighPrecision: false
            )
        }
    }

    private func detectEmails(in text: String) -> [SensitivitySignal] {
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        return Self.regexMatches(pattern, in: text).map { range in
            SensitivitySignal(
                type: .email,
                score: SensitivityType.email.baseScore,
                textRange: range,
                isHighPrecision: false
            )
        }
    }

    /// 의료/금융/주소 문맥 — 문맥어 존재만으로 점수에 기여(단독 차단 안 함). 유형별 1회만.
    private func detectContextual(in text: String) -> [SensitivitySignal] {
        var signals: [SensitivitySignal] = []
        let medical = #"병원|의원|클리닉|처방|진단|증상|복용|진료|환자|수술|보험금|소견서"#
        if let range = Self.firstRange(medical, in: text) {
            signals.append(SensitivitySignal(type: .medical, score: SensitivityType.medical.baseScore,
                                             textRange: range, isHighPrecision: false))
        }
        let finance = #"급여|월급|연봉|세금|계약서|송금|대출|이자|보험료|청구서"#
        if let range = Self.firstRange(finance, in: text) {
            signals.append(SensitivitySignal(type: .finance, score: SensitivityType.finance.baseScore,
                                             textRange: range, isHighPrecision: false))
        }
        // 한국 주소: 시·도 + 시군구 + 도로명/동 + 번지. NSDataDetector 가 한국 주소에 약해 룰 보강.
        let address = #"[가-힣]+(?:특별시|광역시|특별자치시|도)\s*[가-힣]+(?:시|군|구)\s*[가-힣0-9]+(?:로|길|동|읍|면)"#
        if let range = Self.firstRange(address, in: text) {
            signals.append(SensitivitySignal(type: .address, score: SensitivityType.address.baseScore,
                                             textRange: range, isHighPrecision: false))
        }
        return signals
    }

    /// 사용자가 명시적으로 라벨링한 민감정보(예: "카드번호: ...", "비밀번호: ..."). 라벨이 의도를
    /// 강하게 드러내므로 값이 체크섬/길이 검증에 미달해도 고신뢰로 채택한다(메모에 라벨 붙여 적는 흔한 패턴).
    private func detectLabeledSecrets(in text: String) -> [SensitivitySignal] {
        let labeled: [(label: String, type: SensitivityType)] = [
            (#"비밀\s?번호|패스\s?워드|password|passwd|\bpwd\b"#, .passwordOrToken),
            (#"카드\s?번호|카드\s?정보|cvc|cvv"#, .cardNumber),
            (#"주민\s?(?:등록)?\s?번호"#, .nationalID),
            (#"계좌\s?번호|예금주"#, .bankAccount),
        ]
        var signals: [SensitivitySignal] = []
        for (label, type) in labeled {
            // 값에 공백이 끼어도(예: `카드번호: 1234 5678 9012 3456`) 같은 줄 토큰을 이어 잡는다 —
            // 한 토큰만 잡으면 나머지 번호가 블러를 빠져나가 노출될 수 있다(`\n` 은 넘지 않음).
            let pattern = "(?:\(label))\\s*[:=]\\s*(\\S{2,}(?:[ \\t]+\\S+)*)"
            signals += Self.regexMatches(pattern, in: text, captureGroup: 1, options: [.caseInsensitive]).map {
                SensitivitySignal(type: type, score: type.baseScore, textRange: $0, isHighPrecision: true)
            }
        }
        return signals
    }

    // MARK: - Regex 헬퍼

    /// 매치된 전체(또는 지정 캡처그룹)의 `Range<String.Index>` 목록.
    static func regexMatches(
        _ pattern: String,
        in text: String,
        captureGroup: Int = 0,
        options: NSRegularExpression.Options = []
    ) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { result in
            guard captureGroup < result.numberOfRanges else { return nil }
            return Range(result.range(at: captureGroup), in: text)
        }
    }

    static func firstRange(_ pattern: String, in text: String) -> Range<String.Index>? {
        regexMatches(pattern, in: text).first
    }

    /// 문자열에서 ASCII 숫자만 추출.
    static func digits(of s: Substring) -> [Int] {
        s.compactMap { c in (c.isASCII && c.isNumber) ? c.wholeNumberValue : nil }
    }

    private static func hasValidBirthdate(_ digits13: [Int]) -> Bool {
        let mm = digits13[2] * 10 + digits13[3]
        let dd = digits13[4] * 10 + digits13[5]
        guard (1...12).contains(mm), dd >= 1 else { return false }
        // 세기·윤년을 알 수 없어 2월은 29일까지 관대하게 허용. 월별 최대 일수로 명백한 무효(2/31, 11/31)를 거른다.
        let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return dd <= daysInMonth[mm - 1]
    }
}
