import SwiftUI
import ComposableArchitecture
import CoreNetworking
import DesignSystem

/// 능동 회수 3단의 화면들 — 홈 "한 칸"(요약) · ② 자세히(통일 카드 목록) · ③ 기록 상세.
///
/// 디자인: 단일 토큰 소스 ``HomeDesign``(mock 의 RD 복제 토큰 폐기). 기존 홈/상세 패턴과 일치 —
/// riseIn stagger 등장, PressableStyle, cardShadow, 보라 그라데이션 CTA, 파스텔 이유 칩.
/// 회수=분류 아님: category 통계·주제 라벨 0개. "왜 지금 떠올렸나"(이유 칩)만 신호로 노출.
///
/// 접근성(codex-9): 이유 칩 VoiceOver 의미 라벨 · Dynamic Type 큰 글자에서 미리보기 2줄 확장 ·
/// 상세 액션 가로→세로 스택 전환 · destructive "그만"은 primary 와 시각적 분리.

// MARK: - 회수 이유의 시각 언어 (분류 아님 — "왜 지금" 신호의 단일 색 소스)

/// reason → 색을 한 곳에서 정한다. 칩·썸네일·상세 히어로가 같은 reason엔 같은 색을 쓰도록 통일
/// (이전엔 칩 tint 와 썸네일 grad 가 reason마다 따로 놀아 같은 "왜 지금"이 두 색으로 보였다).
/// 색은 UI 전용이라 ``RecallReasonKind``(Feature) 가 아니라 View 레이어에 둔다(ux-ui §3).
private extension RecallReasonKind {
    /// 단일 강조색 — 칩 글자·테두리, 상세 워터마크·primary 톤.
    var tint: Color {
        switch self {
        case .relatedCluster: HomeDesign.Color.purple500
        case .fadingValue:    HomeDesign.Color.peach400
        case .revisitedOften: HomeDesign.Color.mint400
        case .linkedToRecent: HomeDesign.Color.sky400
        }
    }

    /// 옅은 배경 틴트 — 상세 히어로 그라데이션의 받침색.
    var paleTint: Color {
        switch self {
        case .relatedCluster: HomeDesign.Color.purple50
        case .fadingValue:    HomeDesign.Color.butter50
        case .revisitedOften: HomeDesign.Color.mint100
        case .linkedToRecent: HomeDesign.Color.sky100
        }
    }

    /// 썸네일·강조 그라데이션 — tint 와 같은 색조 계열로 정합.
    var gradient: [Color] {
        switch self {
        case .relatedCluster: [HomeDesign.Color.purple200, HomeDesign.Color.purple500]
        case .fadingValue:    [HomeDesign.Color.butter100, HomeDesign.Color.peach400]
        case .revisitedOften: [HomeDesign.Color.mint100, HomeDesign.Color.mint400]
        case .linkedToRecent: [HomeDesign.Color.sky100, HomeDesign.Color.sky400]
        }
    }
}

/// 회수 화면 공용 배경 — bg 위 상단 라벤더 글로우. 홈·월간 정리(`MonthlyDigestView`)와 같은 기조로
/// 화면 간 연속성을 만든다("모찌의 보라 세계로 들어왔다").
private struct RecallAuroraBackground: View {
    var body: some View {
        ZStack {
            HomeDesign.Color.bg
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.30),
                    HomeDesign.Color.purple100.opacity(0.10),
                    Color.white.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - 회수 이유 칩 (분류 아님 — 회수 신호)

/// 파스텔 캡슐 칩. 색/아이콘은 ``RecallReasonKind`` 가 ``HomeDesign`` 토큰으로 매핑.
struct RecallReasonChip: View {
    let reason: RecallReasonKind
    var compact: Bool = false
    var trailing: String? = nil

    init(_ reason: RecallReasonKind, compact: Bool = false, trailing: String? = nil) {
        self.reason = reason
        self.compact = compact
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.xs + 1) {
            Image(systemName: reason.icon)
                .font(.system(size: compact ? 9.5 : 11, weight: .bold))
            Text(reason.label)
                .font(.system(size: compact ? 10.5 : 11.5, weight: .bold, design: .rounded))
                .tracking(0.1)
            if let trailing {
                Text("·").foregroundStyle(reason.tint.opacity(0.4))
                Text(trailing)
                    .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(reason.tint)
        .padding(.horizontal, compact ? HomeDesign.Spacing.sm : HomeDesign.Spacing.sm + 2)
        .padding(.vertical, compact ? 3 : 4)
        .background(Capsule().fill(reason.tint.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(trailing.map { "\(reason.accessibilityLabel), \($0)" } ?? reason.accessibilityLabel)
    }
}

// MARK: - 썸네일 (실제론 캡처 이미지 — 지금은 reason 색 그라데이션 placeholder)

/// kind/related 로 그라데이션·심볼을 정한다. 묶음(related>1)이면 겹친 표시로 "여럿"을 암시.
/// 표시·게이트는 서버 `relatedCount` 가 아니라 실제 렌더 가능한 `related.count`(파싱 드롭 반영)로 통일.
private struct RecallThumb: View {
    let entry: RecallFeedEntryDTO
    var size: CGFloat = 48

    var body: some View {
        if entry.related.count > 1 {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.19, style: .continuous)
                    .fill(grad.first!.opacity(0.55))
                    .frame(width: size - 4, height: size - 4)
                    .rotationEffect(.degrees(8))
                    .offset(x: 4, y: -2)
                tile
            }
            .frame(width: size + 4, height: size + 2)
        } else {
            tile
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
            .fill(LinearGradient(colors: grad, startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            // 좌상단 광택 — 평면 그라데이션에 입체감을 더한다.
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.40), .clear],
                            center: .topLeading, startRadius: 0, endRadius: size * 0.85
                        )
                    )
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: grad.last!.opacity(0.45), radius: 3, x: 0, y: 1)
            )
            .shadow(color: grad.last!.opacity(0.35), radius: 8, x: 0, y: 4)
    }

    private var grad: [Color] { RecallReasonKind(reason: entry.reason).gradient }

    private var symbol: String {
        switch entry.kind {
        case "knowledge": "book.fill"
        default:          "sparkles"
        }
    }
}

// MARK: - ① 홈 "한 칸" (고정 틀 + 가장 가치 높은 1개 미리보기)

/// 홈에 고정으로 노출되는 회수 요약 카드. count + 최상위 1건 미리보기(안 눌러도 떠오르게).
/// 비면 "지금은 없어요"로 채워 레이아웃이 출렁이지 않게 한다(고정 틀, ux-ui §2·§6).
/// Dynamic Type 확대 시 미리보기는 2줄까지 확장(잘림 금지, codex-9).
struct RecallEntryCard: View {
    let entries: [RecallFeedEntryDTO]
    let onTap: () -> Void

    private var top: RecallFeedEntryDTO? { entries.first }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: HomeDesign.Spacing.md) {
                sparkleBadge

                if let top {
                    filled(top: top)
                } else {
                    empty
                }
            }
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [HomeDesign.Color.surface, HomeDesign.Color.purple50.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
            )
            .cardShadow()
        }
        .buttonStyle(PressableStyle())
        .disabled(entries.isEmpty)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(entries.isEmpty ? "" : "눌러서 전체 보기")
    }

    private var sparkleBadge: some View {
        ZStack {
            Circle().fill(HomeDesign.Color.purple50)
                .frame(width: 42, height: 42)
                .overlay(Circle().stroke(HomeDesign.Color.purpleGlow.opacity(0.35), lineWidth: 2.5))
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
        }
        .accessibilityHidden(true)
    }

    private func filled(top: RecallFeedEntryDTO) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                Text("다시 보면 좋을 기억")
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    Text("\(entries.count)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(HomeDesign.Color.purple500)
            }
            // 최상위 1건만 미리보기 — Dynamic Type 확대 시 2줄까지(잘림 금지).
            Text("“\(top.title)” \(top.oneline)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("다시 보면 좋을 기억")
                .font(.system(size: 15.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Text("지금은 없어요 · 새 기억이 무르익으면 꺼내드릴게요")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textFaint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessibilityLabel: String {
        guard let top else { return "다시 보면 좋을 기억. 지금은 없어요." }
        return "다시 보면 좋을 기억 \(entries.count)개. 예를 들어 \(top.title), \(top.oneline)."
    }
}

// MARK: - ② 자세히 보기 (통일 카드 목록)

public struct RecallListView: View {
    @Bindable var store: StoreOf<RecallListFeature>
    /// 진입 시 히어로 등장 트리거 (한 번만).
    @State private var hasEntered = false

    public init(store: StoreOf<RecallListFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                if store.entries.isEmpty {
                    emptyState
                        .riseIn(hasEntered, index: 0)
                } else {
                    heroHeader
                        .riseIn(hasEntered, index: 0)
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        Button { store.send(.entryTapped(entry)) } label: {
                            UnifiedRecallCard(entry: entry)
                        }
                        .buttonStyle(PressableStyle())
                        .surfaceOnAppear(index: index)
                    }
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, 40)
        }
        .background(RecallAuroraBackground().ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("다시 볼 기억")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            store.send(.onAppear)
            hasEntered = true
        }
    }

    // MARK: 히어로 — 모찌가 먼저 떠올려줬다는 톤(능동 주체=모찌). 마스코트 대신 스파클 오브.

    private var heroHeader: some View {
        HStack(alignment: .center, spacing: HomeDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                Text("모찌가 떠올렸어요")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(HomeDesign.Color.purple600)
                (Text("다시 보면 좋을 기억 ")
                 + Text("\(store.entries.count)개").foregroundStyle(HomeDesign.Color.purple600))
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("요즘 안 보셨지만, 눌러보면 그때 무엇이었는지 다시 보여드릴게요")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: HomeDesign.Spacing.sm)
            sparkleOrb(size: 56, glow: 92)
        }
        .padding(HomeDesign.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.4)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
        )
        .cardShadow()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("모찌가 떠올린, 다시 보면 좋을 기억 \(store.entries.count)개")
    }

    private var emptyState: some View {
        VStack(spacing: HomeDesign.Spacing.lg) {
            sparkleOrb(size: 64, glow: 116)
            VStack(spacing: 6) {
                Text("지금은 떠올릴 기억이 없어요")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("기억이 무르익으면 모찌가 먼저 꺼내드릴게요")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
        .padding(.bottom, 40)
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .accessibilityElement(children: .combine)
    }

    /// 스파클 글로우 오브 — 회수의 시그니처. 보라 글로우 위 그라데이션 원 + sparkles(마스코트 대체).
    private func sparkleOrb(size: CGFloat, glow: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [HomeDesign.Color.purpleGlow.opacity(0.38), .clear],
                        center: .center, startRadius: 2, endRadius: glow / 2
                    )
                )
                .frame(width: glow, height: glow)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size)
                .shadow(color: HomeDesign.Color.purple500.opacity(0.4), radius: 10, x: 0, y: 5)
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: glow, height: glow)
        .accessibilityHidden(true)
    }
}

/// 통일 카드 — 모든 회수가 같은 틀(종류 차이는 상세에서). 썸네일 + 이유 칩 + 제목 + 한 줄 + 시점.
private struct UnifiedRecallCard: View {
    let entry: RecallFeedEntryDTO

    private var reason: RecallReasonKind { RecallReasonKind(reason: entry.reason) }

    var body: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            RecallThumb(entry: entry, size: 52)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    RecallReasonChip(reason, compact: true)
                    Spacer(minLength: 0)
                    Text(entry.savedAt.recallRelative)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                }
                Text(entry.title)
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)
                Text(entry.oneline)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if entry.related.count > 1 {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("관련 기억 \(entry.related.count)개")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(HomeDesign.Color.purple500)
                    .padding(.horizontal, HomeDesign.Spacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(HomeDesign.Color.purple50))
                    .padding(.top, 2)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HomeDesign.Color.textFaint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(HomeDesign.Color.bg))
                .padding(.top, 2)
        }
        .padding(HomeDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .cardShadow()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(reason.accessibilityLabel). \(entry.title). \(entry.oneline). \(entry.savedAt.recallRelative)"
            + (entry.related.count > 1 ? ". 관련 기억 \(entry.related.count)개" : "")
        )
    }
}

// MARK: - ③ 기록 상세 (kind별 디테일 + 응답 액션)

public struct RecallDetailView: View {
    @Bindable var store: StoreOf<RecallDetailFeature>
    /// 진입 시 섹션 순차 등장 트리거 (한 번만).
    @State private var hasEntered = false
    /// Dynamic Type 큰 글자면 액션 버튼을 세로로 쌓는다(가로 잘림 방지, codex-9).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(store: StoreOf<RecallDetailFeature>) {
        self.store = store
    }

    private var entry: RecallFeedEntryDTO { store.entry }
    private var reason: RecallReasonKind { RecallReasonKind(reason: entry.reason) }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                heroCard.riseIn(hasEntered, index: 0)
                originCard.riseIn(hasEntered, index: 1)

                if entry.kind == "knowledge", !entry.gist.isEmpty {
                    gistCard.riseIn(hasEntered, index: 2)
                }

                if entry.related.count > 1 {
                    relatedList.riseIn(hasEntered, index: 3)
                }

                guideVoice.riseIn(hasEntered, index: 4)
                actions.riseIn(hasEntered, index: 5)
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, HomeDesign.Spacing.xxl)
        }
        .background(RecallAuroraBackground().ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("기록 상세")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let toast = store.toast { RecallToast(text: toast) }
        }
        .task {
            store.send(.onAppear)
            hasEntered = true
        }
    }

    /// 히어로 — "왜 지금 떠올렸나"를 reason 색으로 입은 카드. 큰 이유 아이콘을 옅은 워터마크로 깔아
    /// 이 기억이 어떤 신호로 떠올랐는지 한눈에 전한다(회수=분류 아님이라 주제 라벨은 없다).
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            RecallReasonChip(reason, trailing: entry.savedAt.recallRelative)
            Text(entry.title)
                .font(.system(size: 21, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.oneline)
                .font(.system(size: 13.5, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HomeDesign.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, reason.paleTint, reason.paleTint.opacity(0.5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                // 옅은 이유 워터마크 — 카드 안에서 클립.
                Image(systemName: reason.icon)
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(reason.tint.opacity(0.10))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 22, y: -18)
            }
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(reason.tint.opacity(0.25), lineWidth: 1.2)
        )
        .cardShadow()
        .accessibilityElement(children: .combine)
    }

    /// 저장한 원본 — 탭하면 원본 mochiItem 상세를 연다(원본 대체 금지, ux-ui §5).
    private var originCard: some View {
        Button { store.send(.openOriginalTapped) } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                RecallThumb(entry: RecallFeedEntryDTO(
                    itemID: entry.itemID, kind: entry.kind, reason: entry.reason,
                    title: entry.title, oneline: entry.oneline, source: entry.source,
                    savedAt: entry.savedAt, relatedCount: 1
                ), size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("저장한 원본")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    Text(entry.source)
                        .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                    Text("“\(entry.oneline)”")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                        .italic()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(HomeDesign.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("저장한 원본 보기. \(entry.source)")
    }

    /// 지식 — 모찌가 정리한 핵심(원본 안 봐도 떠올림). 기존 상세 GistCard 와 같은 기조.
    private var gistCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            Label("모찌가 정리한 핵심", systemImage: "sparkles")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.mint400)
            ForEach(Array(entry.gist.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
                    Circle().fill(HomeDesign.Color.mint400)
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    Text(line)
                        .font(.system(size: 13.5, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.ink700)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(HomeDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [HomeDesign.Color.surface, HomeDesign.Color.mint100.opacity(0.5)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.mint100, lineWidth: 1.2)
        )
    }

    /// 관련 기억 묶음 — 분류가 아니라 "같은 대상에 남긴 기록들"(트랙 C). 탭하면 그 항목 상세로.
    private var relatedList: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            Text("관련해서 담아둔 기록")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.purple500)
            ForEach(entry.related) { item in
                Button { store.send(.relatedTapped(item)) } label: {
                    HStack(spacing: HomeDesign.Spacing.md) {
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                            .fill(HomeDesign.Color.purple50)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(HomeDesign.Color.purple500)
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textPrimary)
                                .lineLimit(1)
                            Text(item.oneline)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textMuted)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(HomeDesign.Color.textFaint)
                    }
                    .padding(HomeDesign.Spacing.sm + 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                            .fill(HomeDesign.Color.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                            .stroke(HomeDesign.Color.border, lineWidth: 1)
                    )
                }
                .buttonStyle(PressableStyle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("관련 기억. \(item.title). \(item.oneline).")
                .accessibilityHint("눌러서 자세히 보기")
            }
        }
    }

    /// 모찌가 건네는 한마디 — 부담 없이 응답하면 된다는 톤. 보라 틴트 칸으로 액션과 자연스레 잇는다.
    private var guideVoice: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HomeDesign.Color.purple500)
                .padding(.top, 1)
            Text(entry.kind == "knowledge"
                 ? "기억나셨으면 가볍게 알려만 주세요. 다음엔 더 늦게 꺼낼게요."
                 : "필요하면 가볍게 알려만 주세요. 무엇을 할지는 천천히 정하시면 돼요.")
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.purple50.opacity(0.7))
        )
        .accessibilityElement(children: .combine)
    }

    /// 응답 액션 — primary=목적 수행(원본 보기), 피드백("기억났어요")은 보조, "그만 보기"는 destructive 분리.
    /// Dynamic Type 큰 글자면 세로 스택으로 전환(가로 잘림 방지). "그만"은 항상 한 칸 떨어뜨려 오탭 방지.
    @ViewBuilder
    private var actions: some View {
        let stackVertically = dynamicTypeSize >= .accessibility1
        if stackVertically {
            VStack(spacing: HomeDesign.Spacing.sm) {
                primaryAction.frame(maxWidth: .infinity)
                secondaryAction.frame(maxWidth: .infinity)
                Divider().padding(.vertical, 2)
                stopAction.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: HomeDesign.Spacing.sm) {
                primaryAction
                secondaryAction
                Spacer(minLength: HomeDesign.Spacing.md)
                stopAction
            }
        }
    }

    private var primaryAction: some View {
        RecallAction(text: "원본 보기", icon: "arrow.up.right", tint: HomeDesign.Color.purple500, filled: true) {
            store.send(.openOriginalTapped)
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if entry.kind == "knowledge" {
            RecallAction(text: "기억났어요", icon: "checkmark", tint: HomeDesign.Color.mint400) {
                store.send(.rememberedTapped)
            }
        }
    }

    private var stopAction: some View {
        RecallAction(
            text: "그만 보기", icon: "bell.slash",
            tint: HomeDesign.Color.textMuted, role: .destructive
        ) {
            store.send(.stopTapped)
        }
        .disabled(store.didStop)
        .opacity(store.didStop ? 0.5 : 1)
    }
}

// MARK: - 소품

/// 응답 액션 버튼 — filled(primary 보라) / outline(보조) / destructive("그만", 점선 분리).
private struct RecallAction: View {
    let text: String
    let icon: String
    var tint: Color = HomeDesign.Color.textMuted
    var filled: Bool = false
    var role: ButtonRole? = nil
    var action: () -> Void = {}

    private var isDestructive: Bool { role == .destructive }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: HomeDesign.Spacing.xs) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(text)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(filled ? .white : tint)
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .background(capsuleBackground)
            .overlay(Capsule().stroke(border, style: borderStyle))
        }
        .buttonStyle(PressableStyle())
    }

    /// primary(filled)는 보라 그라데이션 + 글로우로 "목적 수행"을 가장 또렷한 행동 신호로 띄운다.
    /// 나머지는 단색 캡슐(보조) / 투명+점선(destructive, 오탭 분리, codex-9).
    @ViewBuilder
    private var capsuleBackground: some View {
        if filled {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [HomeDesign.Color.purple500, HomeDesign.Color.purple600],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .shadow(color: HomeDesign.Color.purple500.opacity(0.40), radius: 9, x: 0, y: 4)
        } else {
            Capsule().fill(isDestructive ? Color.clear : HomeDesign.Color.surface)
        }
    }

    private var border: Color {
        if filled { return .clear }
        return isDestructive ? HomeDesign.Color.blush400.opacity(0.6) : HomeDesign.Color.border
    }

    private var borderStyle: StrokeStyle {
        isDestructive ? StrokeStyle(lineWidth: 1, dash: [4, 3]) : StrokeStyle(lineWidth: 1)
    }
}

/// 하단 확인 토스트 — 잉크색 캡슐(기존 토스트 톤).
private struct RecallToast: View {
    let text: String
    var body: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(HomeDesign.Color.mint400)
            Text(text)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.vertical, HomeDesign.Spacing.md)
        .background(Capsule().fill(HomeDesign.Color.ink900))
        .cardShadow()
        .padding(.bottom, HomeDesign.Spacing.xxl)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - "흐릿하던 기억이 또렷이 떠오르는" stagger 등장 (목록 전용)

private struct SurfaceOnAppear: ViewModifier {
    let index: Int
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onAppear {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.85).delay(Double(index) * 0.07)) {
                    shown = true
                }
            }
    }
}

private extension View {
    func surfaceOnAppear(index: Int) -> some View { modifier(SurfaceOnAppear(index: index)) }
}

// MARK: - 상대 시점 포맷 ("3일 전" 등)

private extension Date {
    /// 회수 카드의 "언제 저장" 표기 — 한국어 상대 시점. 분 단위는 노출 안 함(기억 회수엔 과한 정밀도).
    var recallRelative: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        let now = Date()
        if now.timeIntervalSince(self) < 60 { return "방금" }
        return formatter.localizedString(for: self, relativeTo: now)
    }
}

// MARK: - Previews

#Preview("② 자세히 — 통일 카드") {
    NavigationStack {
        RecallListView(store: Store(
            initialState: RecallListFeature.State(entries: RecallFeedEntryDTO.previewFeed)
        ) { RecallListFeature() })
    }
    .tint(HomeDesign.Color.purple500)
}

#Preview("③ 기록 상세 — 지식") {
    NavigationStack {
        RecallDetailView(store: Store(
            initialState: RecallDetailFeature.State(entry: RecallFeedEntryDTO.previewFeed[0])
        ) { RecallDetailFeature() })
    }
    .tint(HomeDesign.Color.purple500)
}

#Preview("③ 기록 상세 — 관련 묶음") {
    NavigationStack {
        RecallDetailView(store: Store(
            initialState: RecallDetailFeature.State(entry: RecallFeedEntryDTO.previewFeed[2])
        ) { RecallDetailFeature() })
    }
    .tint(HomeDesign.Color.purple500)
}

#Preview("① 홈 한 칸") {
    VStack(spacing: 20) {
        RecallEntryCard(entries: RecallFeedEntryDTO.previewFeed) {}
        RecallEntryCard(entries: []) {}
    }
    .padding()
    .background(HomeDesign.Color.bg)
}

private extension RecallFeedEntryDTO {
    static let previewFeed: [RecallFeedEntryDTO] = [
        .init(
            itemID: UUID(), kind: "knowledge", reason: "fadingValue",
            title: "RAG 검색 — Hybrid 전략", oneline: "한 달째 안 펼쳐보셨어요",
            source: "medium · Hybrid Search", savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 30),
            gist: ["BM25(키워드)와 벡터(의미) 후보를 각각 뽑아 합친다",
                   "합친 뒤 rerank 해 상위만 남긴다",
                   "오타·동의어엔 벡터가, 고유명사엔 BM25가 강하다"],
            relatedCount: 1, recallEventID: UUID()
        ),
        .init(
            itemID: UUID(), kind: "knowledge", reason: "revisitedOften",
            title: "TCA 의존성 주입 패턴", oneline: "최근 자주 들춰보시던 자료예요",
            source: "pointfree.co", savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 3),
            gist: ["@Dependency 로 클라이언트를 주입한다", "테스트는 withDependencies 로 교체"],
            relatedCount: 1, recallEventID: nil
        ),
        .init(
            itemID: UUID(), kind: "knowledge", reason: "relatedCluster",
            title: "성수동 카페 세 곳", oneline: "비슷한 걸 여러 번 담아두셨어요",
            source: "instagram · 저장한 장소", savedAt: Date().addingTimeInterval(-60 * 60 * 24 * 12),
            gist: ["로스터리 중심 · 좌석 여유", "주말 오픈 시간 제각각 — 확인 필요"],
            related: [
                .init(itemID: UUID(), title: "어니언 성수", oneline: "베이커리 같이 운영"),
                .init(itemID: UUID(), title: "센터커피 성수", oneline: "넓고 콘센트 많음"),
                .init(itemID: UUID(), title: "대림창고", oneline: "전시 겸 카페"),
            ],
            relatedCount: 3, recallEventID: UUID()
        ),
        .init(
            itemID: UUID(), kind: "general", reason: "linkedToRecent",
            title: "환율 우대 카드 비교", oneline: "지금 보시던 여행 준비와 이어져요",
            source: "blog · 해외 결제 카드", savedAt: Date().addingTimeInterval(-60 * 60 * 30),
            relatedCount: 1, recallEventID: UUID()
        ),
    ]
}
