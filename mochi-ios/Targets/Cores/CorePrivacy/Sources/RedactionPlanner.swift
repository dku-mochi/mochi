import CoreGraphics
import Foundation

/// 사용자가 개별 토글할 수 있는 블러 후보 영역 — 한 OCR box(대개 한 줄)에 대응한다.
///
/// 같은 box 에 여러 신호가 겹치면 `types` 에 모인다(라벨·정렬용). `types` 가 비어 있으면
/// 자동 감지엔 안 걸렸지만 사용자가 직접 가릴 수 있는 일반 텍스트 후보다.
public struct RedactionRegion: Identifiable, Sendable, Equatable, Hashable {
    public let id: UUID
    /// 블러할 영역(Vision 정규화 좌표, 원점 좌하단, 0–1).
    public let rect: CGRect
    /// 이 영역에 걸린 민감 유형(라벨용). 비어 있으면 사용자 수동 후보.
    public let types: [SensitivityType]

    public init(id: UUID = UUID(), rect: CGRect, types: [SensitivityType]) {
        self.id = id
        self.rect = rect
        self.types = types
    }

    /// 대표 유형 — 가장 민감한(점수 높은) 것. 칩 라벨·아이콘에 쓴다. 수동 후보면 nil.
    public var primaryType: SensitivityType? {
        types.max(by: { $0.baseScore < $1.baseScore })
    }
}

/// 감지된 민감 신호의 텍스트 위치를 OCR box 의 이미지 좌표로 역매핑해, **블러할 사각형 목록**을 만든다.
///
/// 블러 단위는 OCR box(대개 한 줄) 전체다 — 민감 토큰만 정밀히 가리는 것보다 box 전체를 가리는 쪽이
/// 단순하고 안전하다(주변 맥락도 함께 가림). 반환 사각형은 Vision 정규화 좌표(원점 좌하단, 0–1).
public struct RedactionPlanner {
    public init() {}

    /// 감지 신호를 OCR box 단위로 묶어 **라벨이 달린 블러 후보 영역**을 만든다. 같은 box 에 여러
    /// 신호가 겹치면 한 영역으로 합치고 유형을 모은다(사용자가 "여기 전화번호+이메일" 을 한 번에 토글).
    public func redactionRegions(
        text: String,
        boxes: [RecognizedTextBox],
        signals: [SensitivitySignal]
    ) -> [RedactionRegion] {
        let boxRanges = Self.boxRanges(text: text, boxes: boxes)
        // box rect 등장 순서를 보존하며 유형을 누적한다.
        var order: [CGRect] = []
        var typesByRect: [CGRect: [SensitivityType]] = [:]
        for signal in signals {
            guard let range = signal.textRange else { continue }
            for (boxRange, rect) in boxRanges where boxRange.overlaps(range) {
                if typesByRect[rect] == nil { order.append(rect) }
                if !(typesByRect[rect]?.contains(signal.type) ?? false) {
                    typesByRect[rect, default: []].append(signal.type)
                }
            }
        }
        return order.map { RedactionRegion(rect: $0, types: typesByRect[$0] ?? []) }
    }

    /// - Parameters:
    ///   - text: `ImageTextExtractor.joinedText(boxes)` 와 동일하게 구성된 전체 텍스트.
    ///   - boxes: OCR 결과(text + 정규화 bbox).
    ///   - signals: 감지 신호(각 신호의 `textRange` 가 `text` 기준).
    /// - Returns: 블러할 정규화 사각형 목록(중복 제거).
    public func redactionRects(
        text: String,
        boxes: [RecognizedTextBox],
        signals: [SensitivitySignal]
    ) -> [CGRect] {
        let boxRanges = Self.boxRanges(text: text, boxes: boxes)
        var rects: [CGRect] = []
        for signal in signals {
            guard let range = signal.textRange else { continue }
            for (boxRange, rect) in boxRanges where boxRange.overlaps(range) {
                if !rects.contains(rect) { rects.append(rect) }
            }
        }
        return rects
    }

    /// 각 OCR box 가 `text`(="\n" join) 안에서 차지하는 range 를 재구성한다.
    static func boxRanges(text: String, boxes: [RecognizedTextBox]) -> [(Range<String.Index>, CGRect)] {
        var result: [(Range<String.Index>, CGRect)] = []
        var idx = text.startIndex
        for (i, box) in boxes.enumerated() {
            guard let end = text.index(idx, offsetBy: box.text.count, limitedBy: text.endIndex) else { break }
            result.append((idx..<end, box.boundingBox))
            // 다음 박스 앞의 "\n" 한 칸 건너뛴다.
            if i < boxes.count - 1 {
                guard let next = text.index(end, offsetBy: 1, limitedBy: text.endIndex) else { break }
                idx = next
            } else {
                idx = end
            }
        }
        return result
    }
}
