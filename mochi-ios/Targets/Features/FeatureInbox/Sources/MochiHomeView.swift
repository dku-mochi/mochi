import SwiftUI
import PhotosUI
import UIKit
import ComposableArchitecture
import CoreDomain
import CorePersistence
import DesignSystem

/// 새 홈 — "찾으러 들어왔다가, 잊은 기억을 발견하고 '아, 맞다!' 한다".
///
/// 시선 위계(아래로 갈수록 약해진다):
///  1. **심장(전면)** — 회수 3D 히어로(`RecallHeroView`)가 상단을 가득 채운다. 제목·검색·설정은
///     히어로 위에 떠 있는 floating bar 로 올려, 내비바 영역까지 회수에 내준다.
///  2. **리포트(요약)** — "이번 달 이런 걸 모아두셨어요" 카테고리 분포(막대+범례), 범례 탭 → 3D 턴테이블.
///  3. **안전망(조용)** — 최근에 보낸 것들 · (있을 때) 확인이 필요해요.
///
/// 검색바는 두지 않는다 — 탐색은 검색 탭의 역할이라, 상단 돋보기 아이콘으로만 양보한다(탭별 역할 분리).
/// 우하단 + 버튼이 빠른 입력(메모·링크·사진·카메라) — 저장도 홈의 일부지만 시각 비중은 낮춘다.
public struct MochiHomeView: View {

    @Bindable public var store: StoreOf<MochiHomeFeature>

    @FocusState private var quickMemoFocused: Bool
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    @State private var isComposeMenuPresented = false
    @State private var pendingImage: PendingImage?
    @State private var imageMemoText = ""
    @State private var capturedCameraData: Data?
    /// 첫 진입 시 섹션들이 순서대로 떠오르는 entrance 연출(한 번만).
    @State private var hasEntered = false

    /// 최상단 bar 의 날짜 라벨 — 큰 제목 대신 컨텍스트를 둬 앱 이름 오인을 막는다.
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일 EEEE"
        return f
    }()
    private var todayLabel: String { Self.dateFormatter.string(from: Date()) }

    public init(store: StoreOf<MochiHomeFeature>) {
        self.store = store
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: HomeDesign.Spacing.xl) {
                        recallHeroSection(deckHeight: heroDeckHeight(for: geo.size.height))
                            .riseIn(hasEntered, index: 0)
                        needsReviewBanner
                            .riseIn(hasEntered, index: 1)
                        upcomingSection
                            .riseIn(hasEntered, index: 2)
                        monthlyReportCard(cardWidth: geo.size.width - HomeDesign.Spacing.xl * 2)
                            .riseIn(hasEntered, index: 3)
                        recentSection
                            .riseIn(hasEntered, index: 4)
                    }
                    .padding(.horizontal, HomeDesign.Spacing.xl)
                    .padding(.top, Self.topBarHeight + HomeDesign.Spacing.sm)
                    // FAB(48) + 우하단 여백이 마지막 섹션을 가리지 않도록 충분히 비운다(탭바 inset 은 시스템 자동).
                    .padding(.bottom, Self.fabClearance)
                }
                .refreshable { await store.send(.refresh).finish() }

                floatingTopBar

                if isComposeMenuPresented {
                    HomeDesign.Color.ink900.opacity(0.22)
                        .ignoresSafeArea()
                        .transition(.opacity)
                        .onTapGesture { closeComposeMenu() }
                }

                VStack(alignment: .trailing, spacing: HomeDesign.Spacing.md) {
                    if isComposeMenuPresented {
                        composeMenuCard
                            .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                    }
                    floatingActionButton
                }
                .padding(.trailing, HomeDesign.Spacing.xl)
                .padding(.bottom, HomeDesign.Spacing.lg)
            }
            // 배경은 ZStack 바깥(.background)으로 분리 — ZStack 본체가 safe area 안에서 잡혀야
            // bottomTrailing FAB 이 탭바 밑이 아니라 탭바 위에 정렬된다(겹침 방지).
            .background(background.ignoresSafeArea())
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .preferredColorScheme(.light)
        .task {
            store.send(.onAppear)
            hasEntered = true
        }
        .alert($store.scope(state: \.deleteAlert, action: \.deleteAlert))
        .sheet(isPresented: $store.isComposingMemo) { memoComposeSheet }
        .sheet(isPresented: $store.isNeedsReviewPresented) { needsReviewSheet }
        .sheet(item: $pendingImage) { pending in imageMemoSheet(pending) }
        .photosPicker(isPresented: $isPhotoLibraryPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.9) {
                    pendingImage = PendingImage(data: jpeg)
                }
                selectedPhotoItem = nil
            }
        }
        .fullScreenCover(isPresented: $isCameraPresented, onDismiss: {
            if let data = capturedCameraData {
                capturedCameraData = nil
                pendingImage = PendingImage(data: data)
            }
        }) {
            CameraPicker { data in capturedCameraData = data }
                .ignoresSafeArea()
        }
    }

    // MARK: - 배경 (bg + 상단 회수 보라 글로우)

    private var background: some View {
        ZStack {
            HomeDesign.Color.bg
            // 회수가 심장인 홈 — 상단에 모찌의 보라 기운이 은은히 번진다(히어로가 커진 만큼 길게).
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.30),
                    HomeDesign.Color.purple100.opacity(0.10),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 440)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - 상단 floating bar (제목 + 검색·즐겨찾기·설정) — 회수 히어로 위에 떠 있다

    /// bar 한 줄 높이. 콘텐츠 top inset 과 같게 둬 히어로가 bar 바로 아래에서 시작한다.
    private static let topBarHeight: CGFloat = 52
    /// FAB(48) + 우하단 여백 — 마지막 섹션이 FAB 뒤로 들어가지 않게 ScrollView 하단을 비우는 양.
    private static let fabClearance: CGFloat = 92

    private var floatingTopBar: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: HomeDesign.Spacing.sm) {
                // 최상단은 제목이 아니라 날짜(컨텍스트). bar 배경 없이도 콘텐츠 위에서 잘 보이도록
                // chrome 과 같은 frosted 칩에 글씨를 얹는다(글자 뒤만 블러 — 배경 띠는 두지 않는다).
                Text(todayLabel)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.ink700)
                    .padding(.horizontal, HomeDesign.Spacing.md)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.55), lineWidth: 0.5))
                    .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 6, x: 0, y: 3)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                CircleIconButton(systemName: "magnifyingglass", accessibilityLabel: "검색") {
                    store.send(.searchTapped)
                }
                CircleIconButton(systemName: "star", accessibilityLabel: "즐겨찾기") {
                    store.send(.favoritesTapped)
                }
                CircleIconButton(systemName: "gearshape", accessibilityLabel: "설정") {
                    store.send(.openSettingsTapped)
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .frame(height: Self.topBarHeight)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 히어로 덱 높이 + 스크롤 추적

    /// 회수 히어로가 상단을 가득 채우도록 화면 높이의 ~48% (덱 위 섹션 헤더 + 아래 인디케이터 몫을 남김).
    private func heroDeckHeight(for available: CGFloat) -> CGFloat {
        min(max(available * 0.48, 340), 440)
    }

    // MARK: - ① 심장 (회수 히어로 — 상단 전면)

    @ViewBuilder
    private func recallHeroSection(deckHeight: CGFloat) -> some View {
        if store.recall.isEmpty {
            recallEmptyCard
        } else {
            RecallHeroView(
                entries: store.recall,
                images: store.recallImages,
                deckHeight: deckHeight,
                onOpenAll: { store.send(.recallSeeAllTapped) },
                onOpenFocal: { entry, hero in
                    // 카드는 지금 빠지지 않는다 — hero zoom 으로 상세를 열고, 닫고 돌아온 뒤 제거된다
                    // (recallDetailClosed). 그래야 카드 자리에 착지한 다음 우아하게 사라진다.
                    store.send(.recallEntryOpened(entry, hero: hero))
                }
            )
        }
    }

    /// 회수가 비었을 때(cold-start) — 작은 가로 카드 대신 중앙 정렬 일러스트로 따뜻하게 채운다.
    /// 모찌가 "곧 골라줄게요" 하는 준비 상태. 빈 자리를 어색하게 비워두지 않는다.
    private var recallEmptyCard: some View {
        VStack(spacing: HomeDesign.Spacing.lg) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [HomeDesign.Color.purpleGlow.opacity(0.28), .clear], center: .center, startRadius: 4, endRadius: 52))
                    .frame(width: 104, height: 104)
                Image("mochi2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 58, height: 58)
                    .shadow(color: HomeDesign.Color.purple500.opacity(0.18), radius: 12, x: 0, y: 6)
            }
            VStack(spacing: 6) {
                Text("모찌가 곧 골라드릴게요")
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("기억이 무르익으면 먼저 떠올려드릴게요")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xxl + HomeDesign.Spacing.sm)
        .padding(.horizontal, HomeDesign.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
                .fill(LinearGradient(colors: [HomeDesign.Color.surface, HomeDesign.Color.purple50.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
                .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
        )
        .cardShadow()
    }

    // MARK: - ② 리포트 (이번 달 카테고리 분포 — 막대 + 범례 + 마스코트)

    /// 옛 홈 "이번주 리포트"의 감성을 잇되 **이번 달** 분포를 한 카드에 요약한다(회의 결정).
    /// 카테고리 카드 그리드를 대체 — stacked 막대로 비중을 한눈에 보이고, 범례를 누르면 그 서랍이
    /// 3D 턴테이블로 펼쳐진다(서랍 탐색 기능은 보존, 진입점만 막대 범례로 옮김).
    private func monthlyReportCard(cardWidth: CGFloat) -> some View {
        let peekW = cardWidth * 0.30
        return ZStack(alignment: .top) {
            reportCardBody
            // 작은 모찌가 카드 오른쪽에서 살짝 엿본다(귀엽게). 본체 하단선이 카드 top edge 에 걸침(검증 비율).
            Image("mochi-peek")
                .resizable()
                .scaledToFit()
                .frame(width: peekW)
                .offset(x: cardWidth * 0.18, y: -peekW * 0.383)
                .shadow(color: HomeDesign.Color.ink900.opacity(0.16), radius: 6, x: 0, y: 4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // peek 가 위로 솟는 만큼 위 섹션과의 간격을 비운다(빼꼼은 살리되 닷·콘텐츠와 안 겹치게).
        .padding(.top, peekW * 0.36)
    }

    private var reportCardBody: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            HStack(alignment: .center) {
                HStack(spacing: 5) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("이번 달 모찌 리포트")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .tracking(0.6)
                }
                .foregroundStyle(HomeDesign.Color.purple600)
                Spacer(minLength: 0)
                Button {
                    store.send(.weeklyDigestTapped)
                } label: {
                    Text("자세히")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.purple600)
                        .padding(.horizontal, HomeDesign.Spacing.md)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(HomeDesign.Color.purple50))
                }
                .buttonStyle(PressableStyle())
            }

            monthlyHeadline

            if store.monthlyCategories.isEmpty {
                monthlyEmptyMessage
            } else {
                categoryStackBar
                categoryLegend
            }
        }
        .padding(HomeDesign.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(LinearGradient(colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous).stroke(HomeDesign.Color.purple100, lineWidth: 1.2))
        .cardShadow()
    }

    /// 저장 개수 헤드라인 — 한 줄, 숫자가 갱신될 때 굴러가며 바뀐다.
    private var monthlyHeadline: some View {
        Group {
            if store.monthlyRecordCount == 0 {
                Text("이번 달 첫 기억을 기다리고 있어요")
            } else {
                Text("기억 ")
                + Text("\(store.monthlyRecordCount)개").foregroundStyle(HomeDesign.Color.purple600)
                + Text("를 저장했어요")
            }
        }
        .font(.system(size: 20, weight: .heavy, design: .rounded))
        .foregroundStyle(HomeDesign.Color.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .contentTransition(.numericText(value: Double(store.monthlyRecordCount)))
        .animation(.spring(response: 0.6, dampingFraction: 0.9), value: store.monthlyRecordCount)
    }

    private var monthlyEmptyMessage: some View {
        Text("이번 달엔 아직 모은 기억이 없어요.\n캡처하거나 링크를 보내면 카테고리로 모아둘게요.")
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundStyle(HomeDesign.Color.textMuted)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 이번 달 비중 막대 — 상위 카테고리 + "그외" 한 묶음을 하나의 캡슐에 비율로 채운다.
    private var categoryStackBar: some View {
        let segments = reportSegments
        let total = max(segments.reduce(0) { $0 + $1.count }, 1)
        let gap: CGFloat = 3
        return GeometryReader { proxy in
            let usable = proxy.size.width - CGFloat(max(segments.count - 1, 0)) * gap
            HStack(spacing: gap) {
                ForEach(segments) { seg in
                    LinearGradient(colors: [seg.color, seg.color.opacity(0.82)], startPoint: .top, endPoint: .bottom)
                        .frame(width: max(usable * CGFloat(seg.count) / CGFloat(total), 6))
                }
            }
        }
        .frame(height: 18)
        .clipShape(Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).stroke(Color.white.opacity(0.55), lineWidth: 1))
        .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 3, x: 0, y: 1)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: store.monthlyRecordCount)
    }

    /// 범례 — 탭 가능한 카테고리 칩 2열 그리드. 누르면 그 서랍의 3D 턴테이블로(그외는 탭 불가).
    /// 연한 tint 배경 + 테두리 + chevron 으로 "누를 수 있다"를 분명히 한다(범례처럼 안 보이게).
    private var categoryLegend: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: HomeDesign.Spacing.sm),
                GridItem(.flexible(), spacing: HomeDesign.Spacing.sm),
            ],
            spacing: HomeDesign.Spacing.sm
        ) {
            ForEach(reportSegments) { seg in
                legendItem(seg)
            }
        }
    }

    @ViewBuilder
    private func legendItem(_ seg: ReportSegment) -> some View {
        let tappable = seg.bucket != nil
        let row = HStack(spacing: 7) {
            Circle().fill(seg.color).frame(width: 9, height: 9)
            Text(seg.name)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.ink700)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("\(seg.count)")
                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Spacer(minLength: 2)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(seg.color)
            }
        }
        .padding(.horizontal, HomeDesign.Spacing.md)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(seg.color.opacity(tappable ? 0.13 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .stroke(seg.color.opacity(tappable ? 0.22 : 0.12), lineWidth: 1)
        )

        if let bucket = seg.bucket {
            Button { store.send(.categoryTapped(bucket)) } label: { row }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("\(seg.name) \(seg.count)개. 눌러서 입체로 펼쳐보기")
        } else {
            row.accessibilityLabel("그외 \(seg.count)개")
        }
    }

    /// 막대·범례 세그먼트 — 상위 3개 카테고리 + (나머지가 있으면) "그외".
    /// "그외" 는 월간 총합에서 표시 카테고리 합을 뺀 값으로, 표시 밖 카테고리를 모두 흡수한다.
    private struct ReportSegment: Identifiable {
        let id: String
        let name: String
        let count: Int
        let color: Color
        /// 탭 → 그 서랍의 턴테이블. "그외" 는 nil(탭 불가).
        let bucket: CategoryBucket?
    }

    private var reportSegments: [ReportSegment] {
        let maxSegments = 3
        let shown = Array(store.monthlyCategories.prefix(maxSegments))
        var segments = shown.map { bucket in
            ReportSegment(
                id: bucket.name,
                name: bucket.name,
                count: bucket.count,
                color: MochiCategoryPalette.tint(bucket.tintIndex).strong,
                bucket: bucket
            )
        }
        let shownSum = shown.reduce(0) { $0 + $1.count }
        let etc = max(store.monthlyRecordCount - shownSum, 0)
        if etc > 0 {
            segments.append(ReportSegment(
                id: "__etc__", name: "그외", count: etc,
                color: HomeDesign.Color.purple200, bucket: nil
            ))
        }
        return segments
    }

    // MARK: - ④ 안전망 (최근 / 확인 필요 / 이번주)

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(title: "최근에 보낸 것들")
            if store.recent.isEmpty {
                emptyRecent
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HomeDesign.Spacing.md) {
                        ForEach(store.recent) { item in
                            RecentMochiCard(
                                mochiItem: item,
                                onTap: { hero in store.send(.mochiItemTapped(item.id, hero: hero)) },
                                onDelete: { store.send(.deleteMochiItemTapped(item.id)) }
                            )
                        }
                    }
                    .padding(.horizontal, HomeDesign.Spacing.xl)
                    .padding(.vertical, HomeDesign.Spacing.xl)
                }
                .padding(.horizontal, -HomeDesign.Spacing.xl)
                .padding(.vertical, -HomeDesign.Spacing.xl)
            }
        }
    }

    private var emptyRecent: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.cream200).frame(width: 54, height: 54)
                Image(systemName: "tray")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.ink500)
            }
            VStack(spacing: 4) {
                Text("아직 모찌가 없어요")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("우하단 + 버튼으로 빠르게 남겨보세요")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            if store.recent.isEmpty && store.needsReview.isEmpty {
                Button {
                    store.send(.replayOnboardingTapped)
                } label: {
                    Label("튜토리얼 다시 보기", systemImage: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.purple500)
                        .padding(.horizontal, HomeDesign.Spacing.md)
                        .padding(.vertical, HomeDesign.Spacing.sm)
                        .background(Capsule().fill(HomeDesign.Color.purple50))
                }
                .buttonStyle(PressableStyle())
                .padding(.top, HomeDesign.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xl)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface.opacity(0.7))
        )
    }

    @ViewBuilder
    private var needsReviewBanner: some View {
        if !store.needsReview.isEmpty {
            Button {
                store.send(.needsReviewTapped)
            } label: {
                HStack(spacing: HomeDesign.Spacing.md) {
                    ZStack {
                        Circle().fill(HomeDesign.Color.peach400.opacity(0.16))
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(HomeDesign.Color.peach400)
                    }
                    .frame(width: 34, height: 34)
                    Text("확인이 필요해요")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.ink700)
                    Spacer(minLength: 0)
                    Text("\(store.needsReview.count)")
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(minWidth: 18)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(HomeDesign.Color.peach400))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HomeDesign.Color.peach400)
                }
                .padding(.horizontal, HomeDesign.Spacing.lg)
                .padding(.vertical, HomeDesign.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                        .fill(LinearGradient(colors: [HomeDesign.Color.cream50, HomeDesign.Color.butter50], startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous).stroke(HomeDesign.Color.cream200, lineWidth: 1))
            }
            .buttonStyle(PressableStyle())
        }
    }

    // MARK: - ③ 예정된 알림 (모찌가 보낼 예정인 미래 알림 — pending 0건이면 숨김)

    /// pending 0건이면 섹션 자체를 비운다(안심 톤 — 빈 자리를 만들지 않는다).
    @ViewBuilder
    private var upcomingSection: some View {
        if !store.upcoming.isEmpty {
            UpcomingNotificationsView(
                entries: store.upcoming,
                onVeto: { eventID in store.send(.upcomingVetoed(eventID: eventID), animation: .spring(response: 0.4, dampingFraction: 0.85)) },
                onReschedule: { eventID, fireAt in store.send(.upcomingRescheduled(eventID: eventID, fireAt: fireAt), animation: .spring(response: 0.5, dampingFraction: 0.88)) }
            )
        }
    }

    // MARK: - 빠른 입력 (FAB + compose 메뉴)

    private var floatingActionButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isComposeMenuPresented.toggle()
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(
                    Circle()
                        .fill(LinearGradient(colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: HomeDesign.Color.purple500.opacity(0.4), radius: 14, x: 0, y: 8)
                )
                .rotationEffect(.degrees(isComposeMenuPresented ? 45 : 0))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isComposeMenuPresented ? "입력 메뉴 닫기" : "기록 남기기")
    }

    private var composeMenuCard: some View {
        VStack(spacing: 0) {
            composeMenuRow(icon: "square.and.pencil", tint: HomeDesign.Color.purple500, tintSoft: HomeDesign.Color.purple50, title: "메모·링크 남기기", subtitle: "생각나는 걸 빠르게") {
                closeComposeMenu(); store.isComposingMemo = true
            }
            rowDivider
            composeMenuRow(icon: "photo", tint: HomeDesign.Color.mint400, tintSoft: HomeDesign.Color.mint100, title: "이미지에서 선택", subtitle: "갤러리에서 가져오기") {
                closeComposeMenu(); isPhotoLibraryPresented = true
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                rowDivider
                composeMenuRow(icon: "camera", tint: HomeDesign.Color.sky400, tintSoft: HomeDesign.Color.sky100, title: "카메라로 촬영", subtitle: "지금 바로 찍기") {
                    closeComposeMenu(); isCameraPresented = true
                }
            }
        }
        .padding(.vertical, HomeDesign.Spacing.sm)
        .frame(width: 264)
        .background(RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous).fill(HomeDesign.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous).stroke(HomeDesign.Color.border, lineWidth: 1))
        .shadow(color: HomeDesign.Color.ink900.opacity(0.12), radius: 28, x: 0, y: 12)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(HomeDesign.Color.border)
            .frame(height: 1)
            .padding(.leading, HomeDesign.Spacing.lg + 38 + HomeDesign.Spacing.md)
    }

    private func composeMenuRow(icon: String, tint: Color, tintSoft: Color, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ZStack {
                    Circle().fill(tintSoft)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func closeComposeMenu() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { isComposeMenuPresented = false }
    }

    // MARK: - 시트들

    private var memoComposeSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                Text("빠르게 남기기")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                TextField("링크든 메모든 자유롭게 남겨보세요", text: $store.quickMemoText, axis: .vertical)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .tint(HomeDesign.Color.purple500)
                    .focused($quickMemoFocused)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .modifier(InputFieldCard())
                HStack(spacing: HomeDesign.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(HomeDesign.Color.purple400)
                    Text("링크를 붙여넣으면 내용을 정리하고, 그냥 적으면 메모로 남겨요.")
                        .font(.system(size: 12.5, weight: .regular, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            .padding(HomeDesign.Spacing.xl)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { store.isComposingMemo = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        quickMemoFocused = false
                        store.send(.quickMemoSubmitted)
                    }
                    .fontWeight(.semibold)
                    .disabled(store.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSaving)
                }
            }
            .task { quickMemoFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func imageMemoSheet(_ pending: PendingImage) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                Text("사진 남기기")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                if let uiImage = UIImage(data: pending.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous).stroke(HomeDesign.Color.border, lineWidth: 1))
                }
                TextField("간단한 메모를 남겨보세요 (선택)", text: $imageMemoText, axis: .vertical)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(2...5)
                    .tint(HomeDesign.Color.purple500)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .modifier(InputFieldCard())
                Spacer(minLength: 0)
            }
            .padding(HomeDesign.Spacing.xl)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("취소") { dismissImageMemo() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("저장") {
                        store.send(.imagePicked(data: pending.data, memo: imageMemoText))
                        dismissImageMemo()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func dismissImageMemo() {
        pendingImage = nil
        imageMemoText = ""
    }

    private var needsReviewSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("확인이 필요해요")
                            .font(.system(size: 24, weight: .heavy, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                        Text("모찌가 헷갈린 기억만 빠르게 정리해 주세요.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                    }
                    NeedsReviewCard(
                        mochiItems: Array(store.needsReview),
                        page: $store.needsReviewPage,
                        onReanalyze: { id, hint in store.send(.reanalyzeTapped(mochiItemID: id, hint: hint)) },
                        onRetry: { id in store.send(.retryAnalysisTapped(id)) }
                    )
                }
                .padding(HomeDesign.Spacing.xl)
            }
            .background(LinearGradient(colors: [HomeDesign.Color.cream50, HomeDesign.Color.bg], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { store.send(.dismissNeedsReview) }
                }
            }
            .toolbarBackground(HomeDesign.Color.cream50, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 섹션 헤더

private struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 17, weight: .heavy, design: .rounded))
                .tracking(-0.3)
                .foregroundStyle(HomeDesign.Color.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 헤더 원형 아이콘 버튼

private struct CircleIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.ink700)
                .frame(width: 34, height: 34)
                // frosted glass — 히어로가 은은히 비치는 블러 칩. 스크롤하면 bar 배경이 차올라 또렷해진다.
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 0.5))
                .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - 입력 필드 카드 (시트 공통)

private struct InputFieldCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(HomeDesign.Spacing.md)
            .background(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous).fill(HomeDesign.Color.purple50))
            .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous).stroke(HomeDesign.Color.border, lineWidth: 1))
    }
}

// MARK: - Pending image / Camera picker (입력)

private struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage,
               let jpeg = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(jpeg)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Preview

#Preview {
    MochiHomeView(
        store: Store(initialState: MochiHomeFeature.State()) {
            MochiHomeFeature()
        } withDependencies: {
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }
    )
}
