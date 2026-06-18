import SwiftUI
import CoreNetworking
import CoreDomain
import DesignSystem

/// 홈의 시각적 심장 — 사용자는 "찾으러" 들어오지만, 모찌가 잊고 있던 기억을 떠올려줘 "아, 맞다!"
/// 하게 만든다. 회상의 핵심은 **이미지**다 — 그때 그 화면을 다시 보면 즉시 기억난다.
///
/// 스크린샷 비율(세로 ~0.53)을 그대로 살린 **무한 가로 코버플로우**다 — 끝과 처음이 이어진다. 한 장이
/// 가운데에 서고 좌우 이웃이 살짝 작아져 비친다(평면 — 3D 회전 없이 절제). 텍스트는 제목 + "왜 지금"(reason) 한 줄로 덜어내,
/// 캡처 이미지가 카드의 주인공이 되게 한다. 이미지 없는 회수(메모·URL·순수 지식)만 reason 색 폴백.
struct RecallHeroView: View {
    let entries: [RecallFeedEntryDTO]
    /// 회수 itemID → 원본 캡처 이미지 ref. 있으면 카드 커버로 실제 캡처를 깐다(회상의 핵심).
    let images: [UUID: ImageRef]
    /// 덱(코버플로우) 높이 — 홈에서 상단을 가득 채우도록 화면 비례로 크게 준다.
    var deckHeight: CGFloat = 348
    /// 헤더 "모두 보기" → 자세히 목록.
    let onOpenAll: () -> Void
    /// 가운데 카드 탭 → 그 기록의 원본 상세로 직행. 카드 통째가 상세 헤더로 확대되는 hero zoom 의
    /// 출발 frame(`HeroSourceFrames`)을 함께 넘긴다 — 최근 카드와 같은 확대 전환.
    let onOpenFocal: (RecallFeedEntryDTO, HeroSourceFrames) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 연속 회전값(카드 단위). **무한** — clamp 없이 흐르고 wrap 돼 끝과 처음이 이어진다.
    @State private var rotation: Double = 0
    /// 드래그 시작 시점의 `rotation` 스냅샷 — 누적 이동을 절대값으로 환산.
    @State private var dragStart: Double?
    @State private var focalIndex: Int = 0
    @State private var appeared = false
    /// 초점 카드의 화면상 frame — 탭 시 hero zoom 의 출발점. 초점은 변환이 거의 identity(scale 1·offset 0)라
    /// `.global` 레이아웃 frame 이 실제 화면 위치와 일치한다(코버플로우 변환은 `.global` 에 반영 안 되지만 초점은 무변환).
    @State private var focalFrame: CGRect = .zero

    private var count: Int { entries.count }
    /// 드래그 1pt 당 회전(카드 단위) — 한 장 넘기는 데 ~120pt.
    private let sensitivity = 0.0082

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            header
            deck.frame(height: deckHeight)
            if count > 1 && count <= 7 { pageDots }
        }
        // 카드가 가운데에 들어올 때마다 선택 햅틱 — 촉각으로 "한 장 떠올랐다".
        .sensoryFeedback(.selection, trigger: focalIndex)
        .onAppear {
            focalIndex = Self.wrappedIndex(rotation, count)
            guard !appeared else { return }
            appeared = true
            // 첫 진입 — 카드가 한 칸 굴러 들어오며 자리를 잡는다.
            guard !reduceMotion, count > 1 else { return }
            rotation = -0.6
            withAnimation(.interpolatingSpring(stiffness: 60, damping: 12).delay(0.05)) {
                rotation = 0
            }
        }
    }

    // MARK: - 헤더 (절제 — 라벨 + 모두 보기)

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("모찌가 골라봤어요")
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Spacer(minLength: 0)
            Button(action: onOpenAll) {
                HStack(spacing: 2) {
                    Text("모두 보기")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(HomeDesign.Color.purple500)
            }
            .buttonStyle(PressableStyle())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("모찌가 고른 기록 \(count)개. 모두 보기")
    }

    // MARK: - 페이지 인디케이터 (덱 아래 가운데 — 적을 때만, 많으면 이웃 카드가 어포던스를 대신)

    private var pageDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i == focalIndex ? HomeDesign.Color.purple500 : HomeDesign.Color.purple200)
                    .frame(width: i == focalIndex ? 18 : 6, height: 6)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: focalIndex)
        .accessibilityHidden(true)
    }

    // MARK: - 무한 코버플로우 덱 (평면 — 끝과 처음이 이어진다)

    private var deck: some View {
        GeometryReader { proxy in
            let metrics = RecallCoverMetrics(size: proxy.size)
            ZStack {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    RecallCoverCard(entry: entry, imageRef: images[entry.itemID])
                        .frame(width: metrics.cardWidth, height: metrics.cardHeight)
                        // 초점 카드만 화면 frame 을 추적 — hero zoom 의 출발 좌표(변환 전 레이아웃 frame, 초점은 무변환).
                        .background {
                            if index == focalIndex {
                                GeometryReader { g in
                                    Color.clear
                                        .onAppear { focalFrame = g.frame(in: .global) }
                                        .onChange(of: g.frame(in: .global)) { _, f in focalFrame = f }
                                }
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .onTapGesture { openFocal(entry) }
                        .modifier(RecallCoverTransform(rotation: rotation, index: index, count: count, metrics: metrics))
                        // 목록에서 빠질 때(열어봐서 제거 등) 툭 끊기지 않고 작아지며 사라진다.
                        .transition(.scale(scale: 0.86).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            // 회수 항목이 더해지거나 빠질 때 부드럽게 재배치된다.
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: entries.map(\.id))
        }
    }

    private var dragGesture: some Gesture {
        // 수평 의도가 우세할 때만 — 홈 세로 스크롤에 양보한다.
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard count > 1 else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let start = dragStart ?? rotation
                dragStart = start
                // clamp 없음 — rotation 이 무한히 흐르고 wrap 으로 끝과 처음이 이어진다.
                rotation = start - Double(value.translation.width) * sensitivity
                focalIndex = Self.wrappedIndex(rotation, count)
            }
            .onEnded { value in
                guard count > 1, dragStart != nil else { dragStart = nil; return }
                let start = dragStart ?? rotation
                dragStart = nil
                // 관성(예측 이동)을 싣되 현재에서 최대 ±2.4 카드로 클램프해 가까운 카드에 스냅.
                let predicted = start - Double(value.predictedEndTranslation.width) * sensitivity
                let clamped = min(max(predicted, rotation - 2.4), rotation + 2.4)
                let target = clamped.rounded()
                focalIndex = Self.wrappedIndex(target, count)
                withAnimation(.interpolatingSpring(stiffness: 130, damping: 18)) {
                    rotation = target
                }
            }
    }

    /// 초점 카드 탭 — 그 카드 frame 에서 출발하는 hero zoom 으로 원본 상세를 연다.
    /// 회수 카드는 캡처가 카드 전체를 채우므로(풀블리드) `card == cardImage`. 이미지 없는 회수
    /// (메모·URL·지식)는 `cardImage == nil` → 상세가 중앙에서 fade-in(이미지 비행 없음).
    private func openFocal(_ entry: RecallFeedEntryDTO) {
        let imageRef = images[entry.itemID]
        let hero = HeroSourceFrames(
            card: focalFrame,
            cardImage: imageRef != nil ? focalFrame : nil,
            imageRelativePath: imageRef?.relativePath
        )
        onOpenFocal(entry, hero)
    }

    /// `rotation`(카드 단위)에 가장 가까운 커버 인덱스를 [0, count) 로 감싼다(무한 순환).
    static func wrappedIndex(_ rotation: Double, _ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let rounded = Int(rotation.rounded())
        return ((rounded % count) + count) % count
    }
}

// MARK: - 무한 평면 코버플로우 배치 (Animatable — rotation 보간 시 매 프레임 재배치)

private struct RecallCoverMetrics: Equatable {
    let size: CGSize

    /// 스크린샷 비율(세로 ~0.53) — 세로 캡처가 거의 안 잘린다. 덱 높이를 거의 다 쓰되,
    /// 폭은 가용 폭의 66% 로 상한을 둬 큰 덱에서도 좌우 이웃 카드가 비치게 한다.
    var cardHeight: CGFloat { size.height * 0.97 }
    var cardWidth: CGFloat { min(cardHeight * 0.53, size.width * 0.66) }
    private var stepX: CGFloat { cardWidth * 0.72 }

    func placement(index: Int, rotation: Double, count: Int) -> RecallCoverPlacement {
        guard count > 0 else {
            return RecallCoverPlacement(
                dx: 0, scale: 1, opacity: 1, zIndex: 1, isFocal: true,
                shadowRadius: 26, shadowOpacity: 0.2, shadowY: 16
            )
        }
        let countD = Double(count)
        // 무한 wrap — 오프셋을 [-count/2, count/2) 로 감싸 끝과 처음이 이어진다.
        var n = (Double(index) - rotation).truncatingRemainder(dividingBy: countD)
        if n > countD / 2 { n -= countD }
        if n <= -countD / 2 { n += countD }

        let ad = abs(n)
        let centered = max(0, 1 - ad)
        let dx = CGFloat(n) * stepX
        let scale = max(0.78, 1 - ad * 0.12)
        var opacity = 1.0
        if ad > 2.2 { opacity = max(0, 1 - (ad - 2.2) / 0.8) }
        if ad >= 3.0 { opacity = 0 }

        let isFocal = index == RecallHeroView.wrappedIndex(rotation, count)
        // 중앙이 최상, 멀수록 뒤로(겹친 덱).
        let zIndex = 1000 - Double(ad) * 10

        return RecallCoverPlacement(
            dx: dx,
            scale: scale,
            opacity: opacity,
            zIndex: zIndex,
            isFocal: isFocal,
            shadowRadius: 12 + 18 * centered,
            shadowOpacity: 0.12 + 0.16 * centered,
            shadowY: 7 + 11 * centered
        )
    }
}

private struct RecallCoverPlacement {
    let dx: CGFloat
    let scale: CGFloat
    let opacity: Double
    let zIndex: Double
    let isFocal: Bool
    let shadowRadius: CGFloat
    let shadowOpacity: Double
    let shadowY: CGFloat
}

/// 한 카드의 평면 변환. `animatableData == rotation` 이라, 공유 `rotation` 을 `withAnimation` 으로
/// 바꾸면 SwiftUI 가 프레임마다 다시 계산해 카드가 부드럽게 흐른다(관성·스냅·무한 순환의 구현부).
private struct RecallCoverTransform: ViewModifier, Animatable {
    var rotation: Double
    let index: Int
    let count: Int
    let metrics: RecallCoverMetrics

    var animatableData: Double {
        get { rotation }
        set { rotation = newValue }
    }

    func body(content: Content) -> some View {
        let p = metrics.placement(index: index, rotation: rotation, count: count)
        return content
            .shadow(color: HomeDesign.Color.ink900.opacity(p.shadowOpacity), radius: p.shadowRadius, x: 0, y: p.shadowY)
            .scaleEffect(p.scale)
            .offset(x: p.dx)
            .opacity(p.opacity)
            .zIndex(p.zIndex)
            .allowsHitTesting(p.isFocal && p.opacity > 0.5)
    }
}

// MARK: - 카드 1장 (이미지가 주인공, 텍스트는 하단 두 줄)

private struct RecallCoverCard: View {
    let entry: RecallFeedEntryDTO
    let imageRef: ImageRef?

    private var reason: RecallReasonKind { RecallReasonKind(reason: entry.reason) }

    var body: some View {
        content
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.18), radius: 18, x: 0, y: 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(reason.accessibilityLabel). \(entry.title).")
            .accessibilityHint("눌러서 자세히 보기")
    }

    /// 이미지가 있으면 캡처가 주인공(하단 캡션만), 없으면 **글(제목)이 주인공**인 카드.
    @ViewBuilder
    private var content: some View {
        if let imageRef {
            imageCover(imageRef)
        } else {
            textCover
        }
    }

    // MARK: 이미지 커버 — 캡처 풀블리드 + 하단 스크림 + reason·제목.

    private func imageCover(_ ref: ImageRef) -> some View {
        ZStack(alignment: .bottomLeading) {
            LocalThumbnail(
                relativePath: ref.relativePath,
                objectKey: ref.objectKey,
                sha256: ref.sha256,
                mimeType: ref.mimeType,
                targetSize: CGSize(width: 190, height: 360),
                // center 크롭 — 상세 헤더(ScreenshotPreviewImage)·hero 비행체(scaleAspectFill)와 같은 정렬이라
                // 카드 → 상세 zoom 에서 이미지 내용이 위아래로 튀지 않는다(UX_SPEC §3.4: 세로=center fill).
                alignment: .center
            ) { reasonWash }
            // 하단 스크림 — 텍스트 대비. 위쪽(캡처 본문)은 건드리지 않는다.
            LinearGradient(
                colors: [.clear, .black.opacity(0.18), .black.opacity(0.66)],
                startPoint: .center, endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                reasonTag
                Text(entry.title)
                    .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    // MARK: 텍스트 커버 — 글이 주인공(이미지 없는 메모·URL·순수 지식 회수).
    //
    // 이미지가 없으면 회상의 트리거는 "그때 그 글"이다 — 제목을 에디토리얼하게 크게 세우고,
    // 한 줄 요약·출처를 곁들인다. 인용 글리프를 배경 모티프로 깔아 색 면에 깊이를 준다.

    private var textCover: some View {
        ZStack(alignment: .topLeading) {
            reasonWash
            Text(verbatim: "\u{201C}")
                .font(.system(size: 150, weight: .black, design: .serif))
                .foregroundStyle(.white.opacity(0.14))
                .offset(x: 4, y: -6)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                reasonTag
                Spacer(minLength: HomeDesign.Spacing.sm)
                Text(entry.title)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if !entry.oneline.isEmpty {
                    Text(entry.oneline)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text(sourceLabel)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    // MARK: 소품

    /// reason 색 깊은 그라데이션 + 상단 은은한 빛 — 이미지 폴백 & 텍스트 카드 배경 공통.
    private var reasonWash: some View {
        ZStack {
            LinearGradient(colors: reason.heroColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(
                colors: [.white.opacity(0.16), .clear],
                center: .topLeading, startRadius: 4, endRadius: 220
            )
        }
    }

    private var reasonTag: some View {
        HStack(spacing: 4) {
            Image(systemName: reason.icon)
                .font(.system(size: 9, weight: .bold))
            Text(reason.label)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.white.opacity(0.18)))
    }

    private var sourceLabel: String {
        entry.source.isEmpty ? "내 기록" : entry.source
    }
}

// MARK: - reason → 폴백 색 (이미지 없는 회수)

private extension RecallReasonKind {
    var heroColors: [Color] {
        switch self {
        case .relatedCluster: [HomeDesign.Color.purple400, HomeDesign.Color.purple600]
        case .fadingValue:    [HomeDesign.Color.peach400, HomeDesign.Color.blush400]
        case .revisitedOften: [HomeDesign.Color.mint400, HomeDesign.Color.sky400]
        case .linkedToRecent: [HomeDesign.Color.sky400, HomeDesign.Color.purple500]
        }
    }
}

// MARK: - Preview

#Preview("회수 히어로") {
    RecallHeroView(
        entries: [
            .init(itemID: UUID(), kind: "knowledge", reason: "fadingValue",
                  title: "RAG 검색 — Hybrid 전략", oneline: "한 달째 안 펼쳐보셨어요",
                  source: "medium", savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 30),
                  relatedCount: 1, recallEventID: UUID()),
            .init(itemID: UUID(), kind: "knowledge", reason: "relatedCluster",
                  title: "성수동 카페 세 곳", oneline: "비슷한 걸 여러 번 담아두셨어요",
                  source: "instagram", savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 12),
                  relatedCount: 3, recallEventID: UUID()),
            .init(itemID: UUID(), kind: "general", reason: "linkedToRecent",
                  title: "환율 우대 카드 비교", oneline: "최근에 보신 것과 이어져요",
                  source: "blog", savedAt: Date().addingTimeInterval(-60 * 60 * 30),
                  relatedCount: 1, recallEventID: UUID()),
        ],
        images: [:],
        onOpenAll: {},
        onOpenFocal: { _, _ in }
    )
    .padding()
    .background(HomeDesign.Color.bg)
}
