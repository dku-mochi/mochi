import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// 카테고리 턴테이블 — 한 서랍의 기억 커버들이 누운 원판(LP 턴테이블)을 따라 3D 로 돌고,
/// 앞쪽 커버가 초점이 된다. 시안 `docs/home-carousel-prototype.html` 의 "scroll-velocity 3D planes"
/// 인터랙션을 SwiftUI 로 옮긴 것.
///
/// 모션 설계:
///  - 커버 위치는 연속값 `rotation`(카드 단위)에서 매 프레임 계산한다 — 각 커버에 붙인
///    ``CoverTransform3D`` 가 `Animatable` 이라, `withAnimation` 으로 `rotation` 을 바꾸면 SwiftUI 가
///    프레임마다 보간해 커버들이 함께 흐른다(별도 타이머 루프 없이 관성·스냅 표현).
///  - 드래그 중엔 `rotation` 을 직접 따라가게 하고(즉시), 놓으면 `predictedEndTranslation` 으로 관성을
///    실어 가장 가까운 커버로 `interpolatingSpring` 스냅한다(motion.dev 스타일).
public struct CategoryCarouselView: View {
    @Bindable var store: StoreOf<CategoryCarouselFeature>
    @Environment(\.dismiss) private var dismiss

    /// 연속 회전값(카드 단위). 정수면 그 인덱스 커버가 정면.
    @State private var rotation: Double = 0
    /// 드래그 시작 시점의 `rotation` 스냅샷 — 드래그 누적 이동을 절대값으로 환산.
    @State private var dragStart: Double?
    /// 하단 정보 패널이 가리키는 초점 커버.
    @State private var focalIndex: Int = 0

    public init(store: StoreOf<CategoryCarouselFeature>) {
        self.store = store
    }

    /// 드래그 1pt 당 회전(카드 단위) — 한 커버 넘기는 데 ~150pt. 조금만 굴려도 다음으로 넘어가는 느낌.
    private let sensitivity = 0.0066

    private var items: [MochiItem] { store.bucket.items }
    private var count: Int { items.count }
    private var tint: (soft: Color, strong: Color) { MochiCategoryPalette.tint(store.bucket.tintIndex) }
    private var categoryIcon: String {
        MochiCategoryIcon.icon(for: store.bucket.name, fallbackIndex: store.bucket.tintIndex)
    }
    private var focalItem: MochiItem? {
        guard items.indices.contains(focalIndex) else { return items.first }
        return items[focalIndex]
    }

    public var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                header
                stage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                focalPanel
            }
        }
        // 시스템 nav bar 를 숨기고 헤더 안에 커스텀 원형 back 버튼을 둔다(타이틀과 인라인 정렬, 시안 톤).
        // pop 은 TCA NavigationStack 과 연동된 SwiftUI dismiss 로, 가장자리 스와이프-백은 네이티브 pop
        // 제스처를 되살려(`interactiveSwipeBackEnabled`) 그대로 쓴다.
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveSwipeBackEnabled()
        .preferredColorScheme(.light)
        // 커버가 초점에 들어올 때마다 피커 휠식 선택 햅틱 — 촉각으로 "딱 맞춰졌다".
        .sensoryFeedback(.selection, trigger: focalIndex)
        // 진입 시 rotation·focalIndex 기본값(0)이라 첫 커버가 곧장 초점으로 정지해 있다(인트로 롤 없음 —
        // 이전엔 -0.85→0 으로 굴려 "마지막→첫" 스크롤이 보였다). onAppear 로 리셋하지 않아 상세를 보고
        // 돌아와도 보던 커버 위치가 그대로 보존된다.
    }

    // MARK: - 배경 (bg + 하단 카테고리 틴트 글로우)

    private var background: some View {
        ZStack {
            HomeDesign.Color.bg
            // 초점 카테고리 색이 무대 아래에서 은은히 번진다.
            RadialGradient(
                colors: [tint.soft.opacity(0.9), tint.soft.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.72),
                startRadius: 8,
                endRadius: 380
            )
            // 시네마틱 비네트 — 가장자리를 살짝 눌러 무대 중앙으로 시선을 모은다.
            RadialGradient(
                colors: [Color.clear, HomeDesign.Color.ink900.opacity(0.08)],
                center: .center,
                startRadius: 140,
                endRadius: 540
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 헤더 (카테고리 점 + 이름 + 개수)

    private var header: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            backButton
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    Circle()
                        .fill(tint.strong)
                        .frame(width: 9, height: 9)
                    Text(store.bucket.name)
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text("\(store.bucket.count)개의 기억 · 돌려서 골라보기")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: HomeDesign.Spacing.sm)
            positionIndicator
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.xs)
    }

    /// 커스텀 원형 back 버튼 — 기록 상세 toolbar 버튼과 같은 칩(`CircularGlyph`, DesignSystem 단일 소스).
    private var backButton: some View {
        Button { dismiss() } label: {
            CircularGlyph("chevron.left")
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("뒤로")
    }

    /// 지금 몇 번째 커버인지 — 상단 우측 pill. 회전에 따라 숫자가 굴러 바뀐다.
    private var positionIndicator: some View {
        HStack(spacing: 3) {
            Text("\(min(focalIndex + 1, count))")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(tint.strong)
                .contentTransition(.numericText())
            Text("/ \(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, 7)
        .background(Capsule().fill(HomeDesign.Color.surface))
        .overlay(Capsule().stroke(HomeDesign.Color.border, lineWidth: 1))
        .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 6, x: 0, y: 2)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: focalIndex)
        .accessibilityLabel("\(count)개 중 \(min(focalIndex + 1, count))번째")
    }

    // MARK: - 무대 (커버들이 도는 곳)

    private var stage: some View {
        GeometryReader { proxy in
            let metrics = StageMetrics(size: proxy.size)
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    TurntableCover(
                        item: item,
                        categoryIcon: categoryIcon,
                        tint: tint,
                        size: CGSize(width: metrics.cardWidth, height: metrics.cardHeight),
                        isFocal: index == focalIndex
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    // 탭은 modifier 안쪽에 둬, CoverTransform3D 의 allowsHitTesting(비초점 차단)이 먼저 걸리게 한다
                    // (바깥에 두면 비초점 커버도 탭돼버린다). 탭하면 초점 커버 frame 에서 상세로 hero 확대.
                    .onTapGesture {
                        store.send(.openItemTapped(
                            item.id,
                            hero: heroFrames(for: item, index: index, metrics: metrics, stageFrame: proxy.frame(in: .global))
                        ))
                    }
                    .modifier(CoverTransform3D(rotation: rotation, index: index, count: count, metrics: metrics))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            // 무대를 클리핑하지 않는다 — 멀어지는 커버는 opacity·블러·헤이즈로 이미 자연히 사라지고,
            // 클리핑(`.mask`/`.clipped`)을 걸면 초점 카드의 그림자까지 잘린다(그림자 잘림 버그 원인).
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard count > 1 else { return }
                let start = dragStart ?? rotation
                dragStart = start
                rotation = start - Double(value.translation.width) * sensitivity
                focalIndex = Self.wrappedIndex(rotation, count)
            }
            .onEnded { value in
                guard count > 1 else { dragStart = nil; return }
                let start = dragStart ?? rotation
                dragStart = nil
                // 놓는 순간 속도(예측 이동)로 관성을 싣되, 멀리 날아가지 않게 현재에서 최대 ±2.4 커버로
                // 클램프해 가까운 커버에 단단히 스냅한다("더 가까운 커버스냅").
                let predicted = start - Double(value.predictedEndTranslation.width) * sensitivity
                let clamped = min(max(predicted, rotation - 2.4), rotation + 2.4)
                let target = clamped.rounded()
                focalIndex = Self.wrappedIndex(target, count)
                withAnimation(.interpolatingSpring(stiffness: 130, damping: 18)) {
                    rotation = target
                }
            }
    }

    // MARK: - 하단 초점 정보 + 액션

    private var focalPanel: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            if let item = focalItem {
                Text(item.relativeCapturedLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)

                Text(item.displayTitle)
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46, alignment: .top)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HomeDesign.Spacing.xl)
        .padding(.top, HomeDesign.Spacing.sm)
        .padding(.bottom, HomeDesign.Spacing.lg)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: focalIndex)
    }

    /// 초점 커버의 글로벌 frame 으로 hero 묶음을 만든다 — 그 커버에서 상세로 확대되는 시작점.
    /// 커버는 회전 변환(scale/offset)을 입으므로 레이아웃 frame 대신 무대 frame + 배치 계산으로 구한다.
    /// 스크린샷이면 cardImage(= 커버 전체, 자켓이 이미지를 꽉 채움) + 원본 경로를 실어 이미지가 비행한다.
    private func heroFrames(for item: MochiItem, index: Int, metrics: StageMetrics, stageFrame: CGRect) -> HeroSourceFrames? {
        guard stageFrame.width > 0 else { return nil }
        let placement = metrics.placement(index: index, rotation: rotation, count: count)
        let width = metrics.cardWidth * placement.scale
        let height = metrics.cardHeight * placement.scale
        let rect = CGRect(
            x: stageFrame.midX + placement.dx - width / 2,
            y: stageFrame.midY + placement.dy - height / 2,
            width: width,
            height: height
        )
        let ref = item.source.imageRefs.first
        return HeroSourceFrames(
            card: rect,
            cardImage: ref != nil ? rect : nil,
            imageRelativePath: ref?.displayRelativePath
        )
    }

    /// `rotation`(카드 단위)에 가장 가까운 커버 인덱스를 [0, count) 로 감싼다.
    static func wrappedIndex(_ rotation: Double, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rounded = Int(rotation.rounded())
        return ((rounded % count) + count) % count
    }
}

// MARK: - 커버 1장 (CD 자켓 풍 추상 커버)

/// 한 기억을 표현하는 커버. **스크린샷이면 실제 캡처 이미지**(`LocalThumbnail` — App Group 컨테이너
/// 로드 + GCS 폴백 + 다운샘플, 세로=top fill / 가로=fit+blur)를 자켓으로 깔고, 이미지가 없는
/// 메모·URL 은 카테고리 색 그라데이션 + 아이콘으로 폴백한다. 위에 출처 태그·제목 캡션을 얹는다.
private struct TurntableCover: View {
    let item: MochiItem
    let categoryIcon: String
    let tint: (soft: Color, strong: Color)
    let size: CGSize
    let isFocal: Bool

    private var imageRef: ImageRef? { item.source.imageRefs.first }

    var body: some View {
        ZStack {
            // 자켓 — 실제 캡처 이미지(있으면) / 그라데이션 폴백.
            if let ref = imageRef {
                // center fill — 홈 카드·hero 비행(`scaleAspectFill`)·상세 헤더와 같은 크롭이라, 탭/복귀 hero
                // 전환에서 같은 영역이 보여 이미지가 튀지 않는다(이전 `.top` 은 위쪽만 보여 복귀 시 어긋났다).
                LocalThumbnail(
                    relativePath: ref.displayRelativePath,
                    objectKey: ref.objectKey,
                    sha256: ref.sha256,
                    mimeType: ref.mimeType,
                    targetSize: size,
                    alignment: .center
                ) {
                    gradientArt
                }
            } else {
                gradientArt
            }

            // 출처(스크린샷/메모/URL) 태그 — 좌상단.
            VStack {
                HStack {
                    Image(systemName: item.viewKind.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint.strong)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.88)))
                        .shadow(color: HomeDesign.Color.ink900.opacity(0.12), radius: 3, x: 0, y: 1)
                    Spacer()
                }
                Spacer()
            }
            .padding(10)

            // 제목 캡션 — 하단, 어둡게 깔고 흰 글자.
            VStack {
                Spacer()
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11)
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                    .background(
                        LinearGradient(
                            colors: [Color.black.opacity(0), Color.black.opacity(0.68)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // 유리 광택 — 좌상단에서 떨어지는 미세 하이라이트(softLight 라 이미지·그라데이션 위에서 자연스럽다).
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                )
                .blendMode(.softLight)
                .allowsHitTesting(false)
        )
        // 유리 엣지 — 컬러 테두리(선택 UI 같던) 대신 얇은 흰 hairline. 초점은 크기·선명도·그림자로 구분.
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(isFocal ? 0.7 : 0.42), lineWidth: isFocal ? 1.2 : 0.8)
        )
    }

    /// 이미지가 없는 기억(메모·URL)·로드 대기 중에 쓰는 자켓 — 깊은 카테고리 그라데이션 위에
    /// 블러 오브로 메시 느낌의 깊이를 주고, 프로스티드 글래스 원 안에 카테고리 글리프를 얹는다.
    private var gradientArt: some View {
        ZStack {
            // 1. 깊은 카테고리 대각선 그라데이션.
            LinearGradient(
                colors: [tint.strong, tint.strong.opacity(0.78), tint.soft],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // 2. 떠 있는 블러 오브 — 메시 그라데이션 같은 빛 깊이.
            Circle()
                .fill(Color.white.opacity(0.32))
                .frame(width: size.width * 1.0)
                .blur(radius: 36)
                .offset(x: -size.width * 0.30, y: -size.height * 0.24)
            Circle()
                .fill(tint.strong.opacity(0.6))
                .frame(width: size.width * 0.9)
                .blur(radius: 44)
                .offset(x: size.width * 0.34, y: size.height * 0.30)
            // 3. 상단 광택.
            LinearGradient(
                colors: [Color.white.opacity(0.24), Color.white.opacity(0)],
                startPoint: .top,
                endPoint: .center
            )
            // 4. 프로스티드 글래스 원 + 글리프 (캡션 자리를 피해 살짝 위로).
            Image(systemName: categoryIcon)
                .font(.system(size: size.width * 0.24, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: HomeDesign.Color.ink900.opacity(0.18), radius: 6, x: 0, y: 3)
                .frame(width: size.width * 0.44, height: size.width * 0.44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.4), lineWidth: 1))
                .shadow(color: tint.strong.opacity(0.45), radius: 16, x: 0, y: 10)
                .offset(y: -size.height * 0.07)
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - 3D 배치 (Animatable — rotation 보간 시 매 프레임 재배치)

/// 무대 좌표·상수. 시안 프로토타입의 STEP/ANGLE/PERSPECTIVE 를 옮기되, 화면폭에 따라 평면 오프셋만
/// 비례시킨다(깊이감 f 는 z/perspective 비율이라 화면폭과 무관하게 유지).
private struct StageMetrics: Equatable {
    let size: CGSize

    private var scaleFactor: CGFloat { max(size.width / 390, 0.82) }
    // 폰 스크린샷 비율(≈0.53) — 세로 캡처가 거의 안 잘리고 자연스럽게 채워진다.
    // 하단 버튼·카운터를 걷어낸 만큼 이미지 영역을 키우되, 무대 높이의 60% 로 상한을 둬
    // 작은 화면(SE 등)에서 초점 카드가 무대를 넘쳐 잘리지 않게 한다.
    var cardHeight: CGFloat { min(330 * scaleFactor, size.height * 0.6) }
    var cardWidth: CGFloat { cardHeight * 0.53 }

    // 커버 간격·깊이. 간격을 좁혀(STEP_X↓) 이웃 커버가 더 가깝게 붙어 보이게 한다.
    private let stepX: CGFloat = 98
    private let stepY: CGFloat = -34
    private let stepZ: CGFloat = -128
    private let angle: Double = -50
    private let baseX: CGFloat = 4
    private let baseY: CGFloat = 8
    private let popZ: CGFloat = 30
    private let focalScale: CGFloat = 1.28
    private let perspective: CGFloat = 1000

    func placement(index: Int, rotation: Double, count: Int) -> CoverPlacement {
        guard count > 0 else {
            return CoverPlacement(
                dx: 0, dy: 0, scale: 1, rotationY: 0, opacity: 1, zIndex: 1, isFocal: true,
                blur: 0, dim: 0, shadowRadius: 30, shadowOpacity: 0.4, shadowY: 18
            )
        }
        let countD = Double(count)
        // 오프셋 wrap. 커버가 4장 이상이면 backRoom 1.5 로 "직전 커버"를 초점 왼쪽에 약간 남겨(coverflow
        // 처럼 지나간 것도 보이게), 3장 이하면 backRoom 1.0 으로 전부 전방에 둬 다 또렷이 보이게 한다
        // (소수 카테고리에서 비초점 커버가 사라지지 않게).
        let backRoom: Double = count >= 4 ? 1.5 : 1.0
        var n = (Double(index) - rotation).truncatingRemainder(dividingBy: countD)
        if n > countD - backRoom { n -= countD }
        if n <= -backRoom { n += countD }

        let ad = abs(n)
        let centered = 1 - min(1, ad)
        let visible = n >= -1.5 && n <= 6.0

        let lx = baseX + CGFloat(n) * stepX
        let ly = baseY + CGFloat(n) * stepY
        let lz = CGFloat(n) * stepZ + popZ * CGFloat(centered)
        // 초점과 "바로 이웃"(거리 1 이내)은 0°(정면 유지) — 활성 카드가 명확한 메인이고, 직전/직후
        // 커버가 미리 회전하는 것처럼 보이지 않게 한다. 거리 1 을 넘어 멀어지는 커버만 점진적으로 기운다.
        let rotationY = angle * min(1, max(0, (ad - 1) / 1.5))
        let localScale = 1 + (focalScale - 1) * CGFloat(centered)

        let f = perspective / (perspective - lz)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let vanish = CGPoint(x: size.width * 0.17, y: size.height * 0.22)
        let preX = center.x + lx * scaleFactor
        let preY = center.y + ly * scaleFactor
        let projX = vanish.x + (preX - vanish.x) * f
        let projY = vanish.y + (preY - vanish.y) * f

        var opacity = 1.0
        // 지나간(음수) 커버는 천천히 페이드 — n=-1.5 에서 0, n=-1 에서 ~0.33 로 "약간 보이게" 남긴다.
        if n < 0 { opacity = max(0, 1 + n / 1.5) }
        else if n > 4 { opacity = max(0, 1 - (n - 4) / 2) }
        if !visible { opacity = 0 }

        let isFocal = index == CategoryCarouselView.wrappedIndex(rotation, count)
        let zIndex = isFocal ? 5000.0 : 2000.0 + Double(lz)

        // 시네마틱 깊이 — 초점에서 멀수록 흐려지고(피사계심도) 어둑해진다(공기원근),
        // 초점은 크고 부드러운 그림자로 떠오른다(elevation, centered 에 연동).
        let blur = min(5.0, max(0, ad - 0.55) * 2.5)
        let dim = min(0.32, max(0, ad - 0.4) * 0.17)
        let shadowRadius = 12 + 26 * CGFloat(centered)
        let shadowOpacity = 0.16 + 0.26 * Double(centered)
        let shadowY = 7 + 13 * CGFloat(centered)

        return CoverPlacement(
            dx: projX - center.x,
            dy: projY - center.y,
            scale: f * localScale,
            rotationY: rotationY,
            opacity: opacity,
            zIndex: zIndex,
            isFocal: isFocal,
            blur: blur,
            dim: dim,
            shadowRadius: shadowRadius,
            shadowOpacity: shadowOpacity,
            shadowY: shadowY
        )
    }
}

private struct CoverPlacement {
    let dx: CGFloat
    let dy: CGFloat
    let scale: CGFloat
    let rotationY: Double
    let opacity: Double
    let zIndex: Double
    let isFocal: Bool
    let blur: CGFloat
    let dim: Double
    let shadowRadius: CGFloat
    let shadowOpacity: Double
    let shadowY: CGFloat
}

/// 한 커버의 3D 변환. `animatableData == rotation` 이라, 공유 `rotation` 을 `withAnimation` 으로 바꾸면
/// SwiftUI 가 프레임마다 이 모디파이어를 다시 계산해 커버가 부드럽게 흐른다(관성·스냅의 실제 구현부).
private struct CoverTransform3D: ViewModifier, Animatable {
    var rotation: Double
    let index: Int
    let count: Int
    let metrics: StageMetrics

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func body(content: Content) -> some View {
        let p = metrics.placement(index: index, rotation: rotation, count: count)
        return content
            // 공기원근 — 멀어지는 커버는 살짝 어둑하게 (초점은 dim 0 으로 또렷).
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.black.opacity(p.dim))
            )
            // elevation — 초점이 떠오르며 크고 부드러운 그림자.
            .shadow(color: HomeDesign.Color.ink900.opacity(p.shadowOpacity), radius: p.shadowRadius, x: 0, y: p.shadowY)
            // 피사계심도 — 초점에서 멀수록 부드럽게 흐려져 시선이 활성 카드에 집중된다.
            .blur(radius: p.blur)
            .rotation3DEffect(.degrees(p.rotationY), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.42)
            .scaleEffect(p.scale)
            .offset(x: p.dx, y: p.dy)
            .opacity(p.opacity)
            .zIndex(p.zIndex)
            .allowsHitTesting(p.isFocal && p.opacity > 0.5)
    }
}
