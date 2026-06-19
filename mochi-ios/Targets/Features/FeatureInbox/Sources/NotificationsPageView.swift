import SwiftUI
import ComposableArchitecture
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
                    SentNotificationRow(entry: entry)
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

/// 보낸 알림 1건 — 좌측 종류 아이콘 + title/body + 발송 시각 + opened/dismissed 상태 칩.
/// 액션 없음(읽기 전용) — "이미 보낸 것"의 기록이라 조정 대상이 아니다.
private struct SentNotificationRow: View {
    let entry: SentNotificationDTO

    var body: some View {
        HStack(alignment: .top, spacing: HomeDesign.Spacing.md) {
            kindIcon

            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.system(size: 14.5, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
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
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.md, style: .continuous)
                .stroke(HomeDesign.Color.border, lineWidth: 1)
        )
        // 안 열어본 알림은 살짝 강조(왼쪽 보라 띠) — "아직 안 본 것"을 부드럽게 드러낸다.
        .overlay(alignment: .leading) {
            if status == .unread {
                Capsule()
                    .fill(HomeDesign.Color.purple400)
                    .frame(width: 3)
                    .padding(.vertical, HomeDesign.Spacing.sm)
                    .padding(.leading, 1)
            }
        }
        .cardShadow()
        .accessibilityElement(children: .combine)
    }

    /// 종류별 아이콘 타일 — deadline(마감)/nudge(일정)/recall(회수)/그외.
    private var kindIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HomeDesign.Radius.sm, style: .continuous)
                .fill(kindTint.opacity(0.14))
            Image(systemName: kindSymbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(kindTint)
        }
        .frame(width: 40, height: 40)
    }

    private var kindSymbol: String {
        switch entry.kind {
        case "deadline": return "flag.fill"
        case "nudge": return "calendar"
        case "recall": return "sparkles"
        default: return "bell.fill"
        }
    }

    private var kindTint: Color {
        switch entry.kind {
        case "deadline": return HomeDesign.Color.peach400
        case "nudge": return HomeDesign.Color.sky400
        case "recall": return HomeDesign.Color.purple500
        default: return HomeDesign.Color.purple400
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
