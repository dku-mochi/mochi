import SwiftUI
import CoreDomain
import DesignSystem

/// "모찌가 헷갈려요" 카드 — 미분류 항목을 페이지로 넘기며 3개 분류 후보를 제시.
struct NeedsReviewCard: View {
    let mochiItems: [MochiItem]
    @Binding var page: Int
    let onClassify: (MochiItem.ID, Intent) -> Void
    let onReanalyze: (MochiItem.ID, String) -> Void
    let onRetry: (MochiItem.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            if mochiItems.isEmpty {
                emptyState
            } else {
                TabView(selection: $page) {
                    ForEach(Array(mochiItems.enumerated()), id: \.element.id) { idx, mochiItem in
                        AmbiguousBody(mochiItem: mochiItem, onClassify: onClassify, onReanalyze: onReanalyze, onRetry: onRetry)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 332)

                pager
            }
        }
        .padding(HomeDesign.Spacing.lg)
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

    private var emptyState: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle()
                    .fill(HomeDesign.Color.mint100)
                    .frame(width: 44, height: 44)
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.mint400)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("정리할 게 없어요")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("모찌가 다 분류했어요. 새 캡처를 기다리는 중.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pager: some View {
        HStack(spacing: 5) {
            ForEach(mochiItems.indices, id: \.self) { idx in
                Capsule()
                    .fill(idx == page ? HomeDesign.Color.purple500 : HomeDesign.Color.ink100)
                    .frame(width: idx == page ? 22 : 14, height: 4)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Body for one mochiItem

private struct AmbiguousBody: View {
    let mochiItem: MochiItem
    let onClassify: (MochiItem.ID, Intent) -> Void
    let onReanalyze: (MochiItem.ID, String) -> Void
    let onRetry: (MochiItem.ID) -> Void
    @State private var showsHintInput = false
    @State private var hintText = ""

    /// 미확정 후보 (API projection). 강등 항목·미영속 시 비어 있어 "다른 의도"만 노출된다.
    private var options: [ReviewOption] { mochiItem.analysis?.reviewOptions ?? [] }
    /// 분석 실패로 강등된 항목인가 — 명시 마커로 판별(멱등 replay 로 후보만 빈 정상 항목과 구분).
    private var isFailed: Bool { mochiItem.analysis?.isAnalysisFailed ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
                preview
                meta
            }

            Text(isFailed ? "모찌가 잘 모르겠어요" : "모찌는 이렇게 생각해요")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .padding(.top, 2)

            choices
        }
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

    @ViewBuilder
    private var preview: some View {
        let kind = mochiItem.viewKind
        ZStack {
            switch kind {
            case .screenshot:
                // 스크린샷은 대부분 세로(portrait) 비율 → 96×124 박스를 넘치는 부분은 상단 정렬로
                // 크롭(상태바·제목이 보이도록)하고, 프레임 안에서 잘라 헤드라인과 겹치지 않게 한다.
                LocalThumbnail(
                    relativePath: mochiItem.source.imageRefs.first?.relativePath,
                    targetSize: CGSize(width: 96, height: 192),
                    alignment: .top
                ) {
                    ZStack {
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [HomeDesign.Color.purple100, HomeDesign.Color.purple400.opacity(0.35)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "photo")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(HomeDesign.Color.purple600.opacity(0.6))
                    }
                }
                .frame(width: 96, height: 192)
                .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous))

            case .memo:
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(HomeDesign.Color.butter50)
                Image(systemName: "doc.text")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.7))

            case .url:
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(HomeDesign.Color.purple50)
                Image(systemName: "link")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600.opacity(0.7))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .frame(width: 96, height: 192)
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs) {
            MochiItemKindTag(kind: mochiItem.viewKind)

            Text(mochiItem.displayTitle)
                .font(.system(size: 14, weight: .bold))
                .tracking(-0.1)
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(mochiItem.displaySubtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 의견 있음: LLM 의견(최대 2개, label 우선) + "다른 의도".
    /// 의견 없음(분석 실패/강등): "다른 의도" + "모찌에게 다시 맡기기"(재시도).
    private var choices: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(Array(options.prefix(2).enumerated()), id: \.offset) { idx, option in
                    ChoiceChip(
                        text: option.displayLabel,
                        intent: option.intentType,
                        isPrimary: idx == 0
                    ) {
                        onClassify(mochiItem.id, option.intentType)
                    }
                }
                ManualPickChip { showsHintInput = true }
            }
            if isFailed {
                RetryChip { onRetry(mochiItem.id) }
            }
        }
    }
}

// MARK: - Choice chip

private struct ChoiceChip: View {
    let text: String
    let intent: Intent
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(MochiViewIntent(intent).dotColor)
                    .frame(width: 8, height: 8)
                Text(text)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(isPrimary ? HomeDesign.Color.purple50 : HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm)
                    .stroke(isPrimary ? HomeDesign.Color.purple200 : HomeDesign.Color.border, lineWidth: 1)
            )
            .foregroundStyle(isPrimary ? HomeDesign.Color.purple600 : HomeDesign.Color.textPrimary)
        }
        .buttonStyle(PressableStyle())
    }
}

/// "모찌에게 다시 맡기기" — 분석 실패/강등 항목을 다시 분석 큐로 돌린다.
private struct RetryChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                Text("모찌에게 다시 맡기기")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(HomeDesign.Color.purple50)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm)
                    .stroke(HomeDesign.Color.purple200, lineWidth: 1)
            )
            .foregroundStyle(HomeDesign.Color.purple600)
        }
        .buttonStyle(PressableStyle())
    }
}

/// "다른 의도" — 사용자가 의도를 자연어로 적어 모찌에게 재분석을 요청하는 진입점 (alert TextField → onReanalyze).
private struct ManualPickChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .bold))
                Text("다른 의도")
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.sm)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Analyzing card ("모찌가 분석 중이에요")

/// 분석 응답 대기 중인 항목 — 사용자 행동 불필요, 진행 표시만.
/// 가로 캐러셀로 미리보기를 크게 보여준다 (이미지가 카드 폭을 꽉 채우는 2:1).
struct AnalyzingCard: View {
    let mochiItems: [MochiItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ForEach(mochiItems) { mochiItem in
                    AnalyzingCardCell(mochiItem: mochiItem)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
        }
        .padding(.horizontal, -HomeDesign.Spacing.xl)
    }
}

private struct AnalyzingCardCell: View {
    let mochiItem: MochiItem

    /// 이미지가 카드 폭을 꽉 채우고 2:1(세로) 로 표시된다.
    private static let cardWidth: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(width: Self.cardWidth, height: Self.cardWidth * 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(mochiItem.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("모찌가 분석 중…")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            .padding(HomeDesign.Spacing.md)
            .frame(width: Self.cardWidth, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .cardShadow()
    }

    @ViewBuilder
    private var preview: some View {
        switch mochiItem.viewKind {
        case .screenshot:
            LocalThumbnail(
                relativePath: mochiItem.source.imageRefs.first?.relativePath,
                targetSize: CGSize(width: Self.cardWidth, height: Self.cardWidth * 2),
                alignment: .top
            ) {
                Rectangle().fill(HomeDesign.Color.purple100)
            }
        case .memo:
            ZStack {
                Rectangle().fill(HomeDesign.Color.butter50)
                Image(systemName: "doc.text")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.8))
            }
        case .url:
            ZStack {
                Rectangle().fill(HomeDesign.Color.purple50)
                Image(systemName: "link")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600.opacity(0.75))
            }
        }
    }
}

// MochiItemKindTag 는 DesignSystem 으로 승격됨 (HomeViewMapping.swift).
