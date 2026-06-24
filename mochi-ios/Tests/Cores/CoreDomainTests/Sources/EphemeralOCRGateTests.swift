import XCTest
@testable import CoreDomain

/// 분석 전용 ephemeral OCR 업로드 게이트 — **effective policy == originalUpload 일 때만 동봉**.
///
/// 두 업로드 경로(`MochiItemSyncWorker`·`ShareExtDirectUpload`)가 공유하는 단일 정책이라
/// 여기서 한 번 검증하면 양쪽이 동일하게 동작한다. 근거: blurredUpload 는 블러 전 raw OCR
/// (카드번호 등)이 가린 걸 누설하므로 제외, localOnly 는 이미지처럼 미전송(PRIVACY §9).
final class EphemeralOCRGateTests: XCTestCase {
    private let ocr = "예매번호 A1234  카드 1234-5678-9012-3456"

    func test_nonSensitive_default_includes_ocr() {
        // privacy == nil → effective originalUpload → 동봉(정보밀도 높은 일반 스크린샷의 핵심 가치).
        XCTAssertEqual(EphemeralOCRGate.textForUpload(privacy: nil, ocrText: ocr), ocr)
    }

    func test_originalUpload_includes_ocr() {
        let privacy = PrivacyDecision(policy: .originalUpload, level: .sensitive)
        XCTAssertEqual(EphemeralOCRGate.textForUpload(privacy: privacy, ocrText: ocr), ocr)
    }

    func test_blurredUpload_excludes_ocr() {
        // 사용자가 이미지에서 가린 걸 raw OCR 로 누설하지 않는다.
        let privacy = PrivacyDecision(policy: .blurredUpload, level: .sensitive)
        XCTAssertNil(EphemeralOCRGate.textForUpload(privacy: privacy, ocrText: ocr))
    }

    func test_localOnly_excludes_ocr() {
        // 이미지도 미전송 → OCR 도 미전송.
        let privacy = PrivacyDecision(policy: .localOnly, level: .highlySensitive)
        XCTAssertNil(EphemeralOCRGate.textForUpload(privacy: privacy, ocrText: ocr))
    }

    func test_nil_ocr_stays_nil() {
        XCTAssertNil(EphemeralOCRGate.textForUpload(privacy: nil, ocrText: nil))
    }
}
