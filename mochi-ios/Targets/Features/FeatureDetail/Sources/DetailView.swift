import SwiftUI
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import CorePersistence
import DesignSystem
import ImageIO
import JXPhotoBrowser
import UIKit

/// 기록 상세 화면 — "검수"가 아니라 "회수".
///
/// 정보 위계(UX_SPEC §3.8 과 같은 번호): ① 회수 헤더(썸네일 · 출처·시간 eyebrow · 정체성 제목) →
/// ② 헷갈려요 배너(조건) → ③ 지금 할 수 있어요(할일 체크 / 일정 / 링크 — 전부 같은 행 문법) →
/// ④ 모찌가 정리했어요(요약·원본).
/// **어떤 intent·source 조합이든 골격이 같다** — eyebrow 가 항상 첫 텍스트 줄이고, 섹션 라벨이
/// 카드 밖에 노출되며, ③ 의 행들은 leading 타일·제목·부제의 단일 문법을 공유한다(2026-06-11 통일).
/// 제목은 탭 한 번으로 인라인 교정(로컬 `userTitle` 오버라이드).
/// ("더 자세히" 접힘 섹션은 2026-06-10 제거 — 추출정보·태그·근거는 회수에 기여하지 않는 내부 디테일.)
public struct DetailView: View {
    @Bindable public var store: StoreOf<DetailFeature>
    @State private var presentationAnchor: UIViewController?
    @State private var photoBrowserPresenter: ScreenshotPhotoBrowserPresenter?
    @State private var sourceImageHidden = false
    /// 헤더 아래 섹션들의 시차 등장 트리거 — hero 비행(0.55s)과 겹쳐 콘텐츠가 차오르는 인상.
    /// 헤더는 비행 착지 지점이라 제외(움직이면 `detailImageFrame` 예측이 깨진다).
    @State private var sectionsAppeared = false

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

                // 배너가 없으면 index 를 0 부터 당긴다 — 첫 가시 섹션 앞의 빈 선딜레이 방지
                // (홈/주간 정리의 분기별 index 재사용 패턴과 동일).
                let bump = mochiItem.needsReview ? 1 : 0
                if mochiItem.needsReview {
                    NeedsReviewBanner()
                        .riseIn(sectionsAppeared, index: 0)
                }

                IntentActionsSection(mochiItem: mochiItem, analysis: analysis) { instance in
                    store.send(.todoToggled(instance))
                }
                .riseIn(sectionsAppeared, index: bump)

                // 관련 링크(Agent ResourceFinder) — 3종 카드 비교용. 결정 후 승자만 ② 섹션에 합친다.
                let ref = analysis.referenceLinks.isEmpty ? 0 : 1
                if !analysis.referenceLinks.isEmpty {
                    ReferenceLinksComparison(links: analysis.referenceLinks)
                        .riseIn(sectionsAppeared, index: bump + 1)
                }

                GistCard(mochiItem: mochiItem, analysis: analysis)
                    .riseIn(sectionsAppeared, index: bump + ref + 1)

                // ⑤ 비슷한 기록 — 결과 없으면(임계값 미달·미색인) 섹션 자체를 렌더하지 않는다.
                if !store.similar.isEmpty {
                    SimilarSection(items: store.similar) { preview in
                        store.send(.similarItemTapped(preview.id))
                    }
                    .riseIn(sectionsAppeared, index: bump + ref + 2)
                }

                if let error = store.lastError {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(HomeDesign.Color.blush400)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear { sectionsAppeared = true }
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
                    handle: previewHandle
                )
                // 카드 미디어와 같은 4:3 프레임 + 같은 렌더 정책(세로=fill 크롭 / 가로=fit+블러)으로
                // 통일 — hero cross-fade 시 같은 이미지가 다른 모양으로 튀지 않게 한다(카드: 178×134).
                // 비율·정책은 ScreenshotPreviewImage 가 직접 잡는다. 전체 보기는 탭 시 JXPhotoBrowser.
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

            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                // 출처·시간 eyebrow — 제목 **위**에 둔다. 썸네일이 없는 기록(메모·URL)도
                // 첫 텍스트 줄이 항상 같아, 어떤 조합을 열어도 "기록 상세"로 즉시 읽힌다.
                HStack(spacing: 5) {
                    Image(systemName: mochiItem.viewKind.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textFaint)
                    Text(mochiItem.displaySubtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }

                titleView
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
                    // 여러 줄로 감기는 긴 제목도 잘리지 않고 보이게 — 리턴 키는 reducer 가 커밋으로 처리.
                    .lineLimit(1...5)
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
    let onToggle: (IntentInstance) -> Void
    @Environment(\.openURL) private var openURL

    /// 캘린더 탭과 같은 정렬 — 미완료(마감 임박순) 위, 완료(strikethrough)는 아래에 남긴다.
    private var todoRows: [IntentInstance] {
        mochiItem.instances
            .filter { $0.intentType == .todo }
            .sorted { lhs, rhs in
                let lDone = lhs.lifecycle.kind == .archived
                let rDone = rhs.lifecycle.kind == .archived
                if lDone != rDone { return !lDone }
                switch (DetailTodoRow.deadline(of: lhs), DetailTodoRow.deadline(of: rhs)) {
                case let (l?, r?): return l < r
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return lhs.id.uuidString < rhs.id.uuidString  // 안정 정렬
                }
            }
    }
    private var activeSchedules: [IntentInstance] {
        mochiItem.instances.filter { $0.intentType == .schedule && $0.lifecycle == .active }
    }
    /// 확신할 때만 보여준다 — 미확신(needsReview)이면 헷갈려요 배너가 담당.
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
        !todoRows.isEmpty || hasConfirmedSchedule || primaryURL != nil
            || analysis.shoppingProductQuery != nil
    }
    var body: some View {
        if hasAnyAction {
            // 섹션 라벨을 카드 밖에 노출해 화면 골격(③행동 → ④정리)이 한눈에 읽히게 한다.
            // 할 일·일정·링크 행은 캘린더 탭과 같은 시각 언어 — 행마다 독립된 흰 카드(surface+border).
            // 아이콘은 의도 중립 bolt — 체크는 할 일 전용 시각 언어라, 링크만 있는 기록에서도
            // 어긋나지 않는 "지금 가능한 행동" 기호로 고정한다.
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                SectionHeader(title: "지금 할 수 있어요", icon: "bolt.fill")
                    .padding(.horizontal, HomeDesign.Spacing.xs)
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                    ForEach(todoRows) { todo in
                        DetailTodoRow(instance: todo) { onToggle(todo) }
                    }
                    if hasConfirmedSchedule {
                        ForEach(activeSchedules) { schedule in
                            DetailScheduleRow(instance: schedule)
                        }
                    }
                    if let url = primaryURL {
                        DetailLinkRow(url: url, label: sourceLabel(url)) { openURL(url) }
                    }
                    if let query = analysis.shoppingProductQuery {
                        ForEach(ShoppingSearchProvider.allCases) { provider in
                            if let url = provider.searchURL(for: query) {
                                DetailLinkRow(
                                    url: url,
                                    label: provider.label,
                                    subtitle: query,
                                    usesFavicon: true
                                ) { openURL(url) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// URL host 로 커뮤니티 플랫폼을 판별해 행 라벨을 정한다 — openURL 이 설치된 앱(YouTube 등)으로 라우팅.
    private func sourceLabel(_ url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host.contains("youtu") { return "YouTube에서 보기" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.contains("twitter") { return "X에서 보기" }
        if host.contains("instagram") { return "Instagram에서 보기" }
        if host.contains("tiktok") { return "TikTok에서 보기" }
        return "원본에서 보기"
    }
}

/// 쇼핑 캡처의 커머스 "검색된 상태" 링크 — 같은 상품을 여러 판매자가 팔아 특정 상품 상세를
/// 정할 수 없으므로, 상품명이 검색된 결과 화면으로 보낸다 (lab/active/shopping-product-link exp2
/// 에서 쿠팡·네이버 통합검색 조합의 URL 유효성 검증).
private enum ShoppingSearchProvider: CaseIterable, Identifiable {
    case coupang, naver

    var id: Self { self }

    var label: String {
        switch self {
        case .coupang: return "쿠팡에서 찾기"
        case .naver:   return "네이버에서 찾기"
        }
    }

    func searchURL(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .coupang:
            components = URLComponents(string: "https://www.coupang.com/np/search")
            components?.queryItems = [URLQueryItem(name: "q", value: query)]
        case .naver:
            components = URLComponents(string: "https://search.naver.com/search.naver")
            components?.queryItems = [URLQueryItem(name: "query", value: query)]
        }
        return components?.url
    }
}

/// 링크 행 — 할 일·일정 행과 같은 문법(leading 타일 + 제목·부제 + 흰 카드).
/// 이전의 그라데이션 CTA 는 체크 행·날짜 타일 사이에서 혼자 다른 종이라 폐기(2026-06-11) —
/// ② 섹션의 모든 행이 단일 시각 언어를 공유해야 어떤 의도 조합이든 화면이 같게 읽힌다.
/// 브랜드 보라는 타일·부제 틴트로 남겨 "원본으로 가는 행동"의 무게를 유지한다.
/// 쇼핑 검색 행도 같은 문법을 공유한다 — subtitle 은 host 대신 상품명(회수 단서).
/// 쿠팡·네이버처럼 목적지 브랜드가 분명한 행은 단색 아이콘 대신 favicon 으로 "어디로 가는지"를
/// 글자보다 빨리 떠올리게 한다(usesFavicon). 로드 전·실패 시엔 FaviconTile 의 보라 첫글자 타일 폴백.
private struct DetailLinkRow: View {
    let url: URL
    let label: String
    var subtitle: String?
    var icon: String = "arrow.up.right"
    var usesFavicon: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                    if usesFavicon {
                        FaviconTile(host: url.host, size: 24)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(HomeDesign.Color.purple600)
                    }
                }
                .frame(width: 46, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(subtitle ?? url.host ?? url.absoluteString)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.purple500)
                        .lineLimit(1)
                }
            }
            .padding(HomeDesign.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

/// 할 일 행 — 캘린더 탭 `UpcomingTodoRow` 와 같은 시각 언어(체크 토글 · strikethrough · D-day 라벨 ·
/// 행마다 흰 카드). 완료↔미완료 양방향 토글(잘못 눌러도 다시 해제 가능). 상세 안이라 chevron 은 없다.
private struct DetailTodoRow: View {
    let instance: IntentInstance
    let onToggle: () -> Void

    private var isCompleted: Bool { instance.lifecycle.kind == .archived }

    /// 할 일 이름은 `payload.title` 우선 — 채팅 수정(propose_item_update)이 갱신하는 구조 필드이고
    /// 캘린더 탭과 같은 원천. `label` 은 분석 시점 시나리오 라벨이라 수정 후 stale 할 수 있어 폴백.
    private var title: String {
        if let title = instance.payload.title, !title.isEmpty { return title }
        return instance.displayLabel
    }

    /// 마감일 — 캘린더 탭 `TodoRowItem.deadline` 과 같은 규칙(`payload.deadline ?? payload.date`).
    static func deadline(of instance: IntentInstance) -> Date? {
        PayloadDate.parse(instance.payload.deadline ?? instance.payload.date)
    }

    private var deadline: Date? { Self.deadline(of: instance) }

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            Button(action: onToggle) {
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isCompleted ? HomeDesign.Color.butter400 : HomeDesign.Color.textFaint)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel(isCompleted ? "\(title) 완료 취소" : "\(title) 완료하기")

            VStack(alignment: .leading, spacing: 3) {
                // 상세는 읽는 자리 — 캘린더처럼 한 줄로 자르지 않고 전체를 보여준다.
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(isCompleted ? HomeDesign.Color.textMuted : HomeDesign.Color.textPrimary)
                    .strikethrough(isCompleted, color: HomeDesign.Color.textFaint)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(deadlineLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isCompleted ? HomeDesign.Color.textFaint : DueDisplay.deadlineColor(deadline))
                    .lineLimit(1)
            }
        }
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        .opacity(isCompleted ? 0.65 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCompleted)
    }

    private var deadlineLabel: String {
        if isCompleted { return "완료함" }
        guard let deadline else { return "마감일 미정" }
        return DueDisplay.deadlineLabel(deadline)
    }
}

/// 일정 행 — 캘린더 탭 `UpcomingScheduleRow` 와 같은 시각 언어(날짜 타일 · 상대 라벨 · 흰 카드).
/// 기간 일정은 "시작 ~ 끝", 역전(끝<시작)·파싱 불가 end 는 점 일정으로 수렴(캘린더와 동일 가드).
private struct DetailScheduleRow: View {
    let instance: IntentInstance

    private var title: String {
        if let title = instance.payload.title, !title.isEmpty { return title }
        return instance.displayLabel
    }

    private var start: Date? { Self.parsed(date: instance.payload.date, time: instance.payload.time) }
    private var end: Date? { Self.parsed(date: instance.payload.endDate, time: instance.payload.endTime) }

    var body: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ScheduleDateTile(date: start)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(scheduleLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.sky400)
                    .lineLimit(1)
            }
        }
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
    }

    private var scheduleLabel: String {
        guard let start else { return "날짜 미정" }
        guard let end, end > start else { return DueDisplay.scheduleLabel(start) }
        return DueDisplay.scheduleRangeLabel(start, end)
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
}

// MARK: - ③ 모찌가 정리했어요 (요약 + 원본)

private struct GistCard: View {
    let mochiItem: MochiItem
    let analysis: MochiItemAnalysis

    var body: some View {
        // 섹션 라벨은 카드 밖 — ② "지금 할 수 있어요"와 같은 리듬(라벨 → 카드)으로 골격을 통일.
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "모찌가 정리했어요", icon: "sparkles")
                .padding(.horizontal, HomeDesign.Spacing.xs)
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
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

// MARK: - ⑤ 비슷한 기록 (similar)

/// 의미가 가까운 다른 기록을 가로 캐러셀로 — 회수의 능동 주체는 모찌(PRODUCT §1.5).
/// 카드는 로컬 MochiItem 으로 렌더하고, "왜 비슷한지" 근거 칩만 서버 신호를 쓴다.
private struct SimilarSection: View {
    let items: [SimilarItemPreview]
    let onTap: (SimilarItemPreview) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "비슷한 기록", icon: "rectangle.stack")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeDesign.Spacing.md) {
                    ForEach(items) { preview in
                        SimilarItemCard(preview: preview) { onTap(preview) }
                    }
                }
                .padding(.horizontal, 2)  // 카드 그림자가 ScrollView 클립에 잘리지 않게
                .padding(.bottom, 4)
            }
        }
    }
}

private struct SimilarItemCard: View {
    let preview: SimilarItemPreview
    let onTap: () -> Void

    private var item: MochiItem { preview.item }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                media
                    .frame(width: 150, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous))
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !preview.reasons.isEmpty {
                    reasonChips
                }
            }
            .frame(width: 150)
            .padding(HomeDesign.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 8, x: 0, y: 2)
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private var media: some View {
        switch item.viewKind {
        case .screenshot:
            LocalThumbnail(
                relativePath: item.source.imageRefs.first?.relativePath,
                targetSize: CGSize(width: 150, height: 96)
            ) {
                ZStack {
                    HomeDesign.Color.purple100
                    Image(systemName: "photo")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
        case .memo:
            ZStack {
                LinearGradient(
                    colors: [HomeDesign.Color.butter50, HomeDesign.Color.cream100],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "quote.closing")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.3))
            }
        case .url:
            ZStack {
                HomeDesign.Color.purple50
                Image(systemName: "link")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600)
            }
        }
    }

    private var reasonChips: some View {
        HStack(spacing: 4) {
            ForEach(Array(preview.reasons.prefix(2).enumerated()), id: \.offset) { _, reason in
                Text(Self.label(for: reason))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.purple600)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(HomeDesign.Color.purple50))
            }
        }
    }

    /// 서버 enum → 한국어 칩 카피 (카피는 클라 소유 — ⓪ 폭포를 안 탄다).
    private static func label(for reason: SimilarReason) -> String {
        switch reason.kind {
        case .sharedSource: return "같은 출처"
        case .sameIntent:   return "같은 의도"
        case .closeInTime:  return "비슷한 시기"
        }
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
        // 풀스크린 표시는 imageView.frame 이 이미지 비율로 정확히 잡혀(JXZoomImageCell.adjustImageViewFrame)
        // contentMode 와 무관하다. 하지만 dismiss zoom 전환의 임시 뷰가 이 셀 imageView 의
        // contentMode·backgroundColor 를 복제하므로(JXZoomDismissAnimator), 가로 캡처를 fit+흰배경으로
        // 두면 풀스크린→상세 복귀 시 상세 헤더(가로=fit)와 모양이 맞아 fill→fit 점프가 사라진다.
        let isLandscape = image.size.width > image.size.height
        photoCell.imageView.contentMode = isLandscape ? .scaleAspectFit : .scaleAspectFill
        photoCell.imageView.backgroundColor = isLandscape ? .white : .clear
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
    @ObservedObject var handle: ScreenshotImageViewHandle
    @State private var image: UIImage?

    var body: some View {
        // 비율 박스(4:3)를 Layout 으로 직접 계산한다 — `aspectRatio(_:contentMode:)` 는 ScrollView 의
        // nil 높이 제안을 자식(이미지뷰)의 ideal 크기로 메우는 협상이 끼어들어, 원본이 작은 캡처에서
        // 박스가 이미지 크기로 쪼그라들고 양옆에 배경이 비쳤다. FixedRatioBox 는 "제안된 너비 ÷ 비율
        // = 높이"만 답하므로 이미지 크기가 레이아웃에 개입할 경로가 없다.
        FixedRatioBox(ratio: targetSize.width / targetSize.height, fallbackWidth: targetSize.width) {
            UIKitImageView(image: image, contentMode: foregroundContentMode, handle: handle)
                .background {
                    // 가로 캡처는 fit 으로 좌우 끝까지 보여주고, 남는 레터박스를 같은 이미지의 블러
                    // 확대본으로 채운다 — 카드 `LocalThumbnail`(가로=fit+블러)과 동일 정책이라
                    // 카드→상세 hero 비행에서 모양이 튀지 않는다.
                    if let image, image.size.width > image.size.height {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 12)
                    }
                }
        }
        .clipped()
        .task(id: relativePath) {
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            image = await loadDownsampledDetailImage(relativePath: relativePath, maxPixel: maxPixel)
        }
    }

    /// 세로 캡처는 `fill` 크롭(메인 콘텐츠가 중앙에 있을 확률이 높다), 가로 캡처는 `fit`(좌우
    /// 끝의 정보도 중요) — 카드와 통일. 로드 전(nil)엔 fill 기본.
    private var foregroundContentMode: UIView.ContentMode {
        guard let image, image.size.width > image.size.height else { return .scaleAspectFill }
        return .scaleAspectFit
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
