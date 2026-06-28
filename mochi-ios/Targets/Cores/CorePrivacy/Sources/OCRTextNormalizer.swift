import Foundation

/// OCR 로 읽어낸 텍스트의 표면 변형을 정규화한다 — **반드시 길이(문자 수·UTF-16 offset)를 보존**한다.
///
/// 길이를 보존하는 이유: 감지 신호의 `textRange` 가 정규화된 텍스트에서 잡히지만, 같은 텍스트를
/// `RedactionPlanner` 가 OCR box 길이로 다시 쪼개 블러 영역에 매핑한다(`SensitiveCaptureScanner`).
/// 정규화가 길이를 바꾸면 box 경계가 어긋나 블러가 엉뚱한 줄에 찍힌다. 그래서 1 스칼라 → 1 스칼라
/// 치환만 허용하고(삭제·삽입 금지), `SensitiveDataDetector` 가 매칭 후 textRange 를 같은 offset 으로
/// 원본 문자열에 되돌린다.
///
/// 다루는 변형(OCR 이 흔히 만드는, 정규식 매칭을 깨는 표면 차이):
/// - 전각(full-width) 영숫자·기호 → 반각: `１２３４` → `1234`, `ＡＢ＠` → `AB@`.
/// - 유니코드 대시류(en/em dash·minus·figure dash 등) → ASCII `-`: 카드·주민·전화 구분자 매칭.
/// - 비표준 공백(NBSP·전각 공백 등) → ASCII space.
///
/// **의도적으로 안 하는 것**: 글리프 혼동 치환(`O`→`0`, `l`→`1`)은 영문 단어("OTP")를 깨고
/// 과교정으로 false positive 를 늘려 제외한다. 검증기(Luhn·체크섬)+문맥이 정밀도의 핵심이라,
/// 표면 정규화만으로 OCR 변형의 실효 부분을 흡수한다.
public enum OCRTextNormalizer {
    /// 길이 보존 정규화. 반환 문자열의 UTF-16 길이는 입력과 항상 같다.
    public static func normalize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars { scalars.append(mapped(s)) }
        return String(scalars)
    }

    private static func mapped(_ s: Unicode.Scalar) -> Unicode.Scalar {
        switch s.value {
        // 전각 영숫자·기호(U+FF01…FF5E) → 반각(U+0021…007E). 전각 하이픈 U+FF0D 도 여기서 '-' 가 된다.
        case 0xFF01...0xFF5E:
            return Unicode.Scalar(s.value - 0xFEE0) ?? s
        // 대시류 → ASCII hyphen-minus.
        case 0x2010...0x2015,  // hyphen, non-breaking hyphen, figure dash, en dash, em dash, horizontal bar
             0x2212,           // minus sign
             0xFE58, 0xFE63:   // small em dash, small hyphen-minus
            return "-"
        // 공백류 → ASCII space.
        case 0x00A0,           // no-break space
             0x2000...0x200A,  // en quad … hair space
             0x202F, 0x205F,   // narrow no-break space, medium mathematical space
             0x3000:           // ideographic(full-width) space
            return " "
        default:
            return s
        }
    }
}
