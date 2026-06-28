import SwiftUI
import ComposableArchitecture
import CoreDomain
import CoreNetworking
import DesignSystem

/// 알림 페이지 — 홈 bell 버튼으로 진입. "예정된 알림"/"받은 알림" 2탭.
///
/// **예정 탭**: 홈에서 옮겨온 `UpcomingNotificationsView` 재사용(행·veto·미루기·직접고르기 그대로).
/// **지난 탭**: 모찌가 이미 보낸 알림의 읽기 전용 타임라인 — 발송 시각 + opened/dismissed 상태 칩.
///
/// 상단 segmented Picker 로 탭 전환(InboxView 패턴). NavigationStack title "알림".
public struct NotificationsPageView: View {

    @Bindable public var store: StoreOf<NotificationsPageFeature>

    public init(store: StoreOf<NotificationsPageFeature>) {
        self.store = store
    }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: HomeDesign.Spacing.xl) {
                segmentedPicker
                content
            }
            .padding(.horizontal, HomeDesign.Spacing.xl)
            .padding(.top, HomeDesign.Spacing.md)
            .padding(.bottom, HomeDesign.Spacing.xxl)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("알림")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
    }

    // MARK: - 배경 (홈과 같은 보라 글로우 톤 — 회수 가족이라는 일관성)

    private var background: some View {
        ZStack {
            HomeDesign.Color.bg
            LinearGradient(
                colors: [
                    HomeDesign.Color.purple200.opacity(0.22),
                    HomeDesign.Color.purple100.opacity(0.08),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 280)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - 탭 전환 (segmented)

    private var segmentedPicker: some View {
        Picker("알림 종류", selection: $store.selectedTab) {
            Text("예정된 알림").tag(NotificationsPageFeature.Tab.upcoming)
            Text("받은 알림").tag(NotificationsPageFeature.Tab.sent)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - 탭 본문

    @ViewBuilder
    private var content: some View {
        switch store.selectedTab {
        case .upcoming: upcomingTab
        case .sent: sentTab
        }
    }

    // MARK: - 예정 탭 (홈에서 옮겨온 UpcomingNotificationsView 재사용)

    @ViewBuilder
    private var upcomingTab: some View {
        if store.upcoming.isEmpty {
            emptyState(
                icon: "bell.badge",
                title: "예정된 알림이 없어요",
                subtitle: "마감·일정이 생기면 모찌가 미리 챙겨 여기 올려둘게요."
            )
        } else {
            UpcomingNotificationsView(
                entries: store.upcoming,
                thumbnails: store.thumbnails,
                categories: store.categories,
                onVeto: { eventID in store.send(.upcomingVetoed(eventID: eventID), animation: .spring(response: 0.4, dampingFraction: 0.85)) },
                onReschedule: { eventID, fireAt in store.send(.upcomingRescheduled(eventID: eventID, fireAt: fireAt), animation: .spring(response: 0.5, dampingFraction: 0.88)) }
            )
        }
    }

    // MARK: - 지난 탭 (읽기 전용 sent 타임라인)

    @ViewBuilder
    private var sentTab: some View {
        if store.sent.isEmpty {
            emptyState(
                icon: "tray",
                title: "아직 받은 알림이 없어요",
                subtitle: "모찌가 알림을 보내면 여기에 차곡차곡 쌓아둘게요."
            )
        } else {
            VStack(spacing: HomeDesign.Spacing.sm) {
                ForEach(store.sent) { entry in
                    SentNotificationRow(
                        entry: entry,
                        thumbnails: store.thumbnails,
                        categories: store.categories,
                        onTap: { store.send(.sentNotificationTapped(entry), animation: .easeInOut(duration: 0.22)) }
                    )
                }
            }
        }
    }

    // MARK: - 빈손 (탭 공통)

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [HomeDesign.Color.purpleGlow.opacity(0.22), .clear], center: .center, startRadius: 4, endRadius: 50))
                    .frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(HomeDesign.Color.purple400)
            }
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HomeDesign.Spacing.xxl + HomeDesign.Spacing.md)
        .padding(.horizontal, HomeDesign.Spacing.xl)
    }
}

// MARK: - 지난 알림 1행 (읽기 전용)

/// 보낸 알림 1건 — 좌측 캡처 썸네일 + title/body + 발송 시각 + opened/dismissed 상태 칩.
/// 행을 탭하면 원본 기록 상세를 열고 그 알림을 읽음 처리(opened)한다 — 둘러보다 본 것이 회색으로 가라앉는다.
private struct SentNotificationRow: View {
    let entry: SentNotificationDTO
    let thumbnails: [UUID: ImageRef]
    let categories: [UUID: String]
    let onTap: () -> Void

    private var isRead: Bool { status != .unread }

    var body: some View {
        Button(action: onTap) {
            cardContent.contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .cardShadow()
        .opacity(isRead ? 0.72 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityHint("탭하면 원본 기록을 열고 읽음 처리돼요")
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            NotifThumbnail(itemID: entry.itemID, kind: entry.kind, thumbnails: thumbnails, categories: categories)

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: 14.5, weight: isRead ? .semibold : .bold, design: .rounded))
                    .foregroundStyle(isRead ? HomeDesign.Color.textMuted : HomeDesign.Color.textPrimary)
                    .lineLimit(1)

                Text(entry.body)
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: HomeDesign.Spacing.sm) {
                    sentAtLabel
                    statusChip
                }
                .padding(.top, 1)
            }

            Spacer(minLength: 0)
        }
        .padding(HomeDesign.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .fill(isRead ? HomeDesign.Color.ink100.opacity(0.5) : HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(isRead ? Color.clear : HomeDesign.Color.border, lineWidth: 1)
        )
        // 안 읽은 알림만 왼쪽 보라 띠 + 흰 카드. 읽은 알림은 회색·흐리게(dim)로 가라앉혀 한눈에 구분.
        .overlay(alignment: .leading) {
            if !isRead {
                Capsule()
                    .fill(HomeDesign.Color.purple400)
                    .frame(width: 3)
                    .padding(.vertical, HomeDesign.Spacing.sm)
                    .padding(.leading, 1)
            }
        }
    }

    /// 발송 시각 — DueDisplay 와 같은 KST·한국어 절대 포맷("M월 d일 · 오후 9:00").
    private var sentAtLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 9, weight: .bold))
            Text(Self.sentFormatter.string(from: entry.sentAt))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(HomeDesign.Color.ink500)
    }

    // MARK: 상태 (opened > dismissed > unread)

    private enum SentStatus {
        case opened     // 열어봄
        case dismissed  // 무시함(swipe-away)
        case unread     // 안 열어봄
    }

    private var status: SentStatus {
        if entry.openedAt != nil { return .opened }
        if entry.dismissedAt != nil { return .dismissed }
        return .unread
    }

    @ViewBuilder
    private var statusChip: some View {
        switch status {
        case .opened:
            chip(text: "읽음", icon: "checkmark.circle.fill", tint: HomeDesign.Color.mint400)
        case .dismissed:
            chip(text: "지나침", icon: "xmark.circle.fill", tint: HomeDesign.Color.ink500)
        case .unread:
            chip(text: "안 읽음", icon: "circle.dotted", tint: HomeDesign.Color.purple500)
        }
    }

    private func chip(text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, HomeDesign.Spacing.sm)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private static let sentFormatter = DateFormatter.mochiSeoul("M월 d일 · a h:mm")
}

// MARK: - 알림 썸네일 타일 (예정·받음 공용)

/// 알림 행 왼쪽 50px 타일 — 원본 캡처 썸네일(있으면) / 카테고리 색·아이콘(이미지 없고 카테고리 있으면) /
/// 종류 아이콘(둘 다 없으면). 내용으로만 보던 알림을 한눈에 구분하되, 작게 둬서 난잡하지 않게.
struct NotifThumbnail: View {
    let itemID: UUID?
    let kind: String
    let thumbnails: [UUID: ImageRef]
    let categories: [UUID: String]

    private var imageRef: ImageRef? { itemID.flatMap { thumbnails[$0] } }
    private var category: String? { itemID.flatMap { categories[$0] } }

    var body: some View {
        Group {
            if let ref = imageRef {
                LocalThumbnail(
                    relativePath: ref.displayRelativePath,
                    objectKey: ref.objectKey,
                    sha256: ref.sha256,
                    mimeType: ref.mimeType,
                    targetSize: CGSize(width: 110, height: 110),
                    alignment: .center
                ) { fallback }
            } else {
                fallback
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var fallback: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(tint.opacity(0.14))
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        if let category {
            return MochiCategoryPalette.tint(category.unicodeScalars.reduce(into: 0) { $0 += Int($1.value) }).strong
        }
        switch kind {
        case "deadline": return HomeDesign.Color.peach400
        case "nudge": return HomeDesign.Color.sky400
        case "spaced", "recall": return HomeDesign.Color.purple500
        default: return HomeDesign.Color.purple400
        }
    }

    private var symbol: String {
        if let category { return MochiCategoryIcon.icon(for: category, fallbackIndex: 0) }
        switch kind {
        case "deadline": return "flag.fill"
        case "nudge": return "calendar"
        case "spaced", "recall": return "sparkles"
        default: return "bell.fill"
        }
    }
}

// MARK: - Preview

#Preview("예정된 알림") {
    NavigationStack {
        NotificationsPageView(
            store: Store(initialState: NotificationsPageFeature.State()) {
                NotificationsPageFeature()
            }
        )
    }
}

#Preview("받은 알림") {
    NavigationStack {
        NotificationsPageView(
            store: Store(initialState: NotificationsPageFeature.State(selectedTab: .sent)) {
                NotificationsPageFeature()
            }
        )
    }
}
