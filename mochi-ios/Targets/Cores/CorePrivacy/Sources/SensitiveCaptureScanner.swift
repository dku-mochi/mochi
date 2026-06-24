import CoreGraphics
import Foundation

/// 한 캡처 스캔 결과 — 민감도 평가 + 블러할 영역 + 사용자 수동 가림 후보.
public struct SensitiveCaptureScanResult: Sendable, Equatable {
    public let assessment: SensitivityAssessment
    /// 자동 감지된 블러 후보 영역(유형 라벨 포함). 기본 블러 대상.
    public let regions: [RedactionRegion]
    /// OCR 로 인식된 **모든** 텍스트 줄의 영역(Vision 정규화). 자동 감지엔 안 걸렸어도 사용자가
    /// 직접 가릴 수 있는 후보 — "조금 민감한 게 많은" 캡처에서 수동 가림의 타깃이 된다.
    public let textBoxes: [CGRect]
    /// OCR 로 읽어낸 화면 transcript(줄 join). **분석 전용 ephemeral** — 서버가 추론 컨텍스트로만
    /// 쓰고 추론 후 삭제한다(영속/노출/인덱스 없음). 이미지 캡처에만 있고 텍스트 캡처는 `nil`.
    /// 업로드 경로가 정책에 따라 동봉 여부를 고른다(originalUpload 일 때만 — PRIVACY §9).
    public let ocrText: String?

    /// 자동 감지 영역의 정규화 사각형 — 기존 호출부 호환용 편의 접근자.
    public var redactionRects: [CGRect] { regions.map(\.rect) }

    public init(
        assessment: SensitivityAssessment,
        regions: [RedactionRegion],
        textBoxes: [CGRect],
        ocrText: String? = nil
    ) {
        self.assessment = assessment
        self.regions = regions
        self.textBoxes = textBoxes
        self.ocrText = ocrText
    }
}

/// 저장 시점 민감 캡처 감지의 단일 진입점(facade).
///
/// OCR → 패턴 감지 → 점수 → 블러 영역 산출을 한 번에 묶는다. 호출부(ShareExtension·백탭·앱)는
/// 이것만 호출하면 된다. 모델 0·완전 결정론적이라 Share Extension 메모리 한도에서 안전.
public struct SensitiveCaptureScanner {
    private let extractor = ImageTextExtractor()
    private let detector = SensitiveDataDetector()
    private let scorer = SensitivityScorer()
    private let planner = RedactionPlanner()

    public init() {}

    /// 이미지 캡처(스크린샷 등). OCR 후 텍스트 패턴을 감지하고 블러 영역까지 계산한다.
    public func scan(cgImage: CGImage) async -> SensitiveCaptureScanResult {
        let boxes = await extractor.recognize(in: cgImage)
        let text = ImageTextExtractor.joinedText(boxes)
        let signals = detector.detect(in: text)
        let assessment = scorer.assess(signals)
        let regions = planner.redactionRegions(text: text, boxes: boxes, signals: signals)
        return SensitiveCaptureScanResult(
            assessment: assessment,
            regions: regions,
            textBoxes: boxes.map(\.boundingBox),
            ocrText: text.isEmpty ? nil : text
        )
    }

    /// 텍스트 캡처(메모·URL 등). 블러 영역은 없고 패턴 점수만 낸다.
    public func scan(text: String) -> SensitiveCaptureScanResult {
        let signals = detector.detect(in: text)
        let assessment = scorer.assess(signals)
        return SensitiveCaptureScanResult(assessment: assessment, regions: [], textBoxes: [])
    }
}
