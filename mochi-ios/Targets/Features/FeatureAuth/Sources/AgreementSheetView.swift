import DesignSystem
import SwiftUI

/// 최초 로그인 전 약관·개인정보처리방침 **명시 동의** half sheet.
///
/// 한국 개인정보보호법상 묵시적 "동의 간주"는 명확한 동의로 인정받기 어려워, 체크 + "동의하고 계속"으로
/// 받는다. 약관/처리방침은 같은 모달 안에서 ``legalSheet`` 로 열람. 동의 저장은 ``LoginFeature``.
struct AgreementSheetView: View {
    let onAgree: () -> Void

    @State private var checked = false
    @State private var legalPage: LegalPage?
    @State private var agreedTrigger = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            legalCard
                .padding(.top, 24)

            consentToggle
                .padding(.top, 14)

            Spacer(minLength: 24)

            ctaButton
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HomeDesign.Color.bg.ignoresSafeArea())
        .legalSheet(item: $legalPage)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("시작하기 전에 잠깐")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textPrimary)
            Text("이용약관과 개인정보처리방침을 확인하고 동의하면 바로 시작해요.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(HomeDesign.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 약관 카드

    private var legalCard: some View {
        VStack(spacing: 0) {
            legalRow(title: "이용약관", icon: "doc.text.fill", url: LegalLinks.terms)
            Rectangle()
                .fill(HomeDesign.Color.border)
                .frame(height: 0.5)
                .padding(.leading, 48)
            legalRow(title: "개인정보처리방침", icon: "hand.raised.fill", url: LegalLinks.privacy)
        }
        .background(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .fill(HomeDesign.Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous)
                .strokeBorder(HomeDesign.Color.border, lineWidth: 1)
        )
        .cardShadow()
    }

    private func legalRow(title: String, icon: String, url: URL) -> some View {
        Button { legalPage = LegalPage(title: title, url: url) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.textFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - 동의 체크 (체크박스 ↔ 라벨 세로 중앙 정렬)

    private var consentToggle: some View {
        Button {
            checked.toggle()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 23))
                    .foregroundStyle(checked ? HomeDesign.Color.purple500 : HomeDesign.Color.textFaint)
                    .contentTransition(.symbolEffect(.replace))
                    .scaleEffect(checked ? 1.0 : 0.9)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: checked)
                Text("[필수] 이용약관 및 개인정보처리방침에 동의합니다")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: checked)
        .accessibilityLabel(Text("필수 약관 동의"))
        .accessibilityValue(Text(checked ? "동의함" : "동의 안 함"))
    }

    // MARK: - CTA

    private var ctaButton: some View {
        Button {
            agreedTrigger.toggle()
            onAgree()
        } label: {
            Text("동의하고 시작하기")
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(HomeDesign.Color.purple500)
                        .shadow(
                            color: HomeDesign.Color.purple500.opacity(checked ? 0.30 : 0),
                            radius: 14, x: 0, y: 8
                        )
                )
                .opacity(checked ? 1.0 : 0.45)
                .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: checked)
        }
        .buttonStyle(PressableStyle())
        .disabled(!checked)
        .sensoryFeedback(.success, trigger: agreedTrigger)
    }
}
