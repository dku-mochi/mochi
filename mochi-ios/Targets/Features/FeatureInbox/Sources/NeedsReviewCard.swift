import SwiftUI
import CoreDomain
import DesignSystem

/// "모찌가 헷갈려요" 카드 덱 — 미분류 항목을 한 장씩 넘기며 후보 의도를 고른다.
///
/// 후보 칩 선택 = 그 의도(label)를 hint 로 **재분석**(`onReanalyze`) — intent 라벨만 박지 않고
/// payload·날짜를 보강해 캘린더/할일로 쓸 수 있게 한다(로컬 즉시확정 폐기, MochiHomeFeature 참고).
/// 앞 카드만 인터랙티브하고 뒤 카드는 쌓임으로 비친다. 좌우 드래그로 분류를 미루고 다음을 먼저 본다.
struct NeedsReviewCard: View {
    let mochiItems: [MochiItem]
    @Binding var page: Int
    let onReanalyze: (MochiItem.ID, String) -> Void
    let onRetry: (MochiItem.ID) -> Void

    @State private var drag: CGFloat = 0
    /// 이번 드래그 시퀀스가 "스와이프"로 판정됐는가 — 버튼 위에서 스와이프하다 손을 떼는 순간
    /// 버튼 탭(재분석)이 오발동하는 것을 막는 가드. 스와이프 중이면 칩 액션을 무시한다.
    @State private var didSwipe = false

    private let cardHeight: CGFloat = 360

    var body: some View {
        if mochiItems.isEmpty {
            emptyState
        } else {
            VStack(spacing: HomeDesign.Spacing.lg) {
                deck
                footer
            }
        }
    }

    // MARK: - Deck

    /// page 부터 최대 3장 — depth 0 이 앞장(인터랙티브), 뒤 2장은 쌓임 peek.
    private var visible: [(depth: Int, item: MochiItem)] {
        (0..<min(3, mochiItems.count)).map { offset in
            (offset, mochiItems[(page + offset) % mochiItems.count])
        }
    }

    private var deck: some View {
        ZStack {
            ForEach(visible.reversed(), id: \.item.id) { entry in
                AmbiguousCard(
                    mochiItem: entry.item,
                    height: cardHeight,
                    // 스와이프 중 손을 떼며 발생하는 오발동을 가드 — 순수 탭(움직임 미달)만 통과한다.
                    onReanalyze: { id, hint in if !didSwipe { onReanalyze(id, hint) } },
                    onRetry: { id in if !didSwipe { onRetry(id) } }
                )
                .zIndex(Double(3 - entry.depth))
                .scaleEffect(1 - CGFloat(entry.depth) * 0.05, anchor: .bottom)
                .offset(y: CGFloat(entry.depth) * 14)
                .offset(x: entry.depth == 0 ? drag : 0)
                .rotationEffect(.degrees(entry.depth == 0 ? Double(drag / 24) : 0), anchor: .bottom)
                .opacity(entry.depth == 0 ? 1 : 0.55)
                .allowsHitTesting(entry.depth == 0)
                // 버튼 위에서도 드래그가 잡히도록 simultaneous — 단 가로 우세일 때만 카드가 움직인다(아래 gesture).
                .simultaneousGesture(
                    skipGesture,
                    including: entry.depth == 0 && mochiItems.count > 1 ? .all : .subviews
                )
            }
        }
        .frame(height: cardHeight + 28)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: page)
    }

    /// 좌우로 충분히 끌면 분류를 미루고 다음 항목으로 (덱 순환).
    /// `minimumDistance` + 가로 우세 판별로 순수 탭(버튼)·세로 스크롤(시트)은 양보하고 가로 스와이프만 잡는다.
    private var skipGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                // 세로가 우세하면 시트 스크롤에 양보 — 카드도 안 움직이고 스와이프로 치지 않는다.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                didSwipe = true
                drag = value.translation.width
            }
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                if isHorizontal && abs(value.translation.width) > 96 {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.84)) {
                        page = (page + 1) % mochiItems.count
                        drag = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { drag = 0 }
                }
                // 버튼 탭이 이 직후 발동할 수 있어 한 박자 뒤 리셋(스와이프-끝-탭 오발동 차단).
                DispatchQueue.main.async { didSwipe = false }
            }
    }

    // MARK: - Footer

    private var footer: some View {
        // page 가 리스트 축소 직후 잠깐 count 밖일 수 있어 deck 과 같은 정규화로 active dot 을 맞춘다.
        let activePage = page % mochiItems.count
        return VStack(spacing: HomeDesign.Spacing.sm) {
            HStack(spacing: 5) {
                ForEach(mochiItems.indices, id: \.self) { idx in
                    Capsule()
                        .fill(idx == activePage ? HomeDesign.Color.purple500 : HomeDesign.Color.ink100)
                        .frame(width: idx == activePage ? 20 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
                }
            }
            if mochiItems.count > 1 {
                Text("옆으로 넘기면 다음에 정리할게요")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty

    private var emptyState: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.mint100).frame(width: 46, height: 46)
                Image(systemName: "checkmark")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.mint400)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("정리할 게 없어요")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("모찌가 다 분류했어요. 새 캡처를 기다리는 중이에요.")
                    .font(.system(size: 12.5, weight: .regular, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            Spacer(minLength: 0)
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
    }
}

// MARK: - One card

private struct AmbiguousCard: View {
    let mochiItem: MochiItem
    let height: CGFloat
    let onReanalyze: (MochiItem.ID, String) -> Void
    let onRetry: (MochiItem.ID) -> Void

    @State private var showsHintInput = false
    @State private var hintText = ""

    /// 미확정 후보 (API projection). 강등·미영속 시 비어 있어 "다른 의도"만 노출된다.
    private var options: [ReviewOption] { mochiItem.analysis?.reviewOptions ?? [] }
    /// 분석 실패로 강등된 항목인가 — 명시 마커로 판별(멱등 replay 로 후보만 빈 정상 항목과 구분).
    private var isFailed: Bool { mochiItem.analysis?.isAnalysisFailed ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            header
            question
            Spacer(minLength: 0)
            choices
        }
        .padding(HomeDesign.Spacing.lg)
        .frame(height: height, alignment: .top)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous))
        .cardShadow()
        .alert("어떤 의도였는지 알려주세요", isPresented: $showsHintInput) {
            TextField("예: 나중에 다시 보려고 저장했어요", text: $hintText)
            Button("다시 분석") {
                let trimmed = hintText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { onReanalyze(mochiItem.id, trimmed) }
                hintText = ""
            }
            Button("취소", role: .cancel) { hintText = "" }
        } message: {
            Text("모찌가 헷갈려해요. 어떤 의도였는지 한 줄로 적어주시면 모찌가 다시 분석할게요.")
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [HomeDesign.Color.surface, HomeDesign.Color.cream50],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    /// 미리보기(84² 상단 크롭) + 출처 태그·제목·부제.
    private var header: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            preview
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs) {
                MochiItemKindTag(kind: mochiItem.viewKind)
                Text(mochiItem.displayTitle)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .tracking(-0.2)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(mochiItem.displaySubtitle)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            switch mochiItem.viewKind {
            case .screenshot:
                LocalThumbnail(
                    relativePath: mochiItem.source.imageRefs.first?.displayRelativePath,
                    objectKey: mochiItem.source.imageRefs.first?.objectKey,
                    sha256: mochiItem.source.imageRefs.first?.sha256,
                    mimeType: mochiItem.source.imageRefs.first?.mimeType,
                    targetSize: CGSize(width: 84, height: 84),
                    alignment: .top
                ) {
                    placeholderTile(.screenshot)
                }
            case .memo:
                placeholderTile(.memo)
            case .url:
                placeholderTile(.url)
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }

    private func placeholderTile(_ kind: MochiItemKind) -> some View {
        ZStack {
            kind.background
            Image(systemName: kind.icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(kind.tint.opacity(0.75))
        }
    }

    /// 모찌가 묻는 톤 — 후보가 있으면 권유, 실패면 도움 요청.
    private var question: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            ZStack {
                Circle().fill(HomeDesign.Color.butter50).frame(width: 26, height: 26)
                Image(systemName: isFailed ? "questionmark" : "sparkles")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.peach400)
            }
            Text(isFailed ? "잘 모르겠어요. 어떤 거였는지 알려줄래요?" : "이 중에 맞는 게 있나요?")
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
            Spacer(minLength: 0)
        }
    }

    /// 후보 행(최대 2) + 보조 액션("다른 의도" 자연어 재분석 / 실패 시 "다시 맡기기").
    private var choices: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            ForEach(Array(options.prefix(2).enumerated()), id: \.offset) { idx, option in
                IntentChoiceRow(option: option, isPrimary: idx == 0) {
                    onReanalyze(mochiItem.id, option.displayLabel)
                }
            }
            HStack(spacing: HomeDesign.Spacing.sm) {
                SecondaryActionButton(icon: "ellipsis", title: "다른 의도") {
                    showsHintInput = true
                }
                if isFailed {
                    SecondaryActionButton(icon: "arrow.clockwise", title: "다시 맡기기", emphasized: true) {
                        onRetry(mochiItem.id)
                    }
                }
            }
        }
    }
}

// MARK: - Choice row

/// 후보 의도 행 — intent 색 아이콘 + 라벨 + 모찌 근거. 탭하면 그 의도로 재분석.
private struct IntentChoiceRow: View {
    let option: ReviewOption
    let isPrimary: Bool
    let action: () -> Void

    private var viewIntent: MochiViewIntent { MochiViewIntent(option.intentType) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(viewIntent.chipBackground)
                    Image(systemName: option.intentType.systemImageName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(viewIntent.dotColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 1) {
                    Text(option.displayLabel)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .lineLimit(1)
                    if let reasoning = option.reasoning, !reasoning.isEmpty {
                        Text(reasoning)
                            .font(.system(size: 11.5, weight: .regular))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(viewIntent.dotColor)
            }
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(isPrimary ? viewIntent.chipBackground.opacity(0.45) : HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(isPrimary ? viewIntent.dotColor.opacity(0.35) : HomeDesign.Color.border, lineWidth: 1)
            )
        }
        .buttonStyle(PressableStyle())
    }
}

/// 보조 액션 — "다른 의도"(자연어 재분석 진입) / "다시 맡기기"(실패 항목 재시도).
private struct SecondaryActionButton: View {
    let icon: String
    let title: String
    var emphasized: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(emphasized ? HomeDesign.Color.purple50 : HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .stroke(emphasized ? HomeDesign.Color.purple200 : HomeDesign.Color.border, lineWidth: 1)
            )
            .foregroundStyle(emphasized ? HomeDesign.Color.purple600 : HomeDesign.Color.textMuted)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Analyzing card ("모찌가 분석 중이에요")

/// 분석 응답 대기 중인 항목 — 사용자 행동 불필요, 진행 표시만.
/// 화면을 압도하던 세로 캐러셀 대신 컴팩트한 행 리스트로 — 썸네일(44pt) + 제목 + 진행 바.
struct AnalyzingCard: View {
    let mochiItems: [MochiItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(mochiItems.enumerated()), id: \.element.id) { index, mochiItem in
                AnalyzingRow(mochiItem: mochiItem)
                if index < mochiItems.count - 1 {
                    Rectangle()
                        .fill(HomeDesign.Color.border)
                        .frame(height: 1)
                        .padding(.leading, HomeDesign.Spacing.lg + 44 + HomeDesign.Spacing.md)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
    }
}

private struct AnalyzingRow: View {
    let mochiItem: MochiItem

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            thumbnail
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(HomeDesign.Color.border, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(mochiItem.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: HomeDesign.Spacing.sm) {
                    AnalyzingProgressBar()
                        .frame(maxWidth: 120)
                    Text("분석 중")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.vertical, HomeDesign.Spacing.md)
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch mochiItem.viewKind {
        case .screenshot:
            LocalThumbnail(
                relativePath: mochiItem.source.imageRefs.first?.displayRelativePath,
                objectKey: mochiItem.source.imageRefs.first?.objectKey,
                sha256: mochiItem.source.imageRefs.first?.sha256,
                mimeType: mochiItem.source.imageRefs.first?.mimeType,
                targetSize: CGSize(width: 44, height: 44)
            ) {
                Rectangle().fill(HomeDesign.Color.purple100)
            }
        case .memo:
            ZStack {
                Rectangle().fill(HomeDesign.Color.butter50)
                Image(systemName: "doc.text")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.8))
            }
        case .url:
            ZStack {
                Rectangle().fill(HomeDesign.Color.purple50)
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600.opacity(0.75))
            }
        }
    }
}

/// 보라 하이라이트가 좌→우로 흐르는 indeterminate 진행 바 — "모찌가 일하는 중" 신호.
private struct AnalyzingProgressBar: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(HomeDesign.Color.ink100.opacity(0.6))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple200],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: proxy.size.width * 0.38)
                    .offset(x: proxy.size.width * phase)
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1.0
            }
        }
    }
}

// MochiItemKindTag 는 DesignSystem 으로 승격됨 (HomeViewMapping.swift).
