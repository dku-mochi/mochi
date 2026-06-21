import CoreDomain
import CorePrivacy
import DesignSystem
import SwiftUI

/// 민감 캡처 감지 시 저장 방법을 고르고, **가릴 영역을 직접 손보는** 시트.
///
/// "민감한 곳 가리고 저장"을 고르면 미리보기가 인터랙티브 에디터가 된다. 기본은 **감지된 민감 영역만
/// 이미 가려진** 깨끗한 스크린샷 — 나머지엔 아무 표식도 없다(키보드·특수문자까지 박스로 덮어 어지럽던
/// 문제 제거). 더 가리고 싶으면 글자를 **탭하거나 손가락으로 쓸어서**(Apple Markup 식) 그 줄만 가린다.
/// 감지 유형은 하단 라벨 칩으로도 토글한다. 강제하지 않고 사용자가 고른다. 감지된 원문은 절대 노출하지
/// 않고 유형 칩만 보여준다.
///
/// **레이아웃**: 스크롤이 없다 — 에디터가 가변 높이 hero 로 남는 공간을 채우고, 옵션·CTA 는
/// `safeAreaInset` 으로 항상 화면에 고정된다(숨은 스크롤을 사용자가 모르던 문제를 "스크롤 자체를
/// 없애" 해소; 하단 페이드 같은 힌트 안 씀).
///
/// **디자인**: ShareExtension 의 라벤더 세계(``ShareDesign``)에 흡수돼 입력 화면에서 톤이 끊기지
/// 않는다 — 배경 그라데이션·CTA(``SharePrimaryButton``)·등장 안무 공유. "민감 감지"는 고유 주의
/// 상태라 라벤더와 대비되는 호박 액센트(``ShareDesign/caution``)를 입힌다. 가린 영역은 라벤더
/// (``ShareDesign/primary``). 레이아웃 토큰(``HomeDesign/Spacing``·``HomeDesign/Radius``)은 팔레트
/// 중립이라 그대로 쓴다.
struct PrivacyChoiceView: View {
    let assessment: SensitivityAssessment
    let originalImage: UIImage
    /// 자동 감지된(라벨 달린) 가림 후보.
    let detectedRegions: [RedactionRegion]
    /// OCR 로 인식된 모든 텍스트 줄 영역(정규화) — 사용자가 직접 추가로 가릴 수 있는 후보.
    let textBoxes: [CGRect]
    /// 선택 정책 + 사용자가 켜둔(가릴) 영역. 블러 정책이면 이 영역만 블러본을 생성한다.
    let onChoose: (PrivacyPolicy, [RedactionRegion]) -> Void
    let onCancel: () -> Void
    /// 확정 CTA 라벨 — nil 이면 정책별 기본(`meta.cta`). 선감지(저장 전 적용)에선 "이대로 적용하기".
    let confirmTitle: String?
    /// 취소 라벨 — 기본 "저장하지 않기". 선감지에선 "가리지 않고 둘게요".
    let cancelTitle: String

    @State private var selected: PrivacyPolicy
    /// 가림이 켜진 영역 id. 기본은 자동 감지 영역 전부(안전).
    @State private var enabled: Set<UUID>
    @State private var appeared = false
    /// 칩 탭으로 토글할 때 이미지 위 해당 영역을 잠깐 강조.
    @State private var flashID: UUID?

    /// 자동 감지엔 안 걸린 일반 텍스트 줄(수동 가림 후보, 미렌더 — 탭·쓸기 히트테스트에만 쓴다).
    private let manualCandidates: [RedactionRegion]

    init(
        assessment: SensitivityAssessment,
        originalImage: UIImage,
        detectedRegions: [RedactionRegion],
        textBoxes: [CGRect],
        confirmTitle: String? = nil,
        cancelTitle: String = "저장하지 않기",
        onChoose: @escaping (PrivacyPolicy, [RedactionRegion]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.assessment = assessment
        self.originalImage = originalImage
        self.detectedRegions = detectedRegions
        self.textBoxes = textBoxes
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.onChoose = onChoose
        self.onCancel = onCancel

        let detectedRects = Set(detectedRegions.map(\.rect))
        self.manualCandidates = textBoxes
            .filter { !detectedRects.contains($0) }
            .map { RedactionRegion(rect: $0, types: []) }

        let recommended = assessment.recommendedPolicy
        _selected = State(initialValue: (recommended == .blurredUpload && detectedRegions.isEmpty) ? .originalUpload : recommended)
        _enabled = State(initialValue: Set(detectedRegions.map(\.id)))
    }

    /// 탭·쓸기 히트테스트 + 블러 마스크 대상이 되는 모든 OCR 줄(감지 + 수동).
    private var allRegions: [RedactionRegion] { detectedRegions + manualCandidates }
    private var enabledRegions: [RedactionRegion] { allRegions.filter { enabled.contains($0.id) } }
    private var isBlur: Bool { selected == .blurredUpload }
    private var hasManual: Bool { !manualCandidates.isEmpty }
    private var options: [PrivacyPolicy] {
        detectedRegions.isEmpty ? [.originalUpload, .localOnly] : [.blurredUpload, .originalUpload, .localOnly]
    }
    private var allDetectedOn: Bool {
        !detectedRegions.isEmpty && detectedRegions.allSatisfy { enabled.contains($0.id) }
    }

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient.ignoresSafeArea()
            VStack(spacing: HomeDesign.Spacing.lg) {
                header.shareEntrance(0, appeared: appeared)
                editorArea.shareEntrance(1, appeared: appeared)
                if isBlur, !detectedRegions.isEmpty {
                    detectedChips.shareEntrance(2, appeared: appeared)
                }
                optionSelector.shareEntrance(3, appeared: appeared)
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.top, HomeDesign.Spacing.lg)
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .onAppear { appeared = true }
    }

    // MARK: - Header (compact)

    private var header: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(ShareDesign.cautionSoft)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(ShareDesign.caution)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text("민감한 정보가 있어요")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(ShareDesign.title)
                Text(isBlur ? "가릴 곳을 탭하거나 쓸어서 고르세요" : "이 화면을 어떻게 저장할지 골라주세요")
                    .font(.subheadline)
                    .foregroundStyle(ShareDesign.muted)
                    .animation(.easeInOut(duration: 0.2), value: isBlur)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 에디터 / 미리보기 (가변 높이 hero)

    private var editorArea: some View {
        // 카드 스타일은 flex 프레임이 아니라 **이미지에 hug** 시키고, ZStack 으로 남는 공간 중앙에 둔다
        // (큰 빈 카드 안에 작은 이미지가 떠 보이지 않게).
        ZStack {
            Group {
                if isBlur {
                    RedactionImageEditor(
                        image: originalImage,
                        regions: allRegions,
                        enabled: enabled,
                        flashID: flashID,
                        onToggle: { toggle($0, flash: false) },
                        onPaint: paint
                    )
                } else {
                    Image(uiImage: originalImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if selected == .localOnly {
                    // 어두운 캡슐(`snackbarFill`)에 흰 텍스트 — 양 모드 모두 대비 유지.
                    badge(icon: "iphone", text: "기기에만", tint: ShareDesign.snackbarFill)
                        .padding(HomeDesign.Spacing.md)
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .strokeBorder(ShareDesign.cardStroke, lineWidth: 1)
            }
            .cardShadow()
            .animation(.easeInOut(duration: 0.25), value: selected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func badge(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: HomeDesign.Spacing.xs) {
            Image(systemName: icon).font(.caption2.weight(.bold))
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, HomeDesign.Spacing.xs + 1)
        .background(Capsule().fill(tint))
    }

    // MARK: - 감지 라벨 칩 (탭으로 토글) + 일괄 컨트롤

    private var detectedChips: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                Button(action: toggleAll) {
                    Text(allDetectedOn ? "모두 보이기" : "모두 가리기")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ShareDesign.primary)
                        .padding(.horizontal, HomeDesign.Spacing.sm + 2)
                        .padding(.vertical, HomeDesign.Spacing.xs + 1)
                        .background(Capsule().fill(ShareDesign.primary.opacity(0.10)))
                }
                .buttonStyle(PressableStyle())

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HomeDesign.Spacing.sm) {
                        ForEach(detectedRegions) { region in
                            regionChip(region)
                        }
                    }
                }
            }
        }
    }

    /// 유형 라벨 칩 — 탭하면 해당 영역 가림을 토글하고 이미지에서 잠깐 강조. "라벨로 가리기" 의 명시적 surface.
    private func regionChip(_ region: RedactionRegion) -> some View {
        let isOn = enabled.contains(region.id)
        let tint = isOn ? ShareDesign.primary : ShareDesign.caution
        return Button {
            toggle(region.id, flash: true)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text(region.primaryType?.chipLabel ?? "텍스트")
                    .font(.footnote.weight(.medium))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, HomeDesign.Spacing.sm + 2)
            .padding(.vertical, HomeDesign.Spacing.xs + 2)
            .background(Capsule().fill(isOn ? ShareDesign.primary.opacity(0.12) : ShareDesign.cautionSoft))
            .overlay(Capsule().strokeBorder(isOn ? ShareDesign.primary.opacity(0.35) : .clear, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - 정책 선택 (항상 보이는 고정 카드)

    private var optionSelector: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            ForEach(options, id: \.self) { policy in
                optionRow(policy)
            }
        }
    }

    private func optionRow(_ policy: PrivacyPolicy) -> some View {
        let meta = Self.meta(for: policy)
        let isSelected = selected == policy
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selected = policy }
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(isSelected ? ShareDesign.primary : ShareDesign.primary.opacity(0.10))
                    Image(systemName: meta.icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : ShareDesign.subtitle)
                }
                .frame(width: 34, height: 34)

                HStack(spacing: HomeDesign.Spacing.xs) {
                    Text(policy == .blurredUpload && isSelected ? blurTitle : meta.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ShareDesign.title)
                    if policy == .blurredUpload {
                        Text("추천")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(ShareDesign.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(ShareDesign.primary.opacity(0.12)))
                    }
                }

                Spacer(minLength: HomeDesign.Spacing.sm)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19))
                    .foregroundStyle(isSelected ? ShareDesign.primary : ShareDesign.muted.opacity(0.5))
            }
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, HomeDesign.Spacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(ShareDesign.cardSolid)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .strokeBorder(isSelected ? ShareDesign.primary : ShareDesign.cardStroke,
                                  lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(PressableStyle())
    }

    /// 블러 선택 시 제목에 켠 영역 개수를 실시간 반영.
    private var blurTitle: String {
        let count = enabledRegions.count
        return count == 0 ? "가릴 곳을 골라주세요" : "민감한 곳 \(count)곳 가리고 저장"
    }

    // MARK: - 하단 고정 바 (CTA)

    private var bottomBar: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            SharePrimaryButton(title: confirmTitle ?? Self.meta(for: selected).cta, icon: Self.meta(for: selected).icon) {
                onChoose(selected, enabledRegions)
            }
            Button(action: onCancel) {
                Text(cancelTitle)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ShareDesign.subtitle)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HomeDesign.Spacing.xs)
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.sm)
    }

    // MARK: - 토글 로직

    private func toggle(_ id: UUID, flash: Bool) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if enabled.contains(id) { enabled.remove(id) } else { enabled.insert(id) }
        }
        ShareHaptics.selection()
        guard flash else { return }
        flashID = id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if flashID == id { flashID = nil }
        }
    }

    /// 쓸기(drag)·페인트 — 더하기만(끄려면 탭). 새 줄이 가려질 때만 가벼운 햅틱.
    private func paint(_ id: UUID) {
        guard !enabled.contains(id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { _ = enabled.insert(id) }
        ShareHaptics.selection()
    }

    private func toggleAll() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            if allDetectedOn {
                enabled.removeAll()
            } else {
                for region in detectedRegions { enabled.insert(region.id) }
            }
        }
        ShareHaptics.selection()
    }

    // MARK: - 옵션 메타

    private static func meta(for policy: PrivacyPolicy) -> (icon: String, title: String, subtitle: String, cta: String) {
        switch policy {
        case .blurredUpload:
            return ("eye.slash.fill", "민감한 곳 가리고 저장", "감지된 부분만 흐리게 처리해서 올려요", "가리고 저장하기")
        case .originalUpload:
            return ("photo.fill", "원본 그대로 저장", "가리지 않고 그대로 올려요", "원본 그대로 저장")
        case .localOnly:
            return ("iphone", "이 기기에만 저장", "서버에 올리지 않고 폰에만 보관해요", "기기에만 저장하기")
        }
    }
}

// MARK: - 인터랙티브 가림 에디터

/// 원본 이미지 위에 가림을 탭/쓸기로 칠하는 라이브 에디터.
///
/// 기본은 감지 영역만 가려진 깨끗한 화면 — OCR 줄을 박스로 미리 그리지 않는다(클러터 제거). 가린
/// 영역만 얇은 라벤더 테두리로 "여기 손댈 수 있어요" 를 알리고, 그 위에 같은 이미지의 블러 복제본을
/// 마스크로 드러내 즉시(GPU) 흐리게 보여준다. **탭** = 그 줄 가림 토글, **쓸기** = 지나간 줄들 가리기
/// (더하기). 실제 업로드본은 확정 시 강한 가우시안 블러로 따로 굽는다. 좌표는 Vision 정규화(원점
/// 좌하단)를 뷰 좌표(원점 좌상단)로 뒤집어 매핑한다.
private struct RedactionImageEditor: View {
    let image: UIImage
    /// 모든 OCR 줄(감지 + 수동) — 히트테스트 + 블러 마스크 대상.
    let regions: [RedactionRegion]
    let enabled: Set<UUID>
    let flashID: UUID?
    let onToggle: (UUID) -> Void
    let onPaint: (UUID) -> Void

    var body: some View {
        let aspect = max(0.2, image.size.width / max(1, image.size.height))
        GeometryReader { geo in
            editor(in: geo.size)
        }
        .aspectRatio(aspect, contentMode: .fit)
    }

    private func editor(in size: CGSize) -> some View {
        ZStack {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()

            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .blur(radius: max(8, min(size.width, size.height) * 0.06), opaque: true)
                .mask(maskCanvas(in: size))
                .allowsHitTesting(false)

            ForEach(regions) { region in
                borderView(region, in: size)
            }
            .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            if let id = regionID(at: location, in: size) { onToggle(id) }
        }
        .gesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                .onChanged { value in
                    if let id = regionID(at: value.location, in: size) { onPaint(id) }
                }
        )
    }

    private func maskCanvas(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            for region in regions where enabled.contains(region.id) {
                let r = Self.viewRect(region.rect, in: size).insetBy(dx: -2, dy: -2)
                ctx.fill(Path(roundedRect: r, cornerRadius: 6), with: .color(.white))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// 가린 영역만 얇은 라벤더 테두리(탭으로 끌 수 있음을 암시). 감지됐지만 사용자가 연 영역은 호박
    /// 점선(다시 가릴 수 있음을 암시). 그 외 줄은 아무 표식 없음 — 화면을 깨끗이 유지한다.
    @ViewBuilder
    private func borderView(_ region: RedactionRegion, in size: CGSize) -> some View {
        let isOn = enabled.contains(region.id)
        let isDetected = !region.types.isEmpty
        if isOn || isDetected {
            let r = Self.viewRect(region.rect, in: size)
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isOn ? ShareDesign.primary.opacity(0.7) : ShareDesign.caution.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.5, dash: isOn ? [] : [4, 3])
                )
                .frame(width: r.width + 5, height: r.height + 5)
                .position(x: r.midX, y: r.midY)
                .scaleEffect(flashID == region.id ? 1.08 : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: flashID)
                .animation(.easeInOut(duration: 0.2), value: isOn)
        }
    }

    /// 탭/쓸기 지점(뷰 좌표) 아래의 OCR 줄을 찾는다 — 약간의 여유를 두고, 겹치면 가장 작은(구체적인) 것.
    private func regionID(at point: CGPoint, in size: CGSize) -> UUID? {
        guard size.width > 0, size.height > 0 else { return nil }
        let nx = point.x / size.width
        let ny = 1 - point.y / size.height
        let padX: CGFloat = 0.012, padY: CGFloat = 0.014
        return regions
            .filter { r in
                nx >= r.rect.minX - padX && nx <= r.rect.maxX + padX &&
                ny >= r.rect.minY - padY && ny <= r.rect.maxY + padY
            }
            .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })?
            .id
    }

    /// Vision 정규화(원점 좌하단, 0–1) → 뷰 좌표(원점 좌상단). 컨테이너가 이미지 비율로 잠겨 있어
    /// 레터박스 보정이 필요 없다(스케일 + y 뒤집기만).
    static func viewRect(_ n: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: n.minX * size.width,
            y: (1 - n.minY - n.height) * size.height,
            width: n.width * size.width,
            height: n.height * size.height
        )
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
