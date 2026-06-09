import SwiftUI
import PhotosUI
import UIKit
import ComposableArchitecture
import CoreDomain
import CorePersistence
import DesignSystem

/// 모찌 홈 화면 — "자동성의 예외 처리" 인박스 (docs/PRODUCT.md §8.4).
///
/// 위 → 아래:
///  - ① 지금 확인해 주세요        모찌가 혼자 정하기 애매한 것(needsReview)
///  - ③ 최근에 보낸 것들          정리 대상 아닌 안전망(recent)
///  - ② 모찌가 정리하고 있어요     분석 응답 대기(analyzing), 맨 하단·기본 접힘
/// 우하단 플로팅 버튼(+)이 빠른 입력 — 메모·URL·사진(이미지/카메라)을 한 버튼에 모은다.
/// 4-Intent 라벨은 노출하지 않고 행동으로만 드러난다.
/// 자연어 회수(질문)는 홈에 진입점을 두지 않고 채팅·검색 탭이 담당한다.
public struct HomeView: View {
    
    @Bindable public var store: StoreOf<HomeFeature>
    @FocusState private var quickMemoFocused: Bool
    /// 사진 라이브러리 picker 선택 항목 (선택 후 JPEG 로 변환해 store 로 보낸 뒤 nil 로 리셋).
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isPhotoLibraryPresented = false
    @State private var isCameraPresented = false
    /// 플로팅 버튼(+)을 탭하면 뜨는 커스텀 입력 모달 표시 여부 (순수 UI 상태).
    @State private var isComposeMenuPresented = false
    /// 선택된 이미지 — 메모 입력 시트로 넘긴다(ShareExt 처럼 사진+간단 메모). nil 이면 시트 미표시.
    @State private var pendingImage: PendingImage?
    @State private var imageMemoText = ""
    /// 카메라 촬영 결과 임시 보관 — fullScreenCover 가 완전히 닫힌 뒤 메모 시트를 띄우기 위함.
    @State private var capturedCameraData: Data?
    
    public init(store: StoreOf<HomeFeature>) {
        self.store = store
    }
    
    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            backgroundLayer.ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: HomeDesign.Spacing.xl) {
                    chatRecallSection
                        .padding(.top, HomeDesign.Spacing.lg)
                    weeklyReplayCard
                    needsReviewPrompt
                    recentSection
                    processingSection
                    //                    settingsFooter
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
                .padding(.top, HomeDesign.Spacing.md)
                // 우하단 플로팅 버튼에 마지막 섹션이 가리지 않도록 하단 여백 확보.
                .padding(.bottom, 88)
            }
            .refreshable {
                await store.send(.refresh).finish()
            }
            
            // 모달 바깥(dim)을 탭하면 닫힌다.
            if isComposeMenuPresented {
                HomeDesign.Color.ink900.opacity(0.22)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeComposeMenu() }
            }
            
            VStack(alignment: .trailing, spacing: HomeDesign.Spacing.md) {
                if isComposeMenuPresented {
                    composeMenuCard
                        .transition(
                            .scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity)
                        )
                }
                floatingActionButton
            }
            .padding(.trailing, HomeDesign.Spacing.xl)
            .padding(.bottom, HomeDesign.Spacing.lg)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        // 홈 토큰(HomeDesign)이 light 하드코딩이라 다크모드에선 배경만 흰색이고
        // 시스템 placeholder/텍스트색이 어긋나 안 보인다 → 홈은 light 로 고정한다.
        .preferredColorScheme(.light)
        .task { store.send(.onAppear) }
        .alert($store.scope(state: \.deleteAlert, action: \.deleteAlert))
        .sheet(isPresented: $store.isComposingMemo) { memoComposeSheet }
        .sheet(isPresented: $store.isNeedsReviewModalPresented) { needsReviewSheet }
        .sheet(item: $pendingImage) { pending in imageMemoSheet(pending) }
        .photosPicker(isPresented: $isPhotoLibraryPresented, selection: $selectedPhotoItem, matching: .images)
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let jpeg = image.jpegData(compressionQuality: 0.9) {
                    // 바로 ingest 하지 않고 메모 입력 시트로 — 사용자가 사진에 메모를 덧붙일 수 있게.
                    pendingImage = PendingImage(data: jpeg)
                }
                selectedPhotoItem = nil
            }
        }
        // 카메라가 닫히는 전환과 메모 시트가 겹치지 않도록, 촬영 데이터를 임시 보관했다가
        // fullScreenCover 의 onDismiss 에서 메모 시트를 띄운다.
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
    
    // MARK: - 플로팅 입력 버튼 + 커스텀 입력 모달 (메모 · URL · 이미지 · 카메라)
    
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
                    // 브랜드 그라데이션으로 입체감 (DESIGN.md: CTA 는 그라데이션 허용).
                        .fill(
                            LinearGradient(
                                colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    // DESIGN.md shadow.softPurple — 떠 있는 브랜드 CTA(그림자가 원형을 따라가게 배경에 붙임).
                        .shadow(color: HomeDesign.Color.purple500.opacity(0.40), radius: 14, x: 0, y: 8)
                )
            // 모달이 열리면 + 를 45° 돌려 × 처럼 보이게 한다(닫기 어포던스).
                .rotationEffect(.degrees(isComposeMenuPresented ? 45 : 0))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(isComposeMenuPresented ? "입력 메뉴 닫기" : "기록 남기기")
    }
    
    /// + 버튼 위에 뜨는 입력 모달. 입력 수단을 파스텔 색으로 구분하고(메모=purple·이미지=mint·
    /// 카메라=sky), 탭하면 모달을 닫고 각 입력 경로로 연결한다.
    private var composeMenuCard: some View {
        VStack(spacing: 0) {
            composeMenuRow(
                icon: "square.and.pencil",
                tint: HomeDesign.Color.purple500, tintSoft: HomeDesign.Color.purple50,
                title: "메모·링크 남기기", subtitle: "생각나는 걸 빠르게"
            ) { closeComposeMenu(); store.isComposingMemo = true }
            
            rowDivider
            composeMenuRow(
                icon: "photo",
                tint: HomeDesign.Color.mint400, tintSoft: HomeDesign.Color.mint100,
                title: "이미지에서 선택", subtitle: "갤러리에서 가져오기"
            ) { closeComposeMenu(); isPhotoLibraryPresented = true }
            
            // 카메라가 없는 환경(시뮬레이터)에선 항목을 숨겨 빈 화면·크래시를 막는다.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                rowDivider
                composeMenuRow(
                    icon: "camera",
                    tint: HomeDesign.Color.sky400, tintSoft: HomeDesign.Color.sky100,
                    title: "카메라로 촬영", subtitle: "지금 바로 찍기"
                ) { closeComposeMenu(); isCameraPresented = true }
            }
        }
        .padding(.vertical, HomeDesign.Spacing.sm)
        .frame(width: 264)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.xl, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        // DESIGN.md shadow.elevated — 떠 있는 모달/팝오버.
        .shadow(color: HomeDesign.Color.ink900.opacity(0.12), radius: 28, x: 0, y: 12)
    }
    
    /// 아이콘 원(38) 끝선에 맞춰 divider 를 들여써 텍스트 라인과 정렬한다.
    private var rowDivider: some View {
        Rectangle()
            .fill(HomeDesign.Color.border)
            .frame(height: 1)
            .padding(.leading, HomeDesign.Spacing.lg + 38 + HomeDesign.Spacing.md)
    }
    
    private func composeMenuRow(
        icon: String,
        tint: SwiftUI.Color,
        tintSoft: SwiftUI.Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
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
            // 터치 영역 44pt 이상 보장 (DESIGN.md §10.1).
            .frame(minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func closeComposeMenu() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isComposeMenuPresented = false
        }
    }
    
    // MARK: - 메모 작성 시트
    
    private var memoComposeSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                // 제목을 콘텐츠 안으로 내려 입력 영역과 한 덩어리로 보이게 한다.
                Text("빠르게 남기기")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                
                // 입력 카드가 남은 공간을 채워 키보드 바로 위까지 닿게 한다(빈 공간 제거).
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
                    .disabled(!canSubmit || store.isSaving)
                }
            }
            .task { quickMemoFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - 사진 + 메모 시트 (ShareExt 의 사진+메모 흐름과 동일)
    
    /// 선택한 이미지를 보여주고 간단한 메모(선택)를 받는다. 저장 시 `imagePicked` 로 ingest.
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
                        .overlay(
                            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                                .stroke(HomeDesign.Color.border, lineWidth: 1)
                        )
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
    
    // MARK: - Background (F2F4F7 기조 + 상단 옅은 라벤더 글로우)
    
    private var backgroundLayer: some View {
        ZStack {
            HomeDesign.Color.bg
            
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.35),
                    HomeDesign.Color.purple100.opacity(0.12),
                    Color.white.opacity(0.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
    
    private var canSubmit: Bool {
        !store.quickMemoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // MARK: - 채팅 회수 진입점 (구성만, 실제 채팅 미구현)
    
    private var chatRecallSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.xs) {
                    Text("어떤 기억을 찾아드릴까요?")
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                    Text("모찌에게 물어보면 빠르게 찾아드려요.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
                Spacer()
                settingsFooter
            }.frame(maxWidth: .infinity, alignment: .leading)
            
            
            HStack(spacing: HomeDesign.Spacing.md) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .frame(width: 20)
                TextField("", text: $store.chatDraft, axis: .vertical)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .lineLimit(1...3)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .tint(HomeDesign.Color.purple500)
                Button {
                    store.send(.chatSubmitTapped)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .shadow(color: HomeDesign.Color.purple500.opacity(0.32), radius: 12, x: 0, y: 7)
                }
                .buttonStyle(PressableStyle())
                .disabled(store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(store.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1)
            }
            .padding(.leading, HomeDesign.Spacing.lg)
            .padding(.trailing, HomeDesign.Spacing.sm)
            .padding(.vertical, HomeDesign.Spacing.sm)
            .frame(minHeight: 48)
            .background(
                Capsule(style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
            )
            .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 18, x: 0, y: 8)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HomeDesign.Spacing.sm) {
                    suggestionChip(icon: "mappin.and.ellipse", text: "역삼동 데이트 코스 추천해줘")
                    suggestionChip(icon: "calendar", text: "민수랑 언제 만나기로 했지?")
                    suggestionChip(icon: "car.fill", text: "자동차 배터리 교체 방법 다시 보여줘")
                }
                .padding(.horizontal, HomeDesign.Spacing.xl)
            }
            .padding(.horizontal, -HomeDesign.Spacing.xl)
        }
    }
    
    private func suggestionChip(icon: String, text: String) -> some View {
        Button {
            store.send(.suggestedQuestionTapped(text))
        } label: {
            HStack(spacing: HomeDesign.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                Text(text)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(HomeDesign.Color.purple600)
            .padding(.horizontal, HomeDesign.Spacing.md)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(HomeDesign.Color.purple100.opacity(0.64))
            )
        }
        .buttonStyle(PressableStyle())
    }
    
    // MARK: - 이번주 기억 리플레이
    
    private var weeklyReplayCard: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            Text("이번주에 \(store.weeklyRecordCount)개의 기억을 저장했어요")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .lineSpacing(3)
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white, HomeDesign.Color.purple50, HomeDesign.Color.sky100.opacity(0.42)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                replayParticles
                
                
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                    VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                        replayCategoryList
                        
                        
                        HStack {
                            Spacer()
                            Button {
                                store.send(.weeklyDigestTapped)
                            } label: {
                                HStack(spacing: HomeDesign.Spacing.sm) {
                                    Text("이번주 정리 보기")
                                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .bold))
                                }
                                .foregroundStyle(HomeDesign.Color.purple600)
                                .padding(.horizontal, HomeDesign.Spacing.md)
                                .padding(.vertical, HomeDesign.Spacing.md)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(HomeDesign.Color.surface.opacity(0.92))
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .stroke(HomeDesign.Color.purple200, lineWidth: 1.3)
                                )
                            }
                            .buttonStyle(PressableStyle())
                        }
                        
                    }
                }
                .padding(HomeDesign.Spacing.xl)
                .zIndex(1)
                Image("mochi2")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .shadow(color: HomeDesign.Color.purple500.opacity(0.16), radius: 18, x: 0, y: 10)
            }
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .stroke(HomeDesign.Color.purple100, lineWidth: 1.2)
            )
            .frame(maxWidth: .infinity)
            .cardShadow()
        }
        
    }
    
    private var replayCategoryList: some View {
        VStack(spacing: HomeDesign.Spacing.sm) {
            let categories = store.weeklyTopCategories.isEmpty
            ? [WeeklyCategoryStat(name: "기록", count: store.weeklyRecordCount), WeeklyCategoryStat(name: "기록", count: store.weeklyRecordCount), WeeklyCategoryStat(name: "기록", count: store.weeklyRecordCount)]
            : store.weeklyTopCategories
            ForEach(Array(categories.prefix(3).enumerated()), id: \.element.id) { index, stat in
                GeometryReader { proxy in
                    HStack(spacing: HomeDesign.Spacing.md) {
                        ZStack {
                            Circle().fill(replayTint(index).soft)

                            Image(systemName: replayIcon(index))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(replayTint(index).strong)
                        }
                        .frame(width: 25, height: 25)

                        Text(stat.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("\(stat.count)개")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.purple600)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, HomeDesign.Spacing.md)
                    .padding(.vertical, 9)
                    .frame(
                        minWidth: proxy.size.width * 0.7,
                        maxWidth: proxy.size.width,
                        alignment: .leading
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                            .fill(Color.white.opacity(0.76))
                    )
                }
                .frame(height: 43)
            }
        }
    }
    
    private var replayParticles: some View {
        ZStack {
            // 캐릭터 왼쪽 위
            confetti(
                x: 0.68,
                y: 0.29,
                color: .red,
                size: 12,
                rotation: -42,
                opacity: 0.75
            )
            
            // 캐릭터 중앙 위, 연한 작은 조각
            confetti(
                x: 0.62,
                y: 0.32,
                color: HomeDesign.Color.purple600,
                size: 8,
                rotation: 38,
                opacity: 0.35
            )
            
            // 캐릭터 오른쪽 위, 포인트 핑크
            confetti(
                x: 0.71,
                y: 0.20,
                color: HomeDesign.Color.blush400,
                size: 12,
                rotation: 8,
                opacity: 0.85
            )
            
            // 캐릭터 오른쪽 위 아래쪽, 오렌지
            confetti(
                x: 0.72,
                y: 0.39,
                color: HomeDesign.Color.peach400,
                size: 13,
                rotation: 43,
                opacity: 0.9
            )
            
            // 말풍선 위쪽, 연한 보라
            confetti(
                x: 0.82,
                y: 0.38,
                color: HomeDesign.Color.purple400,
                size: 9,
                rotation: 45,
                opacity: 0.45
            )
            
            // 카드 오른쪽 위
            confetti(
                x: 0.92,
                y: 0.30,
                color: HomeDesign.Color.mint400,
                size: 12,
                rotation: -38,
                opacity: 0.85
            )
        }
        .allowsHitTesting(false)
    }
    
    private func confetti(
        x: CGFloat,
        y: CGFloat,
        color: Color,
        size: CGFloat = 12,
        rotation: Double = 45,
        opacity: Double = 0.8
    ) -> some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(opacity),
                            color.opacity(opacity * 0.65)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size, height: size * 0.72)
                .rotationEffect(.degrees(rotation))
                .position(
                    x: proxy.size.width * x,
                    y: proxy.size.height * y
                )
        }
    }
    private func replayIcon(_ index: Int) -> String {
        ["mappin", "graduationcap", "car.fill"][index % 3]
    }
    
    private func replayTint(_ index: Int) -> (soft: Color, strong: Color) {
        let tints: [(Color, Color)] = [
            (HomeDesign.Color.blush100, HomeDesign.Color.blush400),
            (HomeDesign.Color.purple100, HomeDesign.Color.purple500),
            (HomeDesign.Color.mint100, HomeDesign.Color.mint400),
        ]
        return tints[index % tints.count]
    }
    
    // MARK: - 모찌가 확인이 필요해요
    
    private var confirmSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(
                title: "지금 확인해 주세요",
                trailing: store.needsReview.isEmpty ? nil : "전체 보기",
                subtitle: store.needsReview.isEmpty ? nil : "모찌 혼자 정하기 애매한 것만 모았어요"
            )
            if store.needsReview.isEmpty {
                calmEmpty
            } else {
                NeedsReviewCard(
                    mochiItems: Array(store.needsReview),
                    page: $store.needsReviewPage,
                    onClassify: { id, intent in store.send(.classifyTapped(mochiItemID: id, intent: intent)) },
                    onReanalyze: { id, hint in store.send(.reanalyzeTapped(mochiItemID: id, hint: hint)) },
                    onRetry: { id in store.send(.retryAnalysisTapped(id)) }
                )
            }
        }
    }
    
    @ViewBuilder
    private var needsReviewPrompt: some View {
        if store.needsReview.isEmpty {
            Button {
                store.send(.reviewSummaryTapped)
            } label: {
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                    Text("모찌가 확인이 필요해요")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                    VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                        HStack(alignment: .top, spacing: HomeDesign.Spacing.lg) {
                            ZStack {
                                Circle().fill(HomeDesign.Color.butter50)
                                Image(systemName: "lightbulb.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(HomeDesign.Color.peach400)
                            }
                            .frame(width: 24, height: 24)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(store.needsReview.count)개")
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundStyle(HomeDesign.Color.peach400)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(HomeDesign.Color.cream100))
                                Text("일정인지 할 일인지 애매한 기억이 있어요.\n10초만에 정리할 수 있어요!")
                                    .font(.system(size: 13, weight: .medium, design: .rounded))
                                    .foregroundStyle(HomeDesign.Color.ink700)
                                    .lineSpacing(3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 0) {
                            Spacer()
                            HStack(spacing: HomeDesign.Spacing.sm) {
                                Text("확인하기")
                                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .foregroundStyle(HomeDesign.Color.peach400)
                            .padding(.horizontal, HomeDesign.Spacing.md)
                            .padding(.vertical, HomeDesign.Spacing.md)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(HomeDesign.Color.surface.opacity(0.92))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(HomeDesign.Color.cream200, lineWidth: 1.3)
                            )
                        }
                    }
                    .padding(HomeDesign.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                            .fill(HomeDesign.Color.cream50)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                            .stroke(HomeDesign.Color.cream200, lineWidth: 1)
                    )
                    .cardShadow()
                }
            }
            .buttonStyle(PressableStyle())
        }
    }
    
    private var needsReviewSheet: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: HomeDesign.Spacing.lg) {
                    Text("모찌가 확인이 필요해요")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textPrimary)
                    Text("모찌가 헷갈린 기억만 빠르게 확인해 주세요.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                    NeedsReviewCard(
                        mochiItems: Array(store.needsReview),
                        page: $store.needsReviewPage,
                        onClassify: { id, intent in store.send(.classifyTapped(mochiItemID: id, intent: intent)) },
                        onReanalyze: { id, hint in store.send(.reanalyzeTapped(mochiItemID: id, hint: hint)) },
                        onRetry: { id in store.send(.retryAnalysisTapped(id)) }
                    )
                }
                .padding(HomeDesign.Spacing.xl)
            }
            .background(HomeDesign.Color.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") { store.isNeedsReviewModalPresented = false }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    
    /// ① 빈 상태 — "비는 게 정상". 축하·보상 없이 차분한 상태 패널.
    /// 홈의 기본 화면이므로 비어 있어도 가장 큰 비중을 갖되, 행동을 요구하지 않는다.
    private var calmEmpty: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle().fill(HomeDesign.Color.mint100).frame(width: 50, height: 50)
                Image(systemName: "checkmark")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.mint400)
            }
            VStack(spacing: 5) {
                Text("지금은 확인할 게 없어요")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("모찌가 새로 보낸 기억을 조용히 정리하고 있어요")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xxl + 6)
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .stroke(HomeDesign.Color.border, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        )
    }
    
    // MARK: - ② 모찌가 정리하고 있어요 (analyzing, 접힘)
    
    @ViewBuilder
    private var processingSection: some View {
        if !store.analyzing.isEmpty {
            VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
                Button {
                    store.send(.toggleProcessing, animation: .spring(response: 0.32, dampingFraction: 0.85))
                } label: {
                    HStack(spacing: HomeDesign.Spacing.sm) {
                        ProgressView().controlSize(.mini)
                        Text("모찌가 정리하고 있어요")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                        Text("\(store.analyzing.count)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                            .rotationEffect(.degrees(store.isProcessingExpanded ? 180 : 0))
                    }
                }
                .buttonStyle(.plain)
                
                if store.isProcessingExpanded {
                    AnalyzingCard(mochiItems: Array(store.analyzing))
                }
            }
        }
    }
    
    // MARK: - ③ 최근에 보낸 것들
    
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            SectionHeader(
                title: "최근에 보낸 것들",
                trailing: store.recent.isEmpty ? nil : "전체 보기",
                subtitle: store.recent.isEmpty ? nil : "언제든 다시 열어보거나 되돌릴 수 있어요"
            )
            if store.recent.isEmpty {
                emptyRecent
            } else {
                horizontalCardRow(mochiItems: Array(store.recent))
            }
        }
    }
    
    private var emptyRecent: some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle()
                    .fill(HomeDesign.Color.cream200)
                    .frame(width: 56, height: 56)
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.ink500)
            }
            VStack(spacing: 4) {
                Text("아직 모찌가 없어요")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text("위에서 빠르게 남겨보세요.")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            if hasNoMochiItems {
                Button {
                    store.send(.replayOnboardingTapped)
                } label: {
                    Label("튜토리얼 다시 보기", systemImage: "play.circle.fill")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.purple500)
                        .padding(.horizontal, HomeDesign.Spacing.md)
                        .padding(.vertical, HomeDesign.Spacing.sm)
                        .background(
                            Capsule(style: .continuous)
                                .fill(HomeDesign.Color.purple50)
                        )
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
    
    private var hasNoMochiItems: Bool {
        store.recent.isEmpty && store.analyzing.isEmpty && store.needsReview.isEmpty
    }
    
    private var settingsFooter: some View {
        HStack {
            CircleIconButton(systemName: "gearshape") {
                store.send(.openSettingsTapped)
            }
        }
        .padding(.top, HomeDesign.Spacing.sm)
    }
    
    private func horizontalCardRow(mochiItems: [MochiItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HomeDesign.Spacing.md) {
                ForEach(mochiItems) { mochiItem in
                    RecentMochiCard(
                        mochiItem: mochiItem,
                        onTap: { hero in store.send(.mochiItemTapped(mochiItem.id, hero: hero)) },
                        onDelete: { store.send(.deleteMochiItemTapped(mochiItem.id)) }
                    )
                }
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            // 카드 그림자가 스크롤 영역 상·하단에서 잘리지 않게 세로 여백 확보.
            // RecentMochiCard 그림자(radius 8, y 2)엔 sm(8)이 모자라 잘려서 xl(20)로 키운다.
            // 안쪽 +xl / 바깥 -xl 이라 그림자 여백만 늘고 섹션 간격(레이아웃)은 중립.
            .padding(.vertical, HomeDesign.Spacing.xl)
        }
        .padding(.horizontal, -HomeDesign.Spacing.xl)
        .padding(.vertical, -HomeDesign.Spacing.xl)
    }
}

// MARK: - Section header

private struct SectionHeader: View {
    let title: String
    let trailing: String?
    var subtitle: String? = nil
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .tracking(-0.4)
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            Spacer()
            if let trailing {
                Button(action: {}) {
                    HStack(spacing: 2) {
                        Text(trailing)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(HomeDesign.Color.textMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(HomeDesign.Color.textMuted.opacity(0.7))
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

// MARK: - Circle icon button

private struct CircleIconButton: View {
    let systemName: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HomeDesign.Color.textPrimary)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(HomeDesign.Color.surface)
                        .shadow(color: HomeDesign.Color.ink900.opacity(0.05), radius: 6, x: 0, y: 2)
                )
                .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Input field card (시트 텍스트 입력 영역 공통 스타일)

/// 메모·사진 시트의 텍스트 입력을 연한 라벤더 카드로 감싸 입력 영역을 또렷하게 한다.
private struct InputFieldCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(HomeDesign.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .fill(HomeDesign.Color.purple50)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                    .stroke(HomeDesign.Color.border, lineWidth: 1)
            )
    }
}

// MARK: - Pending image (메모 입력 시트로 넘길 선택 이미지)

/// `.sheet(item:)` 으로 메모 시트를 띄우기 위한 JPEG 래퍼.
private struct PendingImage: Identifiable {
    let id = UUID()
    let data: Data
}

// MARK: - Camera picker (카메라 촬영 → JPEG)

/// `UIImagePickerController(.camera)` 래퍼. 촬영 결과를 JPEG 데이터로 콜백한다.
/// 라이브러리 선택은 SwiftUI `PhotosPicker` 를 직접 쓰고, 카메라만 UIKit 래핑이 필요하다.
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
        
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
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
    HomeView(
        store: Store(initialState: HomeFeature.State()) {
            HomeFeature()
        } withDependencies: {
            $0.mochiItemRepository = InMemoryMochiItemRepository()
        }
    )
}
