import ComposableArchitecture
import CoreAuth
import DesignSystem
import SwiftUI

/// 로그인 진입 화면 — 시안 그대로 보라/연보라 그라데이션 + 모찌 캐릭터 + Apple/Google 버튼 + 약관 푸터.
public struct LoginView: View {
    @Bindable var store: StoreOf<LoginFeature>
    @State private var legalPage: LegalPage?

    public init(store: StoreOf<LoginFeature>) {
        self.store = store
    }

    public var body: some View {
        ZStack {
            backgroundGradient.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 48)
                    .padding(.horizontal, 24)

                Spacer(minLength: 16)

                Image("LoginMochi")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)
                    .padding(.vertical, 8)

                Spacer(minLength: 16)

                buttons
                    .padding(.horizontal, 24)

                footer
                    .padding(.top, 20)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert($store.scope(state: \.alert, action: \.alert))
        .sheet(item: $legalPage) { page in
            NavigationStack {
                LegalWebView(url: page.url)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle(page.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("닫기") { legalPage = nil }
                        }
                    }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("모찌에 오신 것을")
            }
            HStack(spacing: 8) {
                Text("환영해요!")
                Text("\u{1F44B}")  // 👋
            }
        }
        .font(.system(size: 28, weight: .heavy, design: .rounded))
        .foregroundStyle(Self.titleColor)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: - Buttons

    private var buttons: some View {
        VStack(spacing: 12) {
            providerButton(
                kind: .apple,
                title: "Apple로 계속하기",
                background: .black,
                foreground: .white
            ) {
                appleLogo
            }

            providerButton(
                kind: .google,
                title: "Google로 계속하기",
                background: .white,
                foreground: Self.titleColor,
                borderColor: Color.black.opacity(0.05)
            ) {
                googleLogo
            }

            Button("또는 이메일로 계속하기") {
                // 별도 마일스톤 — 현재 마일스톤에선 noop.
            }
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(Self.mutedTextColor)
            .padding(.top, 10)
            .disabled(true)
            .opacity(0.55)

            #if DEBUG
            devLoginButton
                .padding(.top, 4)
            #endif
        }
    }

    #if DEBUG
    /// Debug 빌드 한정. 백엔드 ``POST /auth/dev`` (environment=local) 로 즉시 로그인.
    /// 운영 빌드에는 컴파일되지 않으며, 백엔드도 503 으로 거부한다.
    private var devLoginButton: some View {
        Button {
            store.send(.signInTapped(.dev))
        } label: {
            HStack(spacing: 8) {
                if store.inFlightProvider == .dev {
                    ProgressView().progressViewStyle(.circular).tint(Self.titleColor)
                } else {
                    Image(systemName: "ladybug.fill")
                        .imageScale(.small)
                }
                Text("임시 로그인 (dev)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Self.titleColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .stroke(Self.titleColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy && store.inFlightProvider != .dev)
        .opacity(store.isBusy && store.inFlightProvider != .dev ? 0.5 : 1.0)
        .accessibilityLabel(Text("임시 로그인 (개발용)"))
    }
    #endif

    private func providerButton<Icon: View>(
        kind: LoginFeature.AuthProviderKind,
        title: String,
        background: Color,
        foreground: Color,
        borderColor: Color = .clear,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            store.send(.signInTapped(kind))
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    if store.inFlightProvider == kind {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(foreground)
                    } else {
                        icon()
                    }
                }
                .frame(width: 22, height: 22)

                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(foreground)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(borderColor, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 6)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.isBusy)
        .opacity(store.isBusy && store.inFlightProvider != kind ? 0.5 : 1.0)
        .accessibilityLabel(Text(title))
    }

    private var appleLogo: some View {
        Image(systemName: "applelogo")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
    }

    /// Google 공식 4색 "G" 로고 (Assets: GoogleLogo — 브랜딩 가이드라인 SVG 원본, 색·비율 변경 금지).
    private var googleLogo: some View {
        Image("GoogleLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 18, height: 18)
    }

    // MARK: - Footer

    private var footer: some View {
        Text(
            "로그인하면 서비스 [이용약관](mochi-legal://terms) 및 [개인정보처리방침](mochi-legal://privacy)에 동의하는 것으로 간주됩니다."
        )
        .font(.system(size: 11, weight: .regular, design: .rounded))
        .foregroundStyle(Self.footerColor)
        .tint(Self.titleColor)
        .multilineTextAlignment(.center)
        .lineSpacing(2)
        .environment(\.openURL, OpenURLAction { url in
            switch url.host {
            case "terms": legalPage = LegalPage(title: "이용약관", url: LegalLinks.terms)
            case "privacy": legalPage = LegalPage(title: "개인정보처리방침", url: LegalLinks.privacy)
            default: return .systemAction
            }
            return .handled
        })
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
                .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.45),
                .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Palette

    private static let titleColor = Color(red: 0.21, green: 0.20, blue: 0.45)
    private static let mutedTextColor = Color(red: 0.36, green: 0.34, blue: 0.55)
    private static let footerColor = Color(red: 0.55, green: 0.55, blue: 0.70)
}

#if DEBUG
#Preview {
    LoginView(
        store: Store(initialState: LoginFeature.State()) {
            LoginFeature()
        }
    )
}
#endif
