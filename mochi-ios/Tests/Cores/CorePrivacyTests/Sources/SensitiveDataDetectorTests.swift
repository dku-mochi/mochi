import XCTest
@testable import CorePrivacy

/// 검증기 정밀도 + false positive 억제 검증. FP 가 저장 흐름을 막는 UX 마찰을 차단하는 게 핵심이라
/// "검증/문맥 통과만 채택"을 집중 검증한다.
final class SensitiveDataDetectorTests: XCTestCase {
    private let detector = SensitiveDataDetector()

    // MARK: - 검증기 순수 함수

    func test_luhn_validCard() {
        // 4242 4242 4242 4242 — 표준 테스트 카드(Luhn 통과).
        XCTAssertTrue(SensitiveDataDetector.isValidLuhn([4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2, 4, 2]))
    }

    func test_luhn_invalid() {
        XCTAssertFalse(SensitiveDataDetector.isValidLuhn([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6]))
    }

    func test_nationalIDChecksum() {
        XCTAssertTrue(SensitiveDataDetector.isValidNationalIDChecksum([8, 8, 0, 1, 0, 1, 1, 2, 3, 4, 5, 6, 8]))
        XCTAssertFalse(SensitiveDataDetector.isValidNationalIDChecksum([8, 8, 0, 1, 0, 1, 1, 2, 3, 4, 5, 6, 0]))
    }

    func test_businessNumberChecksum() {
        XCTAssertTrue(SensitiveDataDetector.isValidBusinessNumberChecksum([2, 2, 0, 8, 1, 6, 2, 5, 1, 7]))
        XCTAssertFalse(SensitiveDataDetector.isValidBusinessNumberChecksum([2, 2, 0, 8, 1, 6, 2, 5, 1, 0]))
    }

    // MARK: - 고신뢰 감지 (검증/문맥 통과)

    func test_detectsValidCard() {
        let signals = detector.detect(in: "결제 카드 4242 4242 4242 4242 승인 완료")
        let card = signals.first { $0.type == .cardNumber }
        XCTAssertNotNil(card)
        XCTAssertTrue(card?.isHighPrecision == true)
    }

    func test_detectsNationalID() {
        let signals = detector.detect(in: "주민번호 880101-1234568 확인")
        XCTAssertTrue(signals.contains { $0.type == .nationalID && $0.isHighPrecision })
    }

    func test_detectsBusinessNumber() {
        let signals = detector.detect(in: "사업자등록번호 220-81-62517")
        XCTAssertTrue(signals.contains { $0.type == .businessNumber && $0.isHighPrecision })
    }

    func test_detectsOTPWithContext() {
        let signals = detector.detect(in: "[모찌] 인증번호 482910 을 입력하세요")
        XCTAssertTrue(signals.contains { $0.type == .otpCode && $0.isHighPrecision })
    }

    func test_detectsToken() {
        let signals = detector.detect(in: "api_key=sk_live_abc123XYZ789def")
        XCTAssertTrue(signals.contains { $0.type == .passwordOrToken && $0.isHighPrecision })
    }

    func test_detectsBankAccountWithBankContext() {
        let signals = detector.detect(in: "신한은행 110-234-567890 으로 입금해주세요")
        XCTAssertTrue(signals.contains { $0.type == .bankAccount && $0.isHighPrecision })
    }

    // MARK: - False positive 억제

    func test_ignoresInvalidCard() {
        // Luhn 실패 16자리(주문번호 등) → 카드 신호 없음.
        let signals = detector.detect(in: "주문번호 1234 5678 9012 3456 조회")
        XCTAssertNil(signals.first { $0.type == .cardNumber })
    }

    func test_ignoresInvalidBirthdateNationalID() {
        // MM=99 → 생년월일 무효 → 주민번호 아님.
        let signals = detector.detect(in: "코드 889901-1234567")
        XCTAssertNil(signals.first { $0.type == .nationalID })
    }

    func test_ignoresNumberWithoutOTPContext() {
        // 인증/보안 문맥어가 없으면 짧은 숫자는 무시.
        let signals = detector.detect(in: "회의실 482910 호로 오세요")
        XCTAssertNil(signals.first { $0.type == .otpCode })
    }

    func test_ignoresPlain10DigitsWithoutChecksum() {
        // 체크섬 실패 10자리 → 사업자번호 아님.
        let signals = detector.detect(in: "참조 0123456789 번")
        XCTAssertNil(signals.first { $0.type == .businessNumber })
    }

    // MARK: - 저신뢰(점수만, 단독 차단 안 함)

    func test_detectsPhoneLowPrecision() {
        let signals = detector.detect(in: "연락처 010-1234-5678")
        let phone = signals.first { $0.type == .phoneNumber }
        XCTAssertNotNil(phone)
        XCTAssertFalse(phone?.isHighPrecision == true)
    }

    func test_detectsEmailLowPrecision() {
        let signals = detector.detect(in: "메일 test@example.com 으로 보내줘")
        let email = signals.first { $0.type == .email }
        XCTAssertNotNil(email)
        XCTAssertFalse(email?.isHighPrecision == true)
    }

    func test_ignoresImpossibleDateNationalID() {
        // 2월 31일 — 형식은 맞지만 불가능한 날짜(codex P2: 월별 일수 검증).
        let signals = detector.detect(in: "코드 990231-1234567")
        XCTAssertNil(signals.first { $0.type == .nationalID })
    }

    func test_detectsOTPCaseInsensitive() {
        // 소문자 otp 도 잡아야 한다(codex P2: caseInsensitive).
        let signals = detector.detect(in: "otp 482910 입력하세요")
        XCTAssertTrue(signals.contains { $0.type == .otpCode && $0.isHighPrecision })
    }

    func test_detectsBearerToken() {
        // `Bearer <token>` 형식(구분자 없는 공백) — codex P2.
        let signals = detector.detect(in: "Authorization: Bearer abc123XYZ789tok")
        XCTAssertTrue(signals.contains { $0.type == .passwordOrToken && $0.isHighPrecision })
    }

    func test_detectsLabeledCardEvenIfLuhnFails() {
        // 라벨이 명시되면 Luhn 실패 더미값(1111…)도 잡는다 — 사용자가 라벨 붙여 적은 메모 캡처.
        let signals = detector.detect(in: "카드번호: 1111-1111-1111-1111")
        XCTAssertTrue(signals.contains { $0.type == .cardNumber && $0.isHighPrecision })
    }

    func test_detectsLabeledShortPassword() {
        // 라벨이 명시되면 6자 미만 값도 잡는다.
        let signals = detector.detect(in: "비밀번호: 1234")
        XCTAssertTrue(signals.contains { $0.type == .passwordOrToken && $0.isHighPrecision })
    }

    func test_emptyText() {
        XCTAssertTrue(detector.detect(in: "").isEmpty)
    }

    // MARK: - 정규식 커버리지 보강 (codex review: FN 축소)

    func test_labeledSecretWithSpaces_capturesFullValue() {
        // 라벨값에 공백이 끼어도(카드번호 4그룹) textRange 가 마지막 그룹까지 덮어야 블러가 전체를 가린다.
        let text = "카드번호: 1234 5678 9012 3456"
        let card = detector.detect(in: text).first { $0.type == .cardNumber }
        XCTAssertNotNil(card)
        if let range = card?.textRange {
            XCTAssertTrue(text[range].contains("3456"), "마지막 그룹까지 textRange 에 포함돼야 블러가 전체를 덮는다")
        }
    }

    func test_detectsAmexCard() {
        // 15자리 Amex 4-6-5 (378282246310005, Luhn 통과).
        let signals = detector.detect(in: "카드 3782 822463 10005 결제")
        XCTAssertTrue(signals.contains { $0.type == .cardNumber && $0.isHighPrecision })
    }

    func test_detectsCardWithoutSeparators() {
        // 구분자 없는 16자리 연속(4242424242424242, Luhn 통과).
        let signals = detector.detect(in: "카드 4242424242424242 승인")
        XCTAssertTrue(signals.contains { $0.type == .cardNumber && $0.isHighPrecision })
    }

    func test_detectsBankAccountSingleRun() {
        // 구분자 없는 가상계좌 긴 숫자도 문맥어와 함께면 잡는다.
        let signals = detector.detect(in: "입금 계좌 3012345678901 농협")
        XCTAssertTrue(signals.contains { $0.type == .bankAccount && $0.isHighPrecision })
    }

    func test_detectsOTPWithTrailingContext() {
        // 숫자가 문맥어 앞에 오는 흔한 SMS 문구(`482910 이 인증번호입니다`).
        let signals = detector.detect(in: "482910 이 인증번호입니다")
        XCTAssertTrue(signals.contains { $0.type == .otpCode && $0.isHighPrecision })
    }
}
