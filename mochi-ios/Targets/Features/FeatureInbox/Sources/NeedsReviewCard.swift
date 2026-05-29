import SwiftUI
import CoreDomain

/// "모찌가 헷갈려요" 카드 — 미분류 항목을 페이지로 넘기며 3개 분류 후보를 제시.
struct NeedsReviewCard: View {
    let mochiItems: [MochiItem]
    @Binding var page: Int
    let onClassify: (MochiItem.ID, Intent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            if mochiItems.isEmpty {
                emptyState
            } else {
                TabView(selection: $page) {
                    ForEach(Array(mochiItems.enumerated()), id: \.element.id) { idx, mochiItem in
                        AmbiguousBody(mochiItem: mochiItem, onClassify: onClassify)
                            .tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 240)

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

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
                preview
                meta
            }

            Text("어디로 정리할까요?")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .padding(.top, 2)

            choices
        }
    }

    @ViewBuilder
    private var preview: some View {
        let kind = mochiItem.viewKind
        ZStack {
            switch kind {
            case .screenshot:
                LocalThumbnail(
                    relativePath: mochiItem.source.imageRefs.first?.relativePath,
                    targetSize: CGSize(width: 96, height: 124)
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
        .frame(width: 96, height: 124)
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

    private var choices: some View {
        let (primary, others) = mochiItem.classificationChoices
        return HStack(spacing: HomeDesign.Spacing.sm) {
            ChoiceChip(intent: primary, isPrimary: true) {
                onClassify(mochiItem.id, primary.domain)
            }
            ForEach(others) { intent in
                ChoiceChip(intent: intent, isPrimary: false) {
                    onClassify(mochiItem.id, intent.domain)
                }
            }
        }
    }
}

// MARK: - Choice chip

private struct ChoiceChip: View {
    let intent: MochiViewIntent
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(intent.dotColor)
                    .frame(width: 8, height: 8)
                Text(intent.label)
                    .font(.system(size: 12.5, weight: .semibold))
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

// MARK: - MochiItem kind tag

struct MochiItemKindTag: View {
    let kind: MochiItemKind

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: kind.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(kind.label)
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.05)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(kind.tint)
        .background(
            Capsule().fill(kind.background)
        )
        .overlay(
            Capsule().stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }
}
