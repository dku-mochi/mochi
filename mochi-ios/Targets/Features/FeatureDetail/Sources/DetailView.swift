import SwiftUI
import ComposableArchitecture
import CoreDomain
import CorePersistence
import DesignSystem
import ImageIO
import JXPhotoBrowser
import UIKit

/// 기록 상세 화면 — "검수"가 아니라 "회수".
///
/// 정보 위계: ① 회수 헤더(썸네일·정체성 제목·출처·시간) → (헷갈려요 배너) →
/// ② 지금 할 수 있어요(할일 체크 / 일정 통지 / 링크) → ③ 모찌가 정리했어요(요약·원본) →
/// ④ 더 자세히(추출정보·태그·근거). 제목은 탭 한 번으로 인라인 교정(로컬 `userTitle` 오버라이드).
public struct DetailView: View {
    @Bindable public var store: StoreOf<DetailFeature>
    @State private var presentationAnchor: UIViewController?
    @State private var photoBrowserPresenter: ScreenshotPhotoBrowserPresenter?
    @State private var sourceImageHidden = false

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
        .background(PresentationAnchor(viewController: $presentationAnchor).frame(width: 0, height: 0))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // custom present 라 back 이 없다 — 닫기(X)로 dismiss. 아래로 드래그해도 닫힌다.
                Button { store.send(.closeButtonTapped) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("삭제", role: .destructive) { store.send(.deleteButtonTapped) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                }
            }
        }
        .alert($store.scope(state: \.deleteAlert, action: \.deleteAlert))
        .task { store.send(.onAppear) }
    }

    @ViewBuilder
    private func analyzedContent(_ mochiItem: MochiItem) -> some View {
        if let analysis = mochiItem.analysis {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                RecallHeader(store: store, mochiItem: mochiItem, sourceImageHidden: sourceImageHidden) { image, imageView in
                    presentScreenshotBrowser(image: image, thumbnailView: imageView)
                }

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

    private func presentScreenshotBrowser(image: UIImage?, thumbnailView: UIImageView?) {
        guard let image, let presentationAnchor else { return }
        let presenter = ScreenshotPhotoBrowserPresenter(
            image: image,
            thumbnailView: thumbnailView
        ) { hidden in
            sourceImageHidden = hidden
        }
        photoBrowserPresenter = presenter
        presenter.present(from: presentationAnchor)
    }
}

// MARK: - ① 회수 헤더 (썸네일 · 정체성 제목 · 출처·시간)

private struct RecallHeader: View {
    @Bindable var store: StoreOf<DetailFeature>
    let mochiItem: MochiItem
    let sourceImageHidden: Bool
    /// 스크린샷 탭 → JXPhotoBrowser 확대. 인자는 로드된 이미지와 transition source UIImageView.
    let onTapImage: (UIImage?, UIImageView?) -> Void
    @StateObject private var previewHandle = ScreenshotImageViewHandle()
    @FocusState private var titleFocused: Bool

    var body: some View {
        // 이미지 카드 — 스크린샷은 카드 상단을 edge-to-edge 로 꽉 채우고(카드 clip 이 상단 모서리를
        // 둥글게 잘라줌), 제목·출처만 하단 padding. 단일 요소(이미지)를 안쪽 카드로 또 감싸지 않는다.
        VStack(alignment: .leading, spacing: 0) {
            if let path = mochiItem.source.imageRefs.first?.relativePath {
                ScreenshotPreviewImage(
                    relativePath: path,
                    targetSize: CGSize(width: 320, height: 240),
                    contentMode: .scaleAspectFill,
                    handle: previewHandle
                )
                // 카드 미디어와 같은 4:3·중앙 크롭으로 통일 — hero cross-fade 시 같은 이미지가
                // 다른 비율로 튀지 않게 한다(카드: 178×134). 전체 보기는 탭 시 JXPhotoBrowser.
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Rectangle().fill(HomeDesign.Color.purple50))
                // 하단 페이드 — 이미지가 카드 본문(surface)으로 부드럽게 녹아들게 한다. 밝은 배경
                // 스크린샷(Safari·노션 등)이 흰 카드와 섞여 경계가 깨지던 edge-bleed 도 흰색으로 수렴시켜 해소.
                .overlay(alignment: .bottom) {
                    LinearGradient(
                        colors: [HomeDesign.Color.surface.opacity(0), HomeDesign.Color.surface],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 56)
                    .allowsHitTesting(false)
                }
                // 좌상단 '캡처' 배지 — 캡처한 다른 앱 화면(YouTube 등)을 라이브 화면으로 오인하지
                // 않도록 '저장된 캡처'임을 명시한다.
                .overlay(alignment: .topLeading) {
                    captureBadge
                        .padding(HomeDesign.Spacing.sm)
                        .allowsHitTesting(false)
                }
                // 탭 → JXPhotoBrowser 확대. 배지·페이드는 hit-test 제외라 이미지 전체가 탭된다.
                // hero 전환 중에는 비행 스냅샷과 겹치지 않도록 숨긴다(App 이 비행 끝에 켬).
                .opacity((sourceImageHidden || store.heroImageHidden) ? 0 : 1)
                .animation(.easeInOut(duration: 0.22), value: store.heroImageHidden)
                .contentShape(Rectangle())
                .onTapGesture { onTapImage(previewHandle.image, previewHandle.imageView) }
            }

            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                titleView

                Text(mochiItem.displaySubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HomeDesign.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        .cardShadow()
    }

    /// '캡처' 배지 — viewfinder 아이콘 + "캡처". 이미지 위에 떠야 하므로 반투명 다크 칩 + 흰 글자로
    /// 밝은/어두운 스크린샷 어디서든 읽히게 한다(iOS 사진앱 오버레이 칩 컨벤션).
    private var captureBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "viewfinder")
                .font(.system(size: 10, weight: .bold))
            Text("캡처")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
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
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                // 할 일(체크 리스트)만 흰 카드로 묶는다 — 여러 행이 한 덩어리로 읽혀야 하므로.
                if !activeTodos.isEmpty {
                    VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                        ForEach(activeTodos) { todo in
                            TodoCheckRow(instance: todo) { onArchive(todo.id, .todoCompleted) }
                        }
                    }
                    .detailCard()
                }
                // 일정 통지·링크 버튼은 그 자체가 완결된 박스/버튼 — 흰 카드로 또 감싸지 않고
                // 배경 위 독립 요소로 둔다.
                if hasConfirmedSchedule {
                    scheduleNotice
                }
                if let url = primaryURL {
                    linkButton(url)
                }
            }
        }
    }

    private var scheduleNotice: some View {
        HStack(spacing: HomeDesign.Spacing.sm) {
            Image(systemName: "calendar")
                .font(.system(size: 13))
                .foregroundStyle(HomeDesign.Color.purple600)
            Text("일정으로 분류했어요 — 캘린더 탭에 담아뒀어요")
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
                    targetSize: CGSize(width: 320, height: 320),
                    alignment: .top
                ) {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                }
                .aspectRatio(1, contentMode: .fit)
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

// MARK: - JXPhotoBrowser bridge

private final class ScreenshotPhotoBrowserPresenter: NSObject, JXPhotoBrowserDelegate {
    private let image: UIImage
    private weak var thumbnailView: UIImageView?
    private let setThumbnailHidden: (Bool) -> Void

    init(image: UIImage, thumbnailView: UIImageView?, setThumbnailHidden: @escaping (Bool) -> Void) {
        self.image = image
        self.thumbnailView = thumbnailView
        self.setThumbnailHidden = setThumbnailHidden
    }

    func present(from viewController: UIViewController) {
        let browser = JXPhotoBrowserViewController()
        browser.delegate = self
        browser.initialIndex = 0
        browser.isLoopingEnabled = false
        browser.transitionType = thumbnailView == nil ? .fade : .zoom
        browser.present(from: viewController)
    }

    func numberOfItems(in browser: JXPhotoBrowserViewController) -> Int {
        1
    }

    func photoBrowser(_ browser: JXPhotoBrowserViewController, cellForItemAt index: Int, at indexPath: IndexPath) -> JXPhotoBrowserAnyCell {
        browser.dequeueReusableCell(withReuseIdentifier: JXZoomImageCell.reuseIdentifier, for: indexPath)
    }

    func photoBrowser(_ browser: JXPhotoBrowserViewController, willDisplay cell: JXPhotoBrowserAnyCell, at index: Int) {
        guard let photoCell = cell as? JXZoomImageCell else { return }
        photoCell.imageView.image = image
        photoCell.imageView.contentMode = .scaleAspectFill
        photoCell.setNeedsLayout()
    }

    func photoBrowser(_ browser: JXPhotoBrowserViewController, thumbnailViewAt index: Int) -> UIView? {
        thumbnailView
    }

    func photoBrowser(_ browser: JXPhotoBrowserViewController, setThumbnailHidden hidden: Bool, at index: Int) {
        thumbnailView?.isHidden = hidden
        setThumbnailHidden(hidden)
    }
}

private struct PresentationAnchor: UIViewControllerRepresentable {
    @Binding var viewController: UIViewController?

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard viewController !== uiViewController else { return }
        DispatchQueue.main.async {
            viewController = uiViewController
        }
    }
}

@MainActor
private final class ScreenshotImageViewHandle: ObservableObject {
    weak var imageView: UIImageView?
    var image: UIImage?
}

private struct ScreenshotPreviewImage: View {
    let relativePath: String
    let targetSize: CGSize
    let contentMode: UIView.ContentMode
    @ObservedObject var handle: ScreenshotImageViewHandle
    @State private var image: UIImage?

    var body: some View {
        UIKitImageView(image: image, contentMode: contentMode, handle: handle)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .task(id: relativePath) {
                let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
                image = await loadDownsampledDetailImage(relativePath: relativePath, maxPixel: maxPixel)
            }
    }
}

private struct UIKitImageView: UIViewRepresentable {
    let image: UIImage?
    let contentMode: UIView.ContentMode
    let handle: ScreenshotImageViewHandle

    func makeUIView(context: Context) -> UIImageView {
        let imageView = LayoutNeutralImageView()
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.contentMode = contentMode
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        handle.imageView = imageView
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.image = image
        imageView.contentMode = contentMode
        handle.image = image
        handle.imageView = imageView
    }
}

private final class LayoutNeutralImageView: UIImageView {
    override var intrinsicContentSize: CGSize {
        .zero
    }
}

private struct LoadedDetailImage: @unchecked Sendable {
    let image: UIImage
}

private func loadDownsampledDetailImage(relativePath: String, maxPixel: Int) async -> UIImage? {
    let url = AppGroup.containerURL.appendingPathComponent(relativePath)
    let loaded = await Task.detached(priority: .userInitiated) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as LoadedDetailImage? }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil as LoadedDetailImage?
        }
        return LoadedDetailImage(image: UIImage(cgImage: cgImage))
    }.value
    return loaded?.image
}

// MARK: - Card styling

private extension View {
    /// 상세 화면 공통 카드 — surface 배경 + soft shadow. F2F4F7 배경 위에서 shadow 만으로 분리되므로
    /// border 는 두지 않는다(중첩 카드 시 테두리 무게 제거).
    func detailCard() -> some View {
        self
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .cardShadow()
    }
}
