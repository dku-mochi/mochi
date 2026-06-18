import SwiftUI
import CoreDomain
import CorePersistence

/// App Group 의 캡처 이미지를 **그 자체 비율로 꽉 차게** 보여주고(주변에 별도 컨테이너 박스 없이),
/// 네 모서리 핸들로 **그 자리에서 크롭**하게 한다.
///
/// - **잘림 해소**: 이전 ``SharePreviewImage`` 는 폭맞춤 + 세로 스크롤이라 "창" 처럼 일부만 보여 잘린
///   것처럼 읽혔다. 여기선 이미지를 통째로(레터박스 없이 자기 비율 그대로) 카드가 꽉 감싸 한눈에 100%.
/// - **예측 가능한 크롭**: 잘려나갈 영역은 **항상** dim 오버레이로 덮여 "이렇게 잘린다"가 정지 중에도
///   보인다(드래그 때만 보이지 않게). 모서리를 안쪽으로 끌면 줄고, 바깥(이미지 경계까지)으로 끌면
///   늘어난다 — 양방향 자유, 원본으로 되돌아가지 않는다. 드래그 중엔 dim 이 짙어지고 3분할 그리드가
///   뜬다. `crop` 바인딩(정규화 0...1, 이미지 기준)이 부모로 올라가 제출 시 ``ShareImageCropper`` 가
///   실제 파일에 적용한다. "원본" 칩으로 언제든 전체로 되돌린다.
struct ShareCropImage: View {
    let imageRef: ImageRef
    @Binding var crop: CGRect

    /// 크롭 안 한 상태(전체) — 부모가 `@State` 초기값으로 쓴다.
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// 애플 사진 크롭처럼 모서리를 거의 직각으로 — 핸들이 끝에 딱 붙게(과한 라운드면 핸들이 떠 보임).
    private let cornerRadius: CGFloat = 4
    /// 핸들이 크롭 모서리를 바깥에서 살짝 감싸 "완전히 끝에" 붙도록 내미는 양 (애플 사진처럼).
    private let bracketOverhang: CGFloat = 3

    @State private var uiImage: UIImage?
    @State private var loadFailed = false

    // 드래그 상태 (모두 이미지-로컬 좌표계).
    @State private var dragCorner: Corner?
    @State private var dragFixed: CGPoint = .zero   // 잡은 모서리의 반대편(고정점)
    @State private var liveSelection: CGRect?
    @State private var dragging = false
    @State private var ignoringDrag = false

    var body: some View {
        GeometryReader { geo in
            content(in: geo.size)
        }
    }

    @ViewBuilder
    private func content(in container: CGSize) -> some View {
        if let image = uiImage, container.width > 1, container.height > 1 {
            let size = Self.fitSize(image: image.size, in: container)
            // 카드가 이미지 비율을 꽉 감싼다(레터박스·배경 박스 없음) + 남는 공간 중앙 배치.
            imageCard(image: image, imageSize: size)
                .frame(width: size.width, height: size.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            placeholder
        }
    }

    // MARK: - Image card (이미지를 꽉 감싸는 단일 카드 — 이미지-로컬 좌표)

    private func imageCard(image: UIImage, imageSize: CGSize) -> some View {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let selection = liveSelection ?? Self.selectionRect(crop, in: bounds)
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()

            // 잘려나갈 영역은 항상 어둡게 — 정지 중에도 "이렇게 잘린다"가 예측된다.
            dimLayer(selection: selection)

            CropGrid(rect: selection)
                .opacity(dragging ? 1 : 0)

            // 코너 드래그 캐처 — 이미지 위, 핸들·칩(overlay) 아래라 칩 탭은 가로채지 않는다.
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(bounds: bounds))
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay { chrome(selection: selection, bounds: bounds) }
        .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(isCropped ? "잘린 캡처 미리보기" : "캡처 미리보기"))
        .accessibilityHint(Text("모서리 핸들을 끌어 원하는 부분만 남기거나 다시 늘릴 수 있어요"))
    }

    // MARK: - Dim (잘려나갈 영역 오버레이 — 항상 표시)

    private func dimLayer(selection: CGRect) -> some View {
        // 정지·크롭됨도 또렷하게(예측 가능), 드래그 중 더 짙게, 전체(미크롭)면 0.
        let opacity: Double = dragging ? 0.6 : (isCropped ? 0.48 : 0.0)
        return Rectangle()
            .fill(Color.black)
            .mask(
                ZStack {
                    Rectangle().fill(.white)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .frame(width: selection.width, height: selection.height)
                        .position(x: selection.midX, y: selection.midY)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            )
            .opacity(opacity)
            .allowsHitTesting(false)
    }

    // MARK: - Chrome (핸들 + 칩/힌트)

    @ViewBuilder
    private func chrome(selection: CGRect, bounds: CGRect) -> some View {
        ZStack {
            // 크롭 프레임 — 애플 사진처럼 얇은 흰 테두리(흰 캡처 위에서도 보이게 옅은 그림자).
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: selection.width, height: selection.height)
                .position(x: selection.midX, y: selection.midY)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 0)
                .allowsHitTesting(false)

            ForEach(Corner.allCases, id: \.self) { corner in
                cornerBracket(corner, in: selection, active: dragging)
            }
            .allowsHitTesting(false)   // 핸들은 장식 — 코너 드래그는 아래 캐처가 받는다

            if !dragging {
                if isCropped {
                    resetChip   // 유일하게 탭 가능 (코너에서 떨어진 상단 중앙)
                        .position(x: selection.midX, y: max(selection.minY + 22, 22))
                } else {
                    hintPill
                        .position(x: bounds.midX, y: bounds.maxY - 22)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: bounds.width, height: bounds.height)
    }

    private var resetChip: some View {
        Button(action: reset) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11, weight: .bold))
                Text("원본")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.black.opacity(0.5)))
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("원본으로 되돌리기"))
    }

    private var hintPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "crop")
                .font(.system(size: 10, weight: .bold))
            Text("모서리를 끌어 자르기")
                .font(.system(size: 12, weight: .medium, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.42)))
    }

    // MARK: - Corner bracket (두꺼운 L 핸들)

    private func cornerBracket(_ corner: Corner, in rect: CGRect, active: Bool) -> some View {
        let arm: CGFloat = active ? 26 : 22
        let thickness: CGFloat = active ? 4 : 3.5
        let align = corner.alignment
        return ZStack(alignment: align) {
            RoundedRectangle(cornerRadius: thickness / 2)
                .frame(width: arm, height: thickness)
            RoundedRectangle(cornerRadius: thickness / 2)
                .frame(width: thickness, height: arm)
        }
        .frame(width: arm, height: arm, alignment: align)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 2.5, x: 0, y: 0.5)
        .position(corner.handleCenter(in: rect, overhang: bracketOverhang, arm: arm))
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        ZStack {
            ShareDesign.cardSolid
            Image(systemName: loadFailed ? "photo.badge.exclamationmark" : "photo")
                .font(.system(size: 28))
                .foregroundStyle(ShareDesign.subtitle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(ShareDesign.cardStroke, lineWidth: 1)
        )
        .task(id: imageRef.relativePath) { await loadImage() }
    }

    // MARK: - Gesture

    private func dragGesture(bounds: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { value in
                if dragCorner == nil {
                    guard !ignoringDrag else { return }
                    let selection = Self.selectionRect(crop, in: bounds)
                    let threshold = max(64, min(selection.width, selection.height) * 0.5)
                    guard let corner = nearestCorner(to: value.startLocation, in: selection, threshold: threshold) else {
                        ignoringDrag = true
                        return
                    }
                    dragCorner = corner
                    dragFixed = corner.opposite(in: selection)
                    liveSelection = selection
                    ShareHaptics.lightTap()
                    withAnimation(.easeOut(duration: 0.18)) { dragging = true }
                }

                guard let corner = dragCorner else { return }
                // 클램프 경계는 **이미지 전체 rect** — 그래서 안쪽(축소)·바깥(확대) 모두 자유롭다.
                let minSize = max(40, min(bounds.width, bounds.height) * 0.12)
                liveSelection = resized(bounds: bounds, fixed: dragFixed, corner: corner, to: value.location, minSize: minSize)
            }
            .onEnded { _ in
                defer { ignoringDrag = false }
                guard dragCorner != nil, let sel = liveSelection else {
                    ignoringDrag = false
                    return
                }
                dragCorner = nil
                crop = Self.normalize(sel, in: bounds)
                liveSelection = nil
                ShareHaptics.selection()
                withAnimation(.easeOut(duration: 0.24)) { dragging = false }
            }
    }

    private func reset() {
        ShareHaptics.lightTap()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            crop = Self.fullCrop
        }
    }

    // MARK: - Loading

    private func loadImage() async {
        let path = imageRef.relativePath
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            let url = AppGroup.containerURL.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        await MainActor.run {
            if let loaded {
                uiImage = loaded
            } else {
                loadFailed = true
            }
        }
    }

    // MARK: - Derived

    private var isCropped: Bool { !ShareImageCropper.isFull(crop) }

    // MARK: - Geometry helpers (이미지-로컬 좌표계, origin = .zero)

    /// 이미지를 컨테이너에 fit 했을 때의 크기(카드가 이 크기로 이미지를 꽉 감싼다).
    private static func fitSize(image: CGSize, in container: CGSize) -> CGSize {
        let s = min(container.width / image.width, container.height / image.height)
        return CGSize(width: image.width * s, height: image.height * s)
    }

    /// 정규화 crop → 이미지 rect 안의 선택 사각형.
    private static func selectionRect(_ crop: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + crop.minX * bounds.width,
            y: bounds.minY + crop.minY * bounds.height,
            width: crop.width * bounds.width,
            height: crop.height * bounds.height
        )
    }

    /// 선택 사각형 → 이미지 기준 정규화 crop([0,1] 클램프).
    private static func normalize(_ sel: CGRect, in bounds: CGRect) -> CGRect {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        let x = clamp((sel.minX - bounds.minX) / bounds.width, 0, 1)
        let y = clamp((sel.minY - bounds.minY) / bounds.height, 0, 1)
        let w = clamp(sel.width / bounds.width, 0, 1 - x)
        let h = clamp(sel.height / bounds.height, 0, 1 - y)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private func nearestCorner(to point: CGPoint, in rect: CGRect, threshold: CGFloat) -> Corner? {
        let scored = Corner.allCases
            .map { ($0, hypot(point.x - $0.point(in: rect).x, point.y - $0.point(in: rect).y)) }
            .sorted { $0.1 < $1.1 }
        guard let best = scored.first, best.1 <= threshold else { return nil }
        return best.0
    }

    /// 잡은 모서리만 `bounds`(이미지 전체) 안에서 자유롭게 움직이고, 반대편 `fixed` 는 고정.
    /// 안쪽으로 끌면 축소, 바깥으로 끌면 확대 — 최소 크기만 보장한다.
    private func resized(bounds: CGRect, fixed: CGPoint, corner: Corner, to location: CGPoint, minSize: CGFloat) -> CGRect {
        var p = CGPoint(
            x: min(max(location.x, bounds.minX), bounds.maxX),
            y: min(max(location.y, bounds.minY), bounds.maxY)
        )
        switch corner {
        case .topLeft:
            p.x = min(p.x, fixed.x - minSize)
            p.y = min(p.y, fixed.y - minSize)
            return CGRect(x: p.x, y: p.y, width: fixed.x - p.x, height: fixed.y - p.y)
        case .topRight:
            p.x = max(p.x, fixed.x + minSize)
            p.y = min(p.y, fixed.y - minSize)
            return CGRect(x: fixed.x, y: p.y, width: p.x - fixed.x, height: fixed.y - p.y)
        case .bottomLeft:
            p.x = min(p.x, fixed.x - minSize)
            p.y = max(p.y, fixed.y + minSize)
            return CGRect(x: p.x, y: fixed.y, width: fixed.x - p.x, height: p.y - fixed.y)
        case .bottomRight:
            p.x = max(p.x, fixed.x + minSize)
            p.y = max(p.y, fixed.y + minSize)
            return CGRect(x: fixed.x, y: fixed.y, width: p.x - fixed.x, height: p.y - fixed.y)
        }
    }
}

// MARK: - Corner

private enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var alignment: Alignment {
        switch self {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }

    func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    /// 대각 반대 모서리 좌표 — 리사이즈 시 고정점.
    func opposite(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.maxX, y: rect.maxY)
        case .topRight: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomRight: CGPoint(x: rect.minX, y: rect.minY)
        }
    }

    /// L 핸들 박스(arm×arm)의 중심 — elbow 가 rect 코너에서 `overhang` 만큼 **바깥으로** 나가
    /// 모서리를 감싸도록(애플 사진 크롭처럼 끝에 딱). 두 팔은 거기서 안쪽(각 변 방향)으로 뻗는다.
    func handleCenter(in rect: CGRect, overhang: CGFloat, arm: CGFloat) -> CGPoint {
        let half = arm / 2
        switch self {
        case .topLeft:
            return CGPoint(x: rect.minX - overhang + half, y: rect.minY - overhang + half)
        case .topRight:
            return CGPoint(x: rect.maxX + overhang - half, y: rect.minY - overhang + half)
        case .bottomLeft:
            return CGPoint(x: rect.minX - overhang + half, y: rect.maxY + overhang - half)
        case .bottomRight:
            return CGPoint(x: rect.maxX + overhang - half, y: rect.maxY + overhang - half)
        }
    }
}

// MARK: - Rule-of-thirds grid

private struct CropGrid: View {
    let rect: CGRect

    var body: some View {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
        .stroke(Color.white.opacity(0.4), lineWidth: 0.75)
        .allowsHitTesting(false)
    }
}
