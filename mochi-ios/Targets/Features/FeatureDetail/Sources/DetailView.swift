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
/// ③′ 장소(조건 — Agent 지오코딩 시 지도 프리뷰 + 네이버 길찾기) → ④ 모찌가 정리했어요(요약·원본).
/// **어떤 intent·source 조합이든 골격이 같다** — eyebrow 가 항상 첫 텍스트 줄이고, 섹션 라벨이
/// 카드 밖에 노출되며, ③ 의 행들은 leading 타일·제목·부제의 단일 문법을 공유한다(2026-06-11 통일).
/// 제목은 탭 한 번으로 인라인 교정(로컬 `userTitle` 오버라이드).
/// ("더 자세히" 접힘 섹션은 2026-06-10 제거 — 추출정보·태그·근거는 회수에 기여하지 않는 내부 디테일.)
public struct DetailView: View {
    @Bindable public var store: StoreOf<DetailFeature>
    /// root 상세(카드 탭으로 hero 진입한 첫 화면)면 좌상단 닫기(X)를 노출한다. "비슷한 기록"으로
    /// push 된 자식 상세는 NavigationStack 시스템 back(< 뒤로·엣지 스와이프)으로 이전 상세에 복귀한다.
    let isRoot: Bool
    @State private var presentationAnchor: UIViewController?
    @State private var photoBrowserPresenter: ScreenshotPhotoBrowserPresenter?
    @State private var sourceImageHidden = false
    /// 헤더 아래 섹션들의 시차 등장 트리거 — hero 비행(0.55s)과 겹쳐 콘텐츠가 차오르는 인상.
    /// 헤더는 비행 착지 지점이라 제외(움직이면 `detailImageFrame` 예측이 깨진다).
    @State private var sectionsAppeared = false

    public init(store: StoreOf<DetailFeature>, isRoot: Bool = true) {
        self.store = store
        self.isRoot = isRoot
    }

    /// 사진 앱에 저장할 원본이 있나 — 로컬 캐시(relativePath) 또는 GCS 원본(objectKey) 중 하나라도 있으면 true.
    private var hasSavableImage: Bool {
        guard let ref = store.mochiItem?.source.imageRefs.first else { return false }
        return !ref.relativePath.isEmpty || (ref.objectKey?.isEmpty == false)
    }

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
        .toolbar { detailToolbar }
        .alert($store.scope(state: \.deleteAlert, action: \.deleteAlert))
        .overlay(alignment: .bottom) {
            if let toast = store.saveToast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(HomeDesign.Color.ink900.opacity(0.9)))
                    .padding(.bottom, HomeDesign.Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.saveToast)
        .task { store.send(.onAppear) }
    }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                // root 는 custom present 라 back 이 없다 — 닫기(X)로 dismiss. 아래로 드래그해도 닫힌다.
                // (자식 상세는 X 대신 NavigationStack 시스템 back 으로 이전 상세에 복귀.)
                Button { store.send(.closeButtonTapped) } label: {
                    toolbarIcon("xmark")
                }
                .accessibilityLabel("닫기")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                if !isRoot {
                    // push 된 자식 상세 — back 은 한 칸씩이라, 깊이 들어간 뒤 한 번에 빠져나오는
                    // 명시적 출구. 아래로 드래그(전체 닫기)의 발견성 보조.
                    Button { store.send(.closeButtonTapped) } label: {
                        Label("닫기", systemImage: "xmark")
                    }
                    Divider()
                }
                if let item = store.mochiItem {
                    Button { store.send(.favoriteToggled) } label: {
                        Label(
                            item.isFavorite ? "즐겨찾기 해제" : "즐겨찾기 추가",
                            systemImage: item.isFavorite ? "star.fill" : "star"
                        )
                    }
                }
                if hasSavableImage {
                    Button { store.send(.saveImageButtonTapped) } label: {
                        Label("이미지 저장", systemImage: "square.and.arrow.down")
                    }
                }
                Button("삭제", role: .destructive) { store.send(.deleteButtonTapped) }
            } label: {
                toolbarIcon("ellipsis")
            }
            .accessibilityLabel("더보기")
        }
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

                IntentActionsSection(mochiItem: mochiItem) { instance in
                    store.send(.todoToggled(instance))
                }
                .riseIn(sectionsAppeared, index: bump)

                // 장소(Agent searchPlaceGeo) — 지도 프리뷰 + 네이버 길찾기. 행동(②) 바로 아래에
                // 둔다: "다시 찾아가기"는 이 기록의 가장 구체적인 다음 행동이라 링크보다 앞선다.
                let plc = analysis.place == nil ? 0 : 1
                if let place = analysis.place {
                    PlaceMapSection(place: place)
                        .riseIn(sectionsAppeared, index: bump + 1)
                }

                // 관련 링크(Agent ResourceFinder) — 메타 행카드. 위 "지금 할 수 있어요"의 원본
                // 링크(primaryActionURL)와 같은 자료(같은 영상/URL)는 중복이라 숨긴다(백엔드 dedup 의
                // 표시단 안전망 — 정규화 규칙은 URLCanonical 단일 기준). 회수>확장 우선이라 원본은 위에 남긴다.
                let primaryKey = mochiItem.primaryActionURL.map(URLCanonical.key)
                let visibleRefs = analysis.referenceLinks.filter {
                    primaryKey == nil || URLCanonical.key($0.url) != primaryKey
                }
                let ref = visibleRefs.isEmpty ? 0 : 1
                if !visibleRefs.isEmpty {
                    ReferenceLinksSection(links: visibleRefs)
                        .riseIn(sectionsAppeared, index: bump + plc + 1)
                }

                GistCard(mochiItem: mochiItem, analysis: analysis)
                    .riseIn(sectionsAppeared, index: bump + plc + ref + 1)

                // ⑤ 비슷한 기록 — 결과 없으면(임계값 미달·미색인) 섹션 자체를 렌더하지 않는다.
                if !store.similar.isEmpty {
                    SimilarSection(items: store.similar) { preview in
                        store.send(.similarItemTapped(preview.id))
                    }
                    .riseIn(sectionsAppeared, index: bump + plc + ref + 2)
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
    /// DesignSystem `CircularGlyph` 단일 소스(카테고리 턴테이블 back 버튼과 같은 칩).
    private func toolbarIcon(_ systemName: String) -> some View {
        CircularGlyph(systemName)
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

/// 기록 상세 root — "비슷한 기록" push 스택을 소유하는 `NavigationStack(path:)`.
/// App(`ZoomDetailPresentation`)이 hosting rootView 로 이걸 띄운다. 카드 탭으로 hero 진입한 첫 상세가
/// root(`isRoot: true`)이고, 비슷한 기록으로 쌓이는 항목들이 자식(destination, `isRoot: false`)이다.
/// hero zoom 비행은 root 진입에만 입혀지고, 자식은 표준 push 슬라이드로 오른쪽에서 밀려 들어온다.
/// 모든 push 는 root 의 `path` 한 곳에 모인다(`DetailFeature.State.path` 주석 참고).
public struct DetailRootView: View {
    @Bindable public var store: StoreOf<DetailFeature>

    public init(store: StoreOf<DetailFeature>) { self.store = store }

    public var body: some View {
        NavigationStack(path: $store.scope(state: \.path, action: \.path)) {
            DetailView(store: store, isRoot: true)
        } destination: { store in
            DetailView(store: store, isRoot: false)
        }
        // push 된 자식 상세의 back 버튼·바 버튼 tint = 모찌 퍼플(메인 NavigationStack 과 동일 처리).
        // .tint 를 안 걸면 시스템 기본색으로 빠지므로 명시한다.
        .tint(MochiTheme.Palette.primary)
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
            if let ref = mochiItem.source.imageRefs.first {
                ScreenshotPreviewImage(
                    relativePath: ref.displayRelativePath,
                    objectKey: ref.objectKey,
                    sha256: ref.sha256,
                    mimeType: ref.mimeType,
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
                // onTapGesture 는 VoiceOver 가 버튼으로 못 읽으므로 트레잇·라벨을 직접 부여한다.
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("이미지 크게 보기")
            } else {
                // 스크린샷이 없는 기록(메모·URL) — 빈 흰 헤더 대신 정체성 hero 밴드로 카드 상단을
                // 풀폭으로 채운다(좌우 흰 여백 제거 + "메모/링크" 정체성 표시). 분석중과 같은 밴드라 튀지 않는다.
                DetailIdentityHero(kind: mochiItem.viewKind)
            }

            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                // 출처·시간 eyebrow — 제목 **위**에 둔다. 썸네일이 없는 기록(메모·URL)도
                // 첫 텍스트 줄이 항상 같아, 어떤 조합을 열어도 "기록 상세"로 즉시 읽힌다.
                if let category = mochiItem.analysis?.category?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
                    // 카테고리가 있으면 형식 대신 카테고리를 보여주고, 탭하면 그 카테고리 턴테이블(샤라락)로.
                    Button { store.send(.categoryTapped) } label: {
                        HStack(spacing: 4) {
                            Text(category)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.purple600)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(HomeDesign.Color.purple400)
                            Text("· \(mochiItem.relativeCapturedLabel)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: mochiItem.viewKind.icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textFaint)
                        Text(mochiItem.displaySubtitle)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
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
    /// 원본 링크 행 — "지금 할 수 있어요"와 관련 링크 중복 제거가 같은 값을 보도록 도메인 단일 원천을 쓴다.
    private var primaryURL: URL? { mochiItem.primaryActionURL }
    private var hasAnyAction: Bool {
        !todoRows.isEmpty || hasConfirmedSchedule || primaryURL != nil
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

/// 링크 행 — 할 일·일정 행과 같은 문법(leading 타일 + 제목·부제 + 흰 카드).
/// 이전의 그라데이션 CTA 는 체크 행·날짜 타일 사이에서 혼자 다른 종이라 폐기(2026-06-11) —
/// ② 섹션의 모든 행이 단일 시각 언어를 공유해야 어떤 의도 조합이든 화면이 같게 읽힌다.
/// 브랜드 보라는 타일 틴트로 남겨 "원본으로 가는 행동"의 무게를 유지한다.
private struct DetailLinkRow: View {
    let url: URL
    let label: String
    var icon: String = "arrow.up.right"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                        .fill(HomeDesign.Color.purple50)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.purple600)
                }
                .frame(width: 46, height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(url.host ?? url.absoluteString)
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
                .padding(.horizontal, HomeDesign.Spacing.lg)  // 첫·마지막 카드를 본문 좌우 여백에 맞춤
                .padding(.vertical, 4)  // 카드 그림자가 ScrollView 클립에 잘리지 않게
            }
            // 부모 본문 패딩(lg)을 음수로 상쇄 → 캐러셀만 화면 좌우 끝까지 이어진다(헤더는 본문 정렬 유지).
            .padding(.horizontal, -HomeDesign.Spacing.lg)
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
                relativePath: item.source.imageRefs.first?.displayRelativePath,
                objectKey: item.source.imageRefs.first?.objectKey,
                sha256: item.source.imageRefs.first?.sha256,
                mimeType: item.source.imageRefs.first?.mimeType,
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
        case .sameIntent:   return "비슷한 종류"
        case .closeInTime:  return "비슷한 시기"  // reserved — 서버가 더 이상 파생하지 않아 실제로는 안 뜬다
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

/// 스크린샷이 없는 기록(메모·URL)의 hero 밴드 — 카드 상단을 정체성 색으로 **풀폭**으로 채운다.
/// 홈·비슷한 기록 카드의 미디어 자리(`SimilarItemCard.media`)와 같은 시각 언어(메모=버터/크림, URL=보라)라
/// 화면 전반에서 "이건 메모/링크"가 일관되게 읽히고, 빈 흰 헤더로 인한 좌우 흰 여백을 없앤다.
private struct DetailIdentityHero: View {
    let kind: MochiItemKind

    var body: some View {
        ZStack {
            switch kind {
            case .memo:
                LinearGradient(
                    colors: [HomeDesign.Color.butter50, HomeDesign.Color.cream100],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "quote.closing")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.butter400.opacity(0.35))
            case .url:
                LinearGradient(
                    colors: [HomeDesign.Color.purple50, HomeDesign.Color.purple100],
                    startPoint: .top, endPoint: .bottom
                )
                Image(systemName: "link")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple600)
            case .screenshot:
                // 도달하지 않는다(스크린샷은 이미지 렌더 경로) — 안전 폴백.
                HomeDesign.Color.purple50
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 132)
    }
}

private enum DetailStateView {
    /// 항목 자체를 아직 못 읽은 짧은 순간(로컬 DB 조회 중) — kind 를 모르므로 중립 스켈레톤 카드.
    static var loading: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                HomeDesign.Color.purple50
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
                skeletonLine(width: 180, height: 18)
                skeletonLine(width: 240, height: 14)
            }
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HomeDesign.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        .cardShadow()
    }

    /// 분석중 — 분석완료 헤더(RecallHeader)와 **같은 카드 골격**(hero 상단 + 본문)으로 그린다. hero 가
    /// 같은 렌더러·같은 자리라, 분석이 끝나 본문이 채워질 때 이미지가 튀지 않는다(content-mode·풀폭 통일).
    @ViewBuilder
    static func processing(_ mochiItem: MochiItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heroMedia(mochiItem)
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("모찌가 정리하고 있어요…")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
                // 제목 자리 스켈레톤 — 곧 차오를 콘텐츠를 암시한다.
                skeletonLine(width: 220, height: 18)
            }
            .padding(HomeDesign.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(HomeDesign.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        .cardShadow()
    }

    /// 분석중·완료 공용 hero — 스크린샷이면 단일 렌더러(`ScreenshotPreviewImage`), 메모/URL 이면 정체성 밴드.
    /// RecallHeader 의 hero 분기와 같은 규칙이라 두 상태가 동일하게 보인다.
    @ViewBuilder
    private static func heroMedia(_ mochiItem: MochiItem) -> some View {
        if let ref = mochiItem.source.imageRefs.first {
            ScreenshotPreviewImage(
                relativePath: ref.displayRelativePath,
                objectKey: ref.objectKey,
                sha256: ref.sha256,
                mimeType: ref.mimeType,
                targetSize: CGSize(width: 320, height: 240)
            )
            .frame(maxWidth: .infinity)
            .background(Rectangle().fill(HomeDesign.Color.purple50))
        } else {
            DetailIdentityHero(kind: mochiItem.viewKind)
        }
    }

    /// 스켈레톤 한 줄 — bg 톤 블록으로 "곧 채워질 자리"를 암시한다.
    private static func skeletonLine(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(HomeDesign.Color.bg)
            .frame(maxWidth: width)
            .frame(height: height)
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

/// 기록 상세 hero 이미지 — **분석중·분석완료 공용** 단일 렌더러. 4:3 박스를 항상 컨테이너 폭으로 채우고
/// (세로=center fill / 가로=fit+블러 확대 배경), 비어 있는 `relativePath` 는 GCS 폴백으로 자가 치유한다.
/// 분석중/완료가 같은 렌더러를 써서 분석이 끝나도 content-mode·크롭이 튀지 않는다(이전엔 분석중이 다른
/// 컴포넌트 + `.aspectRatio` 라 ScrollView 협상이 깨져 세로 좁은 띠 + 좌우 흰 여백으로 렌더됐다).
/// `handle` 은 헤더(완료)가 탭→확대 + hero 비행에 쓰는 UIImageView 핸들 — 분석중은 nil(표시 전용).
private struct ScreenshotPreviewImage: View {
    let relativePath: String?
    /// 렌더 시점 GCS 폴백용(로컬 파일이 없을 때) — 셋이 다 있으면 `CaptureImageStore` 가 받아 캐시한다.
    var objectKey: String? = nil
    var sha256: String? = nil
    var mimeType: String? = nil
    let targetSize: CGSize
    var handle: ScreenshotImageViewHandle? = nil
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
        // 빈 문자열 relativePath 는 non-nil 이라 `relativePath ?? objectKey` 로는 id 가 늘 "" 로 고정돼
        // objectKey 만 다른 항목으로 슬롯이 갈아끼워져도 재로드가 안 된다 — 로컬 경로가 비면 objectKey 로 식별.
        .task(id: relativePath?.isEmpty == false ? relativePath : objectKey) {
            image = nil  // 슬롯 교체 시 이전 항목 잔상 제거(첫 등장은 이미 nil 이라 무해).
            let maxPixel = Int(max(targetSize.width, targetSize.height) * 3)
            // 로컬 파일이 없고(빈 relativePath) GCS 단서가 다 있으면 렌더 시점에 받아 채운다
            // (재설치·타기기 생성·pull 직후 objectKey 만 있는 항목 자가 치유) — 카드 LocalThumbnail 과 동일.
            var path = relativePath
            if (path?.isEmpty ?? true), let objectKey, let sha256, let mimeType {
                path = await CaptureImageStore.shared.ensureLocalPath(
                    sha256: sha256, mimeType: mimeType, objectKey: objectKey
                )
            }
            guard let path, !path.isEmpty else { return }
            let loaded = await loadDownsampledDetailImage(relativePath: path, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }  // await 사이 슬롯이 바뀌었으면 stale 대입 버림.
            image = loaded
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
    /// 헤더(완료)만 JXPhotoBrowser 확대·hero 비행을 위해 핸들을 넘긴다. 분석중(표시 전용)은 nil.
    var handle: ScreenshotImageViewHandle? = nil

    func makeUIView(context: Context) -> UIImageView {
        let imageView = LayoutNeutralImageView()
        imageView.clipsToBounds = true
        imageView.backgroundColor = .clear
        imageView.contentMode = contentMode
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        handle?.imageView = imageView
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        imageView.image = image
        imageView.contentMode = contentMode
        handle?.image = image
        handle?.imageView = imageView
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
