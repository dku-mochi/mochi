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
/// ② 지금 할 수 있어요(할일 체크 / 일정 통지 / 링크) → ③ 모찌가 정리했어요(요약·원본).
/// 제목은 탭 한 번으로 인라인 교정(로컬 `userTitle` 오버라이드).
/// ("더 자세히" 접힘 섹션은 2026-06-10 제거 — 추출정보·태그·근거는 회수에 기여하지 않는 내부 디테일.)
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
                    toolbarIcon("xmark")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("삭제", role: .destructive) { store.send(.deleteButtonTapped) }
                } label: {
                    toolbarIcon("ellipsis")
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

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(HomeDesign.Color.blush400)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 원형 칩 toolbar 버튼 — bg(F2F4F7) 위에서도, 드래그 중 dim 이 비칠 때도 또렷한 모달 어포던스.
    private func toolbarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(HomeDesign.Color.textPrimary)
            .frame(width: 30, height: 30)
            .background(Circle().fill(HomeDesign.Color.surface))
            .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
            .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 6, x: 0, y: 2)
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
                // 다른 비율로 튀지 않게 한다(카드: 178×134). 비율은 ScreenshotPreviewImage 가 직접
                // 잡는다(targetSize 4:3). 전체 보기는 탭 시 JXPhotoBrowser.
                .frame(maxWidth: .infinity)
                .background(Rectangle().fill(HomeDesign.Color.purple50))
                // 하단 페이드 — 이미지가 카드 본문(surface)으로 부드럽게 녹아들게 한다. 밝은 배경
                // 스크린샷(Safari·노션 등)이 흰 카드와 섞여 경계가 깨지던 edge-bleed 도 흰색으로 수렴시켜 해소.
                // 좌상단 '캡처' 배지 — 캡처한 다른 앱 화면(YouTube 등)을 라이브 화면으로 오인하지
                // 않도록 '저장된 캡처'임을 명시한다.
                .overlay(alignment: .topLeading) {
                    captureBadge
                        .padding(HomeDesign.Spacing.sm)
                        .allowsHitTesting(false)
                }
                // 탭 → JXPhotoBrowser 확대. 배지·페이드는 hit-test 제외라 이미지 전체가 탭된다.
                // hero 전환 중에는 비행 스냅샷과 겹치지 않도록 숨긴다(App 이 비행 끝에 켬).
                // reveal 은 **즉시**(애니메이션 없음) — 비행 스냅샷이 위를 덮은 채 그 밑에서 켜지므로
                // 보이지 않고, 동일 이미지를 crossfade 하면 합성 불투명도가 1 아래로 꺼져 깜박인다.
                .opacity((sourceImageHidden || store.heroImageHidden) ? 0 : 1)
                .contentShape(Rectangle())
                .onTapGesture { onTapImage(previewHandle.image, previewHandle.imageView) }
            }

            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                titleView

                // 출처·시간 메타데이터 — 종류 아이콘과 함께 한 줄.
                HStack(spacing: 5) {
                    Image(systemName: mochiItem.viewKind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                    Text(mochiItem.displaySubtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
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
                    .font(.system(size: 21, weight: .bold, design: .rounded))
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
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(mochiItem.displayHeadline == nil ? HomeDesign.Color.textFaint : HomeDesign.Color.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 편집 어포던스 — 맨글자 연필보다 칩이 "탭 가능"으로 읽힌다.
                    ZStack {
                        Circle().fill(HomeDesign.Color.bg)
                        Image(systemName: "pencil")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
                    .frame(width: 26, height: 26)
                    .padding(.top, 2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 헷갈려요 배너

private struct NeedsReviewBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.butter100)
                Image(systemName: "questionmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(HomeDesign.Color.butter400)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("모찌가 분류를 확신하지 못했어요")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                // 홈 카피("지금 확인해 주세요")와 같은 표현을 쓴다 — 없는 화면명('헷갈려요') 금지.
                Text("홈의 '확인해 주세요'에서 알려주면 다시 살펴볼게요.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.ink700)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.cream100)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.cream200, lineWidth: 1)
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
    private var activeSchedules: [IntentInstance] {
        mochiItem.instances.filter { $0.intentType == .schedule && $0.lifecycle == .active }
    }
    /// 확신할 때만 "넣어뒀어요" 통지 — 미확신(needsReview)이면 헷갈려요 배너가 담당.
    private var hasConfirmedSchedule: Bool {
        !mochiItem.needsReview && !activeSchedules.isEmpty
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

    /// 일정 통지 — 일시가 핵심 정보라 날짜를 헤드라인으로 올린다(한 캡처에 일정 여럿이면 행 반복).
    private var scheduleNotice: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            ForEach(activeSchedules) { instance in
                HStack(spacing: HomeDesign.Spacing.md) {
                    ZStack {
                        Circle().fill(HomeDesign.Color.purple100)
                        Image(systemName: "calendar")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.purple600)
                    }
                    .frame(width: 26, height: 26)
                    if let when = Self.scheduleWhen(instance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(when)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textPrimary)
                            Text("일정으로 분류했어요 — 캘린더 탭에 담아뒀어요")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.ink700)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("일정으로 분류했어요 — 캘린더 탭에 담아뒀어요")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.ink700)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(HomeDesign.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.purple50)
        )
    }

    /// 일정 일시 표기 — `payload.date`(+`time`)를 `PayloadDate`(단일 원천)로 파싱해
    /// 캘린더 탭과 같은 한국어·KST 로 보여준다. 파싱 불가(자연어 표기)면 원문 그대로 —
    /// 날짜가 아예 안 보이는 것보다 낫다. 일시 자체가 없으면 nil(기존 한 줄 통지 유지).
    /// 기간 일정(`endDate`)은 "시작 ~ 끝" 으로 표기한다 — 역전(끝<시작)·파싱 불가 end 는
    /// 점 일정으로 수렴해 시작만 표기(캘린더 `CalendarDueDate.scheduleEnd`·EK 등록과 동일 가드).
    private static func scheduleWhen(_ instance: IntentInstance) -> String? {
        let payload = instance.payload
        guard let startLabel = formatted(date: payload.date, time: payload.time) else { return nil }
        guard let start = parsed(date: payload.date, time: payload.time),
              let end = parsed(date: payload.endDate, time: payload.endTime),
              end > start,
              let endLabel = formatted(date: payload.endDate, time: payload.endTime)
        else { return startLabel }
        return "\(startLabel) ~ \(endLabel)"
    }

    /// date 가 날짜만(yyyy-MM-dd, 10자)이고 time 이 따로 오면 합쳐 파싱한다.
    private static func parsed(date rawDate: String?, time: String?) -> Date? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        let raw: String = {
            if let time, !time.isEmpty, rawDate.count <= 10 {
                return "\(rawDate) \(time)"
            }
            return rawDate
        }()
        return PayloadDate.parse(raw) ?? PayloadDate.parse(rawDate)
    }

    /// date(+time) 문자열 한 쌍을 표기 문자열로 — 파싱 불가면 원문, date 없으면 nil.
    private static func formatted(date rawDate: String?, time: String?) -> String? {
        guard let rawDate, !rawDate.isEmpty else { return nil }
        let raw: String = {
            if let time, !time.isEmpty, rawDate.count <= 10 {
                return "\(rawDate) \(time)"
            }
            return rawDate
        }()
        guard let date = PayloadDate.parse(raw) ?? PayloadDate.parse(rawDate) else { return rawDate }
        let hasTime = PayloadDate.parse(raw) != nil ? raw.count > 10 : rawDate.count > 10
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
        formatter.dateFormat = hasTime ? "M월 d일 (E) a h:mm" : "M월 d일 (E)"
        return formatter.string(from: date)
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
            HStack(spacing: HomeDesign.Spacing.sm) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .bold))
                Text(sourceLabel(url))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                // 원본으로 가는 1차 행동 — 홈 FAB 과 같은 브랜드 그라데이션 CTA.
                    .fill(
                        LinearGradient(
                            colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .foregroundStyle(Color.white)
            .shadow(color: HomeDesign.Color.purple500.opacity(0.28), radius: 10, x: 0, y: 6)
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
            HStack(spacing: HomeDesign.Spacing.md) {
                Circle()
                    .strokeBorder(HomeDesign.Color.purple200, lineWidth: 2)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(instance.displayLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .multilineTextAlignment(.leading)
                    if let deadline = instance.payload.deadline {
                        HStack(spacing: 3) {
                            Image(systemName: "clock")
                                .font(.system(size: 9, weight: .semibold))
                            Text("마감 \(deadline)")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(HomeDesign.Color.blush400)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(instance.displayLabel) 완료하기")
    }
}

// MARK: - ③ 모찌가 정리했어요 (요약 + 원본)

private struct GistCard: View {
    let mochiItem: MochiItem
    let analysis: MochiItemAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "모찌가 정리했어요", icon: "sparkles")
            Text(analysis.summary)
                .font(.system(size: 14.5))
                .foregroundStyle(HomeDesign.Color.ink700)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let text = mochiItem.source.text, !text.isEmpty {
                // 원본 텍스트 — 인용 바로 요약과 위계를 가른다.
                HStack(alignment: .top, spacing: HomeDesign.Spacing.sm) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HomeDesign.Color.purple200)
                        .frame(width: 3)
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                        .lineSpacing(3)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let memo = mochiItem.source.userMemo, !memo.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: 10, weight: .semibold))
                        Text("내가 남긴 메모")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(HomeDesign.Color.butter400)
                    Text(memo)
                        .font(.system(size: 13))
                        .foregroundStyle(HomeDesign.Color.ink700)
                        .lineSpacing(3)
                }
                .padding(HomeDesign.Spacing.md)
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

// MARK: - Shared bits

private struct SectionHeader: View {
    let title: String
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.purple500)
            }
            Text(title)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
        }
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
                    targetSize: CGSize(width: 320, height: 240),
                    alignment: .top
                ) {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                }
                // 분석 완료 후 헤더와 같은 4:3 — 분석이 끝나도 이미지가 튀지 않는다.
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
                .cardShadow()
            }
            HStack(spacing: HomeDesign.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("모찌가 정리하고 있어요…")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
        }
        .padding(.top, HomeDesign.Spacing.sm)
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
        // 비율 박스(4:3)를 Layout 으로 직접 계산한다 — `aspectRatio(_:contentMode:)` 는 ScrollView 의
        // nil 높이 제안을 자식(이미지뷰)의 ideal 크기로 메우는 협상이 끼어들어, 원본이 작은 캡처에서
        // 박스가 이미지 크기로 쪼그라들고 양옆에 배경이 비쳤다. FixedRatioBox 는 "제안된 너비 ÷ 비율
        // = 높이"만 답하므로 이미지 크기가 레이아웃에 개입할 경로가 없다.
        FixedRatioBox(ratio: targetSize.width / targetSize.height, fallbackWidth: targetSize.width) {
            UIKitImageView(image: image, contentMode: contentMode, handle: handle)
        }
        .clipped()
        .task(id: relativePath) {
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            image = await loadDownsampledDetailImage(relativePath: relativePath, maxPixel: maxPixel)
        }
    }
}

/// 제안된 너비에서 고정 비율로 높이를 직접 계산하는 박스. 자식에게는 박스 크기를 그대로 제안해
/// 꽉 채우게 한다 — 자식의 ideal/원본 크기는 박스 크기에 전혀 영향을 주지 못한다.
private struct FixedRatioBox: Layout {
    let ratio: CGFloat
    /// 너비 제안이 없을 때(ideal 질의)의 기준 너비.
    let fallbackWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = proposal.width ?? fallbackWidth
        if !width.isFinite { width = fallbackWidth }
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(
                at: CGPoint(x: bounds.midX, y: bounds.midY),
                anchor: .center,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
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

    /// 이미지 원본 비율과 무관하게 SwiftUI 가 제안한 영역을 그대로 채운다.
    /// 비율은 바깥 `FixedRatioBox` 가 잡으므로, 이 뷰는 그 박스를 꽉 채워(aspectFill+clip)
    /// 양옆 여백 없이 렌더한다. 미구현 시 representable 이 이미지 크기로 협상해 박스를 못 채운다.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
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
