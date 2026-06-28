import XCTest
@testable import CorePrivacy

/// `OCRTextNormalizer` — **길이(UTF-16) 보존** 불변식과 표면 변형 정규화를 검증한다.
/// 길이 보존이 깨지면 `SensitiveDataDetector` 의 textRange→블러 영역 매핑이 어긋난다.
final class OCRTextNormalizerTests: XCTestCase {
    func test_fullWidthDigitsToHalfWidth() {
        XCTAssertEqual(OCRTextNormalizer.normalize("１２３４５６７８９０"), "1234567890")
    }

    func test_fullWidthLettersAndSymbols() {
        XCTAssertEqual(OCRTextNormalizer.normalize("ＡＢＣ＠ｚ"), "ABC@z")
    }

    func test_unicodeDashesToHyphen() {
        // hyphen(2010)·figure dash(2012)·en dash(2013)·em dash(2014)·minus(2212)·전각(FF0D)
        XCTAssertEqual(
            OCRTextNormalizer.normalize("a\u{2010}b\u{2012}c\u{2013}d\u{2014}e\u{2212}f\u{FF0D}g"),
            "a-b-c-d-e-f-g"
        )
    }

    func test_unicodeSpacesToAsciiSpace() {
        // NBSP(00A0)·en space(2002)·narrow NBSP(202F)·전각 공백(3000)
        XCTAssertEqual(OCRTextNormalizer.normalize("a\u{00A0}b\u{2002}c\u{202F}d\u{3000}e"), "a b c d e")
    }

    func test_lengthPreserved_isInvariant() {
        // 핵심 불변식: 정규화는 UTF-16 길이를 절대 바꾸지 않는다(textRange 매핑 보호).
        let inputs = [
            "１２３４－５６７８　ＡＢ",
            "신한은행 110\u{2013}234\u{2013}567890 입금",
            "plain ascii 1234-5678",
            "혼합 ＯＴＰ\u{00A0}482910",
        ]
        for s in inputs {
            XCTAssertEqual(
                OCRTextNormalizer.normalize(s).utf16.count, s.utf16.count,
                "정규화는 UTF-16 길이를 보존해야 한다: \(s)"
            )
        }
    }

    func test_doesNotMangleAsciiLetters() {
        // 글리프 혼동 치환은 하지 않는다 — "OTP" 의 O 가 0 으로 바뀌면 안 된다(영문 보존, 과교정 회피).
        XCTAssertEqual(OCRTextNormalizer.normalize("OTP login O0l1"), "OTP login O0l1")
    }
}
