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
///  1. **입구(차분)** — 인사 + 검색바. 사용자 의도(찾기)를 즉시 받되 무게는 아래에 양보.
///  2. **심장(강렬)** — 회수 3D 히어로(`RecallHeroView`). 모찌가 잊은 기억을 큰 카드로 내민다.
///  3. **서랍(탐색)** — "이런 걸 모아두셨어요" 카테고리(실 캡처 커버), 탭 → 3D 턴테이블.
///  4. **안전망(조용)** — 최근에 보낸 것들 · (있을 때) 확인이 필요해요 · 이번주 리포트.
///
/// 우하단 + 버튼이 빠른 입력(메모·링크·사진·카메라) — 저장도 홈의 일부지만 시각 비중은 낮춘다.
public struct MochiHomeView: View {

    @Bindable public var store: StoreOf<MochiHomeFeature>

    @FocusState private var searchFocused: Bool
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

    public init(store: StoreOf<MochiHomeFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            background.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: HomeDesign.Spacing.xl) {
                    searchHeader
                        .padding(.top, HomeDesign.Spacing.sm)
                        .riseIn(hasEntered, index: 0)
                    searchChips
                        .riseIn(hasEntered, index: 1)
                    needsReviewBanner
                        .riseIn(hasEntered, index: 2)
                    recallHeroSection
                        .riseIn(hasEntered, index: 3)
                    categoriesSection
                        .riseIn(hasEntered, index: 4)
                    recentSection
                        .riseIn(hasEntered, index: 5)
                    weeklyBanner
                        .riseIn(hasEntered, index: 6)
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.md)
                .padding(.bottom, HomeDesign.Spacing.xxl)
            }
            .refreshable { await store.send(.refresh).finish() }
            .scrollDismissesKeyboard(.immediately)
            .simultaneousGesture(
                TapGesture().onEnded { if searchFocused { searchFocused = false } }
            )

            statusBarScrim

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
            // 회수가 심장인 홈 — 상단에 모찌의 보라 기운이 은은히 번진다.
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.28),
                    HomeDesign.Color.purple100.opacity(0.08),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 320)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var statusBarScrim: some View {
        VStack(spacing: 0) {
            HomeDesign.Color.bg
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.55),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 80)
            Spacer(minLength: 0)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }

    // MARK: - ① 입구 (인사 + 검색바)

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            HStack(alignment: .center) {
                Image("mochi2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                CircleIconButton(systemName: "star", accessibilityLabel: "즐겨찾기") {
                    store.send(.favoritesTapped)
                }
                CircleIconButton(systemName: "gearshape", accessibilityLabel: "설정") {
                    store.send(.openSettingsTapped)
                }
            }

            searchBar
        }
    }

    private var searchBar: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.purple50)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.purple500)
            }
            .frame(width: 30, height: 30)
            .accessibilityHidden(true)

            TextField("기억을 검색해보세요", text: $store.searchDraft)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .tint(HomeDesign.Color.purple500)
                .focused($searchFocused)
                .submitLabel(.search)
                .onSubmit { store.send(.searchSubmitted) }

            if !store.searchDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    store.send(.searchSubmitted)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle().fill(
                                LinearGradient(
                                    colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                        )
                }
                .buttonStyle(PressableStyle())
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.leading, HomeDesign.Spacing.md)
        .padding(.trailing, store.searchDraft.isEmpty ? HomeDesign.Spacing.lg : HomeDesign.Spacing.sm)
        .padding(.vertical, HomeDesign.Spacing.sm + 2)
        .frame(minHeight: 52)
        .background(Capsule(style: .continuous).fill(HomeDesign.Color.surface))
        .overlay(Capsule(style: .continuous).stroke(HomeDesign.Color.purple100, lineWidth: 1.4))
        .shadow(color: HomeDesign.Color.purple500.opacity(0.08), radius: 16, x: 0, y: 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: store.searchDraft.isEmpty)
    }

    // MARK: - 빠른 검색 칩

    @ViewBuilder
    private var searchChips: some View {
        if !store.searchSuggestions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    ForEach(store.searchSuggestions, id: \.self) { term in
                        Button {
                            store.send(.searchSuggestionTapped(term))
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11, weight: .bold))
                                Text(term)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(HomeDesign.Color.purple600)
                            .padding(.horizontal, HomeDesign.Spacing.md)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(HomeDesign.Color.purple100.opacity(0.6)))
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
            }
            .padding(.horizontal, -HomeDesign.Spacing.xl)
        }
    }

    // MARK: - ② 심장 (회수 히어로)

    @ViewBuilder
    private var recallHeroSection: some View {
        if store.recall.isEmpty {
            recallEmptyCard
        } else {
            RecallHeroView(
                entries: store.recall,
                images: store.recallImages,
                onOpenAll: { store.send(.recallSeeAllTapped) },
                onOpenFocal: { entry in
                    // 열어본 카드가 목록에서 빠지는 변화를 애니메이션 트랜잭션으로 — 부드럽게 사라진다.
                    store.send(.recallEntryOpened(entry), animation: .spring(response: 0.45, dampingFraction: 0.85))
                }
            )
        }
    }

    /// 회수가 비었을 때 — 자리를 비워두지 않고 "곧 떠올려줄게요"로 채운다(고정 틀, 레이아웃 안정).
    private var recallEmptyCard: some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [HomeDesign.Color.purpleGlow.opacity(0.4), .clear], center: .center, startRadius: 2, endRadius: 30))
                    .frame(width: 60, height: 60)
                Circle()
                    .fill(LinearGradient(colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("다시 보면 좋을 기억")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("기억이 무르익으면 모찌가 먼저 꺼내드릴게요")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(HomeDesign.Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(LinearGradient(colors: [HomeDesign.Color.surface, HomeDesign.Color.purple50.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous).stroke(HomeDesign.Color.purple100, lineWidth: 1.2))
        .cardShadow()
    }

    // MARK: - ③ 서랍 (카테고리)

    @ViewBuilder
    private var categoriesSection: some View {
        if !store.categories.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                SectionHeader(title: "이런 걸 모아두셨어요")
                let maxCount = max(store.categories.map(\.count).max() ?? 1, 1)
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: HomeDesign.Spacing.md),
                        GridItem(.flexible(), spacing: HomeDesign.Spacing.md),
                    ],
                    spacing: HomeDesign.Spacing.md
                ) {
                    ForEach(store.categories) { bucket in
                        CategoryDrawerCard(bucket: bucket, maxCount: maxCount) {
                            store.send(.categoryTapped(bucket))
                        }
                    }
                }
            }
        }
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

    private var weeklyBanner: some View {
        Button {
            store.send(.weeklyDigestTapped)
        } label: {
            HStack(spacing: HomeDesign.Spacing.md) {
                Image("mochi2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 40, height: 40)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("이번주 리포트")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.purple600)
                    if store.weeklyRecordCount == 0 {
                        Text("이번주 첫 기억을 기다리고 있어요")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                    } else {
                        (Text("이번주 ")
                         + Text("\(store.weeklyRecordCount)개").foregroundStyle(HomeDesign.Color.purple600)
                         + Text("의 기억을 모았어요"))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Text("돌아보기")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(HomeDesign.Color.purple600)
                .padding(.horizontal, HomeDesign.Spacing.md)
                .padding(.vertical, HomeDesign.Spacing.sm)
                .background(Capsule().fill(HomeDesign.Color.surface))
                .overlay(Capsule().stroke(HomeDesign.Color.purple200, lineWidth: 1.2))
            }
            .padding(HomeDesign.Spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.4)], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous).stroke(HomeDesign.Color.purple100, lineWidth: 1.2))
            .cardShadow()
        }
        .buttonStyle(PressableStyle())
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

// MARK: - 카테고리 서랍 카드 (실 캡처 커버 + 입체 press)

/// 카테고리 카드 — 대표 캡처 이미지를 커버로 깔고(없으면 색 그라데이션), 이름·개수·비중 바를 얹는다.
/// 누르면 살짝 안으로 눌리며(PressableStyle) 그 서랍이 3D 턴테이블로 열린다.
private struct CategoryDrawerCard: View {
    let bucket: CategoryBucket
    let maxCount: Int
    let onTap: () -> Void

    private var tint: (soft: Color, strong: Color) { MochiCategoryPalette.tint(bucket.tintIndex) }
    private var icon: String { MochiCategoryIcon.icon(for: bucket.name, fallbackIndex: bucket.tintIndex) }
    private var coverRef: ImageRef? { bucket.items.first?.source.imageRefs.first }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                cover
                info
            }
            .background(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous).fill(HomeDesign.Color.surface))
            .overlay(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous).stroke(HomeDesign.Color.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous))
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(bucket.name) \(bucket.count)개. 눌러서 입체로 펼쳐보기")
    }

    private var cover: some View {
        ZStack(alignment: .topLeading) {
            if let ref = coverRef {
                LocalThumbnail(
                    relativePath: ref.relativePath,
                    objectKey: ref.objectKey,
                    sha256: ref.sha256,
                    mimeType: ref.mimeType,
                    targetSize: CGSize(width: 180, height: 96),
                    alignment: .top
                ) { gradientCover }
            } else {
                gradientCover
            }
            // 출처가 가려지지 않게 상단 살짝 어둡게 + 아이콘 칩.
            LinearGradient(colors: [Color.black.opacity(0.16), .clear], startPoint: .top, endPoint: .center)
            ZStack {
                Circle().fill(Color.white.opacity(0.92))
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint.strong)
            }
            .frame(width: 28, height: 28)
            .shadow(color: HomeDesign.Color.ink900.opacity(0.12), radius: 3, x: 0, y: 1)
            .padding(HomeDesign.Spacing.sm)
        }
        .frame(height: 96)
        .clipped()
    }

    private var gradientCover: some View {
        ZStack {
            LinearGradient(colors: [tint.strong, tint.strong.opacity(0.7), tint.soft], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: tint.strong.opacity(0.4), radius: 8, x: 0, y: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 96)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.sm) {
            Text(bucket.name)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(bucket.count)")
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(tint.strong)
                Text("개")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textFaint)
                Spacer(minLength: 0)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(HomeDesign.Color.ink100.opacity(0.7))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.strong, tint.strong.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(proxy.size.width * CGFloat(bucket.count) / CGFloat(maxCount), 8))
                }
            }
            .frame(height: 4)
        }
        .padding(HomeDesign.Spacing.md)
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
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .frame(width: 38, height: 38)
                .background(Circle().fill(HomeDesign.Color.surface).shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 6, x: 0, y: 2))
                .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
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
