import Foundation

/// Gemini가 캡처에서 추출한 의미적 엔티티.
public struct ExtractedEntity: Equatable, Sendable, Hashable, Codable {
    public let kind: Kind
    public let value: String
    /// 원문 내 위치 (있는 경우). OCR 결과의 bounding box나 텍스트 offset.
    public let provenance: Provenance?

    public init(kind: Kind, value: String, provenance: Provenance? = nil) {
        self.kind = kind
        self.value = value
        self.provenance = provenance
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case person
        case place
        case organization
        case date
        case time
        case money
        case url
        case email
        case phone
        case other
    }

    public enum Provenance: Equatable, Sendable, Hashable, Codable {
        case textRange(start: Int, end: Int)
        case ocrBoundingBox(x: Double, y: Double, width: Double, height: Double)
    }
}
