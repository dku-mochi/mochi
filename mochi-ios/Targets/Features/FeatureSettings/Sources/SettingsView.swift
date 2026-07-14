import SwiftUI
import ComposableArchitecture
import DesignSystem
#if canImport(UIKit)
import UIKit
#endif

public struct SettingsView: View {
    @Bindable public var store: StoreOf<SettingsFeature>
    @Environment(\.openURL) private var openURL
    @State private var legalPage: LegalPage?

    public init(store: StoreOf<SettingsFeature>) { self.store = store }

    public var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                accountSection
                notificationSection
                integrationSection
                privacySection
                infoSection
                logoutSection
                deleteAccountSection
            }
            .padding(.horizontal, HomeDesign.Spacing.lg)
            .padding(.bottom, HomeDesign.Spacing.xxl)
        }
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .preferredColorScheme(.light)
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .task { store.send(.onAppear) }
        .confirmationDialog(
            "정말 탈퇴할까요?",
            isPresented: Binding(get: { store.confirmingDelete }, set: { store.send(.confirmingDeleteChanged($0)) }),
            titleVisibility: .visible
        ) {
            Button("탈퇴하기", role: .destructive) { store.send(.deleteAccountConfirmed) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("지금까지 모은 모든 기억이 사라지고, 되돌릴 수 없어요.")
        }
        .alert(
            "탈퇴하지 못했어요",
            isPresented: Binding(get: { store.deleteAccountError != nil }, set: { if !$0 { store.send(.deleteErrorDismissed) } })
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("계정은 그대로 있어요. 잠시 후 다시 시도해 주세요.")
        }
        .alert(
            "알림 설정을 저장하지 못했어요",
            isPresented: Binding(get: { store.preferenceSaveFailed }, set: { if !$0 { store.send(.preferenceErrorDismissed) } })
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("이전 설정으로 되돌렸어요. 잠시 후 다시 시도해 주세요.")
        }
        .legalSheet(item: $legalPage)
    }

    private var deleteAccountSection: some View {
        Button { store.send(.deleteAccountTapped) } label: {
            HStack(spacing: 6) {
                if store.isDeletingAccount { ProgressView() }
                Text("회원 탈퇴")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textMuted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HomeDesign.Spacing.lg)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .disabled(store.isDeletingAccount)
    }

    // MARK: - 계정

    private var accountSection: some View {
        section("계정") {
            card {
                HStack(spacing: HomeDesign.Spacing.md) {
                    ZStack {
                        Circle().fill(
                            LinearGradient(colors: [HomeDesign.Color.purple400, HomeDesign.Color.purple600],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        Text(avatarInitial)
                            .font(.system(size: 22, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.account?.name ?? "불러오는 중…")
                            .font(.system(size: 17, weight: .heavy, design: .rounded))
                            .foregroundStyle(HomeDesign.Color.textPrimary)
                        if let detail = store.account?.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(HomeDesign.Color.textMuted)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HomeDesign.Spacing.lg)
                .padding(.vertical, HomeDesign.Spacing.lg)
            }
        }
    }

    private var avatarInitial: String {
        guard let first = store.account?.name.first else { return "모" }
        return String(first).uppercased()
    }

    // MARK: - 알림

    private var notificationSection: some View {
        section("알림") {
            card {
                row(
                    icon: "bell.fill", iconFg: HomeDesign.Color.butter400, iconBg: HomeDesign.Color.butter50,
                    title: "알림 권한"
                ) { notificationStatusPill }
                // 서버 전역 선호 — 로드 성공 시에만 표시(실패해도 권한 칩·딥링크는 그대로).
                if let preferences = store.notificationPreferences {
                    rowDivider
                    row(
                        icon: "sparkles", iconFg: HomeDesign.Color.purple500, iconBg: HomeDesign.Color.purple100,
                        title: "먼저 떠올려주는 알림",
                        subtitle: "마감이나 일정, 다시 보면 좋을 기억을 모찌가 먼저 알려드려요"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { preferences.recallEnabled },
                            set: { store.send(.recallNotificationsToggled($0)) }
                        ))
                        .labelsHidden()
                        .tint(HomeDesign.Color.purple500)
                    }
                    rowDivider
                    row(
                        icon: "questionmark.bubble.fill", iconFg: HomeDesign.Color.sky400, iconBg: HomeDesign.Color.sky100,
                        title: "헷갈릴 때 물어보는 알림",
                        subtitle: "어떻게 남길지 애매한 기록만 모찌가 물어봐요"
                    ) {
                        Toggle("", isOn: Binding(
                            get: { preferences.analysisEnabled },
                            set: { store.send(.analysisNotificationsToggled($0)) }
                        ))
                        .labelsHidden()
                        .tint(HomeDesign.Color.purple500)
                    }
                }
                rowDivider
                Button { openSystemSettings() } label: {
                    row(icon: "gearshape.fill", iconFg: HomeDesign.Color.ink500, iconBg: HomeDesign.Color.ink100,
                        title: "iOS 설정에서 관리") { chevron }
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    @ViewBuilder
    private var notificationStatusPill: some View {
        switch store.notificationStatus {
        case .authorized:
            pill("허용됨", fg: HomeDesign.Color.mint400, bg: HomeDesign.Color.mint100)
        case .denied:
            pill("꺼짐", fg: HomeDesign.Color.blush400, bg: HomeDesign.Color.blush100)
        case .notDetermined, .unknown:
            pill("미설정", fg: HomeDesign.Color.textMuted, bg: HomeDesign.Color.ink100)
        }
    }

    // MARK: - 연동

    /// 시스템 캘린더·미리알림 자동 등록 밸브(§1.5 자동 관리) — 설정 재설계 때 빠졌던 토글이
    /// 이번엔 실배선으로 부활. off 는 신규 등록·갱신 중단만(기존 EK 항목 불가침).
    private var integrationSection: some View {
        section("연동") {
            card {
                row(
                    icon: "calendar.badge.checkmark", iconFg: HomeDesign.Color.mint400, iconBg: HomeDesign.Color.mint100,
                    title: "캘린더·미리알림 자동 등록",
                    subtitle: "확정된 일정은 캘린더에, 할 일은 미리알림에 자동으로 등록해요"
                ) {
                    Toggle("", isOn: Binding(
                        get: { store.calendarAutoRegistration },
                        set: { store.send(.calendarAutoRegistrationToggled($0)) }
                    ))
                    .labelsHidden()
                    .tint(HomeDesign.Color.purple500)
                }
            }
        }
    }

    // MARK: - 프라이버시

    private var privacySection: some View {
        section("프라이버시") {
            card {
                row(
                    icon: "lock.shield.fill", iconFg: HomeDesign.Color.mint400, iconBg: HomeDesign.Color.mint100,
                    title: "민감 캡처는 항상 이 기기에만",
                    subtitle: "전화번호·인증번호 등이 감지되면 이 기기 밖으로 내보내지 않아요"
                ) {
                    Toggle("", isOn: Binding(
                        get: { store.sensitiveAlwaysLocalOnly },
                        set: { store.send(.sensitiveLocalOnlyChanged($0)) }
                    ))
                    .labelsHidden()
                    .tint(HomeDesign.Color.purple500)
                }
            }
        }
    }

    // MARK: - 정보

    private var infoSection: some View {
        section("정보") {
            card {
                Button { store.send(.onboardingButtonTapped) } label: {
                    row(icon: "play.circle.fill", iconFg: HomeDesign.Color.sky400, iconBg: HomeDesign.Color.sky100,
                        title: "온보딩 다시 보기") { chevron }
                }
                .buttonStyle(PressableStyle())
                rowDivider
                Button { legalPage = LegalPage(title: "이용약관", url: LegalLinks.terms) } label: {
                    row(icon: "doc.text.fill", iconFg: HomeDesign.Color.ink500, iconBg: HomeDesign.Color.ink100,
                        title: "이용약관") { chevron }
                }
                .buttonStyle(PressableStyle())
                rowDivider
                Button { legalPage = LegalPage(title: "개인정보처리방침", url: LegalLinks.privacy) } label: {
                    row(icon: "hand.raised.fill", iconFg: HomeDesign.Color.ink500, iconBg: HomeDesign.Color.ink100,
                        title: "개인정보처리방침") { chevron }
                }
                .buttonStyle(PressableStyle())
                rowDivider
                row(icon: "number", iconFg: HomeDesign.Color.ink500, iconBg: HomeDesign.Color.ink100,
                    title: "버전") {
                    Text(Self.versionText)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
        }
    }

    // MARK: - 로그아웃

    private var logoutSection: some View {
        card {
            Button(role: .destructive) { store.send(.logoutButtonTapped) } label: {
                Text("로그아웃")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.blush400)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HomeDesign.Spacing.md)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
        }
        .padding(.top, HomeDesign.Spacing.lg)
    }

    // MARK: - 빌딩 블록

    private func section<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .padding(.leading, 6)
                .padding(.top, HomeDesign.Spacing.lg)
                .padding(.bottom, HomeDesign.Spacing.sm)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(
                RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                    .fill(HomeDesign.Color.surface)
            )
            .cardShadow()
    }

    private func row<Trailing: View>(
        icon: String, iconFg: Color, iconBg: Color,
        title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: HomeDesign.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(iconBg)
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing()
        }
        .padding(.horizontal, HomeDesign.Spacing.lg)
        .padding(.vertical, HomeDesign.Spacing.md)
        .contentShape(Rectangle())
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(HomeDesign.Color.textFaint)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(HomeDesign.Color.border)
            .frame(height: 0.5)
            .padding(.leading, HomeDesign.Spacing.lg + 30 + HomeDesign.Spacing.md)
    }

    private func pill(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    private func openSystemSettings() {
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #endif
    }

    /// 앱 버전 — "v{marketing} ({build})". Info.plist `$(MARKETING_VERSION)`/`$(CURRENT_PROJECT_VERSION)`.
    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "v\(marketing) (\(build))"
    }

}
