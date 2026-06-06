import SwiftUI
import ComposableArchitecture
import CoreDomain
import DesignSystem

/// 기록 상세 화면 — "검수"가 아니라 "회수".
///
/// 정보 위계: ① 회수 헤더(썸네일·정체성 제목·출처·시간) → (헷갈려요 배너) →
/// ② 지금 할 수 있어요(할일 체크 / 일정 통지 / 링크) → ③ 모찌가 정리했어요(요약·원본) →
/// ④ 더 자세히(추출정보·태그·근거). 제목은 탭 한 번으로 인라인 교정(로컬 `userTitle` 오버라이드).
public struct DetailView: View {
    @Bindable public var store: StoreOf<DetailFeature>

    public init(store: StoreOf<DetailFeature>) { self.store = store }

    public var body: some View {
        ScrollView {
            Group {
                if let mochiItem = store.mochiItem {
                    if mochiItem.analysis != nil {
                        analyzedContent(mochiItem)
                    } else if case .failed = mochiItem.lifecycleState {
                        DetailStateView.failed
                    } else {
                        DetailStateView.processing(mochiItem)
                    }
                } else {
                    DetailStateView.loading
                }
            }
            .padding(HomeDesign.Spacing.lg)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .navigationTitle("기록 상세")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private func analyzedContent(_ mochiItem: MochiItem) -> some View {
        if let analysis = mochiItem.analysis {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                RecallHeader(store: store, mochiItem: mochiItem)

                if mochiItem.needsReview {
                    NeedsReviewBanner()
                }

                IntentActionsSection(mochiItem: mochiItem, analysis: analysis) { instanceID, reason in
                    store.send(.archiveTapped(instanceID: instanceID, reason: reason))
                }

                GistCard(mochiItem: mochiItem, analysis: analysis)
                DetailsDisclosure(mochiItem: mochiItem, analysis: analysis)

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(HomeDesign.Color.blush400)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ① 회수 헤더 (썸네일 · 정체성 제목 · 출처·시간)

private struct RecallHeader: View {
    @Bindable var store: StoreOf<DetailFeature>
    let mochiItem: MochiItem
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            if let path = mochiItem.source.imageRefs.first?.relativePath {
                LocalThumbnail(
                    relativePath: path,
                    targetSize: CGSize(width: 320, height: 480),
                    preservesAspectRatio: true
                ) {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous))
            }

            titleView

            Text(mochiItem.displaySubtitle)
                .font(.system(size: 12))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .detailCard()
    }

    /// 비편집: 제목 + 연필 힌트(탭 → 편집). 편집: 인라인 TextField + 취소/완료.
    @ViewBuilder
    private var titleView: some View {
        if store.isEditingTitle {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                TextField("제목을 입력하세요", text: $store.titleDraft.sending(\.titleDraftChanged), axis: .vertical)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1...3)
                    .focused($titleFocused)
                    .submitLabel(.done)
                    .onSubmit { store.send(.titleCommitted) }
                    .padding(HomeDesign.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                            .fill(HomeDesign.Color.cream100)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                            .stroke(HomeDesign.Color.border, lineWidth: 1)
                    )
                HStack(spacing: HomeDesign.Spacing.lg) {
                    Spacer()
                    Button("취소") { store.send(.titleEditCancelled) }
                        .font(.system(size: 13))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    Button("완료") { store.send(.titleCommitted) }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.purple600)
                }
            }
            .onAppear { titleFocused = true }
        } else {
            Button { store.send(.titleTapped) } label: {
                HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
                    Text(mochiItem.displayHeadline ?? "제목을 더해 주세요")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(mochiItem.displayHeadline == nil ? HomeDesign.Color.textFaint : HomeDesign.Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "pencil")
                        .font(.system(size: 12))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                        .padding(.top, 6)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 헷갈려요 배너

private struct NeedsReviewBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(HomeDesign.Color.butter400)
            Text("모찌가 아직 분류를 확신하지 못했어요. 홈의 ‘헷갈려요’에서 알려주면 다시 살펴볼게요.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(HomeDesign.Color.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.cream200)
        )
    }
}

// MARK: - ② 지금 할 수 있어요 (할일 체크 · 일정 통지 · 링크)

private struct IntentActionsSection: View {
    let mochiItem: MochiItem
    let analysis: MochiItemAnalysis
    let onArchive: (UUID, InstanceLifecycle.ArchiveReason) -> Void
    @Environment(\.openURL) private var openURL

    private var activeTodos: [IntentInstance] {
        mochiItem.instances.filter { $0.intentType == .todo && $0.lifecycle == .active }
    }
    /// 확신할 때만 "넣어뒀어요" 통지 — 미확신(needsReview)이면 헷갈려요 배너가 담당.
    private var hasConfirmedSchedule: Bool {
        !mochiItem.needsReview && mochiItem.instances.contains { $0.intentType == .schedule && $0.lifecycle == .active }
    }
    private var primaryURL: URL? {
        if let url = mochiItem.source.url { return url }
        // 분석이 화면(스크린샷)에서 그라운딩한 원본 소스 URL — payload.url (platformContext/webFetch 경유).
        for inst in mochiItem.instances {
            if let raw = inst.payload.url, let url = URL(string: raw) { return url }
        }
        for candidate in analysis.actionCandidates {
            if case let .openURL(url) = candidate { return url }
        }
        return nil
    }
    private var hasAnyAction: Bool {
        !activeTodos.isEmpty || hasConfirmedSchedule || primaryURL != nil
    }

    var body: some View {
        if hasAnyAction {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                ForEach(activeTodos) { todo in
                    TodoCheckRow(instance: todo) { onArchive(todo.id, .todoCompleted) }
                }
                if hasConfirmedSchedule {
                    scheduleNotice
                }
                if let url = primaryURL {
                    linkButton(url)
                }
            }
            .detailCard()
        }
    }

    private var scheduleNotice: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "calendar")
                .font(.system(size: 13))
                .foregroundStyle(HomeDesign.Color.purple600)
            Text("일정으로 분류했어요 — 모찌들 탭에 담아뒀어요")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HomeDesign.Color.ink700)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.purple50)
        )
    }

    /// URL host 로 커뮤니티 플랫폼을 판별해 버튼 라벨을 정한다 — openURL 이 설치된 앱(YouTube 등)으로 라우팅.
    private func sourceLabel(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host.contains("youtu") { return "YouTube에서 보기" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter") { return "X에서 보기" }
        if host.contains("instagram") { return "Instagram에서 보기" }
        if host.contains("tiktok") { return "TikTok에서 보기" }
        return "원본에서 보기"
    }

    private func linkButton(_ url: URL) -> some View {
        Button { openURL(url) } label: {
            Label(sourceLabel(url), systemImage: "arrow.up.right.square")
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, HomeDesign.Spacing.md)
                .padding(.vertical, 11)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(HomeDesign.Color.purple500)
                )
                .foregroundStyle(Color.white)
        }
        .buttonStyle(PressableStyle())
    }
}

/// 할일 — 체크박스 한 번으로 완료 → archive(.todoCompleted). 마감은 정보 표시(액션 아님).
private struct TodoCheckRow: View {
    let instance: IntentInstance
    let onComplete: () -> Void

    var body: some View {
        Button(action: onComplete) {
            HStack(spacing: HomeDesign.Spacing.sm) {
                Image(systemName: "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.displayLabel)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let deadline = instance.payload.deadline {
                        Text("마감 \(deadline)")
                            .font(.system(size: 11))
                            .foregroundStyle(HomeDesign.Color.blush400)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - ③ 모찌가 정리했어요 (요약 + 원본)

private struct GistCard: View {
    let mochiItem: MochiItem
    let analysis: MochiItemAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "모찌가 정리했어요")
            Text(analysis.summary)
                .font(.system(size: 14))
                .foregroundStyle(HomeDesign.Color.ink700)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let text = mochiItem.source.text, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let memo = mochiItem.source.userMemo, !memo.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("내가 남긴 메모")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    Text(memo)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeDesign.Color.ink700)
                }
                .padding(HomeDesign.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(HomeDesign.Color.butter50)
                )
            }
        }
        .detailCard()
    }
}

// MARK: - ④ 더 자세히 (접힘)

private struct DetailsDisclosure: View {
    let mochiItem: MochiItem
    let analysis: MochiItemAnalysis
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                if !analysis.entities.isEmpty {
                    detailBlock("추출 정보") {
                        ForEach(analysis.entities, id: \.self) { entity in
                            HStack(spacing: 6) {
                                Text(entity.kind.rawValue)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(HomeDesign.Color.textMuted)
                                Text(entity.value)
                                    .font(.system(size: 12))
                                    .foregroundStyle(HomeDesign.Color.ink700)
                            }
                        }
                    }
                }
                if !analysis.tags.isEmpty {
                    detailBlock("태그") {
                        Text(analysis.tags.map { "#\($0)" }.joined(separator: "  "))
                            .font(.system(size: 12))
                            .foregroundStyle(HomeDesign.Color.purple600)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let reasons = mochiItem.instances.compactMap { $0.reasoning }.filter { !$0.isEmpty }
                if !reasons.isEmpty {
                    detailBlock("모찌의 근거") {
                        ForEach(Array(reasons.enumerated()), id: \.offset) { _, reason in
                            Text(reason)
                                .font(.system(size: 12))
                                .foregroundStyle(HomeDesign.Color.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                detailBlock("처리") {
                    Text("중요도 \(analysis.importance.rawValue)/5 · \(syncLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                }
            }
            .padding(.top, HomeDesign.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("더 자세히")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
        }
        .tint(HomeDesign.Color.textMuted)
        .detailCard()
    }

    @ViewBuilder
    private func detailBlock<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var syncLabel: String {
        switch mochiItem.syncState {
        case .pendingUpload:  return "동기화 대기"
        case .uploading:      return "업로드 중"
        case .uploaded:       return "저장됨"
        case .calendarSynced: return "캘린더 반영"
        case .reminderSynced: return "미리알림 반영"
        case .syncFailed:     return "동기화 실패"
        }
    }
}

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(HomeDesign.Color.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum DetailStateView {
    static var loading: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.top, 80)
    }

    @ViewBuilder
    static func processing(_ mochiItem: MochiItem) -> some View {
        VStack(spacing: HomeDesign.Spacing.lg) {
            if let path = mochiItem.source.imageRefs.first?.relativePath {
                LocalThumbnail(
                    relativePath: path,
                    targetSize: CGSize(width: 320, height: 480),
                    preservesAspectRatio: true
                ) {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                }
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous))
            }
            HStack(spacing: HomeDesign.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("모찌가 정리하고 있어요…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
        }
        .padding(.top, 40)
    }

    static var failed: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(HomeDesign.Color.peach400)
            Text("이번에는 정리하지 못했어요")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Text("잠시 후 모찌가 다시 시도할게요.")
                .font(.system(size: 12))
                .foregroundStyle(HomeDesign.Color.textMuted)
        }
        .padding(.top, 80)
    }
}

// MARK: - Card styling

private extension View {
    /// 상세 화면 공통 카드 — surface 배경 + 1pt border + soft shadow.
    func detailCard() -> some View {
        self
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
