import CoreGraphics
import Foundation
import ImageIO
import Vision

/// OCR 로 인식한 텍스트 한 덩어리와 그 위치(Vision 정규화 좌표: 원점 좌하단, 0–1).
public struct RecognizedTextBox: Sendable, Equatable {
    public let text: String
    public let boundingBox: CGRect

    public init(text: String, boundingBox: CGRect) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// Apple Vision 으로 이미지에서 텍스트와 bounding box 를 추출한다.
///
/// 시스템이 관리하는 OCR 이라 앱 프로세스 메모리에 모델 가중치를 올리지 않는다 — Share Extension
/// 120MB 한도에서도 (downscale 된 이미지로) 안전하게 호출할 수 있다.
public struct ImageTextExtractor {
    public init() {}

    public func recognize(in cgImage: CGImage) async -> [RecognizedTextBox] {
        await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let boxes = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { obs -> RecognizedTextBox? in
                        guard let candidate = obs.topCandidates(1).first else { return nil }
                        return RecognizedTextBox(text: candidate.string, boundingBox: obs.boundingBox)
                    }
                continuation.resume(returning: boxes)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true
            // 입력 cgImage 는 호출부(`downsampledCGImage(transform:true)`)가 EXIF orientation 을 베이크한
            // 정립 픽셀이라 `.up`. 블러 마스크(`ImageBlurRedactor`)도 같은 정립 이미지를 쓰므로 OCR
            // boundingBox 와 좌표계가 일치한다 — 비정립 EXIF 로 가림이 빗나가지 않게 정립을 단언한다.
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }

    /// 인식된 박스들을 줄바꿈으로 이어붙인 전체 텍스트. `RedactionPlanner` 의 매핑 규칙과 동일하게
    /// `"\n"` 으로 join 한다(둘이 같은 규칙을 써야 textRange↔bbox 매핑이 어긋나지 않는다).
    public static func joinedText(_ boxes: [RecognizedTextBox]) -> String {
        boxes.map(\.text).joined(separator: "\n")
    }
}
