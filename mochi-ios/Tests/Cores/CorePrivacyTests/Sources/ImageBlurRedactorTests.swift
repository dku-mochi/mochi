import CoreGraphics
import XCTest
@testable import CorePrivacy

/// 영역-한정 블러(메모리 최적화)가 가림 정확성을 유지하는지 검증한다 — **가릴 영역만 블러되고
/// 영역 밖은 원본 보존**. 이 불변식이 깨지면 (a) 마스크 안이 안 블러되면 민감정보 누설, (b) 마스크
/// 밖이 바뀌면 원본 손상이라 둘 다 회귀로 잡아야 한다(ShareExt 120MB 한도용 region-crop 도입 회귀).
final class ImageBlurRedactorTests: XCTestCase {
    private let redactor = ImageBlurRedactor()

    /// 세로 띠 3개(RED|GREEN|BLUE)에 sharp edge 2개. 왼쪽 edge(red/green) 주변만 가리는 rect 를
    /// 주면, edge 안쪽은 blend(변경)되고 띠 양 끝(rect 밖)은 순색 원본이 보존돼야 한다.
    func test_blurs_only_masked_region_and_preserves_outside() throws {
        let size = 120
        let original = try makeStripeImage(width: size, height: size)
        // Vision 정규화(원점 좌하단). x∈[0.25,0.42] 는 픽셀 ≈30–50 으로 x=40 의 red/green edge 를 덮는다.
        let rect = CGRect(x: 0.25, y: 0.0, width: 0.17, height: 1.0)

        let blurred = try XCTUnwrap(redactor.redactedImage(from: original, normalizedRects: [rect]))
        XCTAssertEqual(blurred.width, size)
        XCTAssertEqual(blurred.height, size)

        let pixels = try readPixels(blurred, width: size, height: size)
        // (1) rect 밖 왼쪽 끝 — 원본 RED 보존.
        assertColor(pixels.at(5, 60, size), red: 255, green: 0, blue: 0, tol: 4, label: "rect 밖(좌) 원본 RED 보존")
        // (2) rect 밖 오른쪽 끝 — 원본 BLUE 보존(이 edge 는 가리지 않았다).
        assertColor(pixels.at(114, 60, size), red: 0, green: 0, blue: 255, tol: 4, label: "rect 밖(우) 원본 BLUE 보존")
        // (3) rect 안 red/green edge(x=40) — 블러로 섞여 순색이 아니어야 한다(가림 발효).
        let edge = pixels.at(40, 60, size)
        XCTAssertTrue(
            edge.r > 8 && edge.r < 247 && edge.g > 8 && edge.g < 247,
            "rect 안 edge 픽셀은 블러로 섞여야 함(순 RED/GREEN 아님) — got r=\(edge.r) g=\(edge.g) b=\(edge.b)"
        )
    }

    /// 떨어진 영역 2개 — **둘 다** 블러되고 그 사이 간격(마스크 밖)은 원본 보존돼야 한다.
    /// 합집합 박스가 넓어도 마스크 흰 영역만 블러된다(region-crop 이 영역을 빠뜨리지 않음).
    func test_blurs_each_of_multiple_separated_regions_preserving_gap() throws {
        let size = 120
        let original = try makeStripeImage(width: size, height: size)
        let left = CGRect(x: 0.25, y: 0.0, width: 0.17, height: 1.0)   // red/green edge(x=40)
        let right = CGRect(x: 0.58, y: 0.0, width: 0.17, height: 1.0)  // green/blue edge(x=80)

        let blurred = try XCTUnwrap(redactor.redactedImage(from: original, normalizedRects: [left, right]))
        let pixels = try readPixels(blurred, width: size, height: size)

        let edgeL = pixels.at(40, 60, size)
        XCTAssertTrue(edgeL.r > 8 && edgeL.r < 247 && edgeL.g > 8, "왼쪽 영역 edge 블러됨 — got \(edgeL)")
        let edgeR = pixels.at(80, 60, size)
        XCTAssertTrue(edgeR.g > 8 && edgeR.b > 8 && edgeR.b < 247, "오른쪽 영역 edge 블러됨 — got \(edgeR)")
        // 두 영역 사이 간격(순 GREEN, 마스크 밖) 보존.
        assertColor(pixels.at(60, 60, size), red: 0, green: 255, blue: 0, tol: 4, label: "영역 사이 간격 GREEN 보존")
        assertColor(pixels.at(5, 60, size), red: 255, green: 0, blue: 0, tol: 4, label: "좌측 끝 RED 보존")
        assertColor(pixels.at(114, 60, size), red: 0, green: 0, blue: 255, tol: 4, label: "우측 끝 BLUE 보존")
    }

    /// 이미지 가장자리에 붙은 rect — 마스크 흰 영역이 경계를 넘어 clamp 돼도, region 이 마스크를 포함해
    /// 영역 안 edge 가 정상 블러되고(under-blur 없음) 영역 밖은 보존된다.
    func test_blurs_edge_attached_region_without_clamp_dropping_mask() throws {
        let size = 120
        let original = try makeStripeImage(width: size, height: size)
        // x∈[0.58,1.0]: 픽셀 ≈70–120 으로 green/blue edge(x=80)를 덮고 오른쪽 경계에 붙는다.
        let rect = CGRect(x: 0.58, y: 0.0, width: 0.42, height: 1.0)

        let blurred = try XCTUnwrap(redactor.redactedImage(from: original, normalizedRects: [rect]))
        let pixels = try readPixels(blurred, width: size, height: size)

        let edge = pixels.at(80, 60, size)
        XCTAssertTrue(edge.g > 8 && edge.b > 8 && edge.b < 247, "경계 부착 영역 안 edge 블러됨 — got \(edge)")
        assertColor(pixels.at(10, 60, size), red: 255, green: 0, blue: 0, tol: 4, label: "영역 밖 RED 보존")
        assertColor(pixels.at(55, 60, size), red: 0, green: 255, blue: 0, tol: 4, label: "영역 밖 GREEN 보존")
    }

    func test_returns_nil_when_no_rects() throws {
        let original = try makeStripeImage(width: 40, height: 40)
        XCTAssertNil(redactor.redactedImage(from: original, normalizedRects: []))
    }

    // MARK: - helpers

    private func makeStripeImage(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let third = CGFloat(width) / 3
        let h = CGFloat(height)
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: third, height: h))
        ctx.setFillColor(red: 0, green: 1, blue: 0, alpha: 1); ctx.fill(CGRect(x: third, y: 0, width: third, height: h))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 2 * third, y: 0, width: third, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    private struct Pixels {
        let buffer: [UInt8]
        let bytesPerRow: Int
        /// CGContext 원점 좌하단 — y 를 뒤집어 (x, y[bottom-up]) 픽셀을 읽는다.
        func at(_ x: Int, _ yFromBottom: Int, _ height: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
            let row = height - 1 - yFromBottom
            let i = row * bytesPerRow + x * 4
            return (buffer[i], buffer[i + 1], buffer[i + 2])
        }
    }

    private func readPixels(_ image: CGImage, width: Int, height: Int) throws -> Pixels {
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        // 컨텍스트 메모리가 buffer 를 가리키므로 draw 까지 포인터 스코프 안에서 끝낸다(escape 금지).
        try buffer.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(buffer: buffer, bytesPerRow: bytesPerRow)
    }

    private func assertColor(
        _ p: (r: UInt8, g: UInt8, b: UInt8), red: UInt8, green: UInt8, blue: UInt8,
        tol: Int, label: String
    ) {
        XCTAssertLessThanOrEqual(abs(Int(p.r) - Int(red)), tol, "\(label) R")
        XCTAssertLessThanOrEqual(abs(Int(p.g) - Int(green)), tol, "\(label) G")
        XCTAssertLessThanOrEqual(abs(Int(p.b) - Int(blue)), tol, "\(label) B")
    }
}
