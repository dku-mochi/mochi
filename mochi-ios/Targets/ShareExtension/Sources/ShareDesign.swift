import SwiftUI
import CoreDomain
import CorePersistence

/// ShareExtension 전용 디자인 토큰 + 공통 컴포넌트.
///
/// `FeatureOnboarding.OnboardingTheme` 와 동일한 라벤더 톤. 모듈 경계상 직접 import 불가
/// 라 RGB 값을 정적 상수로 복제한다 (`BackTapSnippetView` 도 같은 패턴).
/// `OnboardingTheme` 변경 시 본 파일도 sync 필요.
enum ShareDesign {
    static let backgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(red: 0.84, green: 0.83, blue: 0.96), location: 0.0),
            .init(color: Color(red: 0.89, green: 0.87, blue: 0.96), location: 0.45),
            .init(color: Color(red: 0.93, green: 0.88, blue: 0.94), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let title          = Color(red: 0.21, green: 0.20, blue: 0.45)
    static let subtitle       = Color(red: 0.36, green: 0.34, blue: 0.55)
    static let muted          = Color(red: 0.55, green: 0.55, blue: 0.70)
    static let primary        = Color(red: 0.55, green: 0.46, blue: 0.93)
    static let primaryShadow  = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.30)
    static let cardFill       = Color.white.opacity(0.55)
    static let cardStroke     = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.15)
}

// MARK: - Primary CTA

/// 보라 채움 라운드 primary 버튼 — `OnboardingButton` 과 동일 톤.
struct SharePrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 17)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(ShareDesign.primary)
                )
                .shadow(color: ShareDesign.primaryShadow, radius: 16, x: 0, y: 10)
        }
        .buttonStyle(ScalePressStyle())
        .accessibilityLabel(Text(title))
    }
}

// MARK: - Source app chip

/// "Safari에서 캡처" — 단축어가 sentinel 로 보낸 출처앱(자동신호)을 사용자 메모와
/// 시각적으로 구분해 보여주는 칩. 백엔드 `text` 에는 정규화 1줄로 따로 합쳐진다.
struct SourceAppChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.dashed.inset.filled")
                .font(.system(size: 12, weight: .semibold))
            Text("\(name)에서 캡처")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(ShareDesign.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.55))
                .overlay(Capsule().stroke(ShareDesign.cardStroke, lineWidth: 1))
        )
        .accessibilityLabel(Text("\(name)에서 캡처됨"))
    }
}

// MARK: - Close button

/// 좌상단 X 닫기 — Material 배경.
struct ShareCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ShareDesign.subtitle)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(Text("취소"))
    }
}

// MARK: - Memo field

/// 흰 반투명 카드 위에 얹는 메모 입력 필드.
///
/// `compact` = true 면 한~두 줄짜리 슬림 모드 (스크린샷이 대부분 차지하는 케이스 — height ≈ 56pt).
/// false 면 3~6줄짜리 펼친 모드 (텍스트/URL 위주 케이스).
///
/// **레이아웃 주의**: 배경 `RoundedRectangle` 은 반드시 `.background()` modifier 로 둔다.
/// `ZStack` 안에 child 로 두면 Shape 의 greedy 한 성격 때문에 부모 VStack 의 가용 공간을
/// 다 잡아먹어 (이미지와 50:50 으로 나눠 가져) 메모가 비대해진다.
struct ShareMemoField: View {
    @Binding var memo: String
    var compact: Bool = false

    private var radius: CGFloat { compact ? 14 : 14 }
    private var vPad: CGFloat   { compact ? 14 : 12 }
    private var hPad: CGFloat   { compact ? 16 : 14 }
    private var minH: CGFloat   { compact ? 56 : 80 }

    private var memoFont: Font {
        compact
            ? .system(.subheadline, design: .rounded).weight(.medium)
            : .system(.callout, design: .rounded)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if memo.isEmpty {
                Text("메모 추가하기 (선택)")
                    .font(memoFont)
                    .foregroundStyle(ShareDesign.subtitle.opacity(0.7))
                    .padding(.horizontal, hPad + 2)
                    .padding(.vertical, vPad)
                    .allowsHitTesting(false)
            }

            TextField("", text: $memo, axis: .vertical)
                .font(memoFont)
                .foregroundStyle(ShareDesign.title)
                .lineLimit(compact ? 1...2 : 3...6)
                .padding(.horizontal, hPad)
                .padding(.vertical, vPad)
        }
        .frame(minHeight: minH, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(ShareDesign.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(ShareDesign.cardStroke, lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview image

/// App Group container 의 captures/ PNG 를 로드해 흰 stroke + 그림자를 두른 RoundedRect 로 표시.
///
/// 가로 폭은 부모 너비를 가득 채우고, 세로는 이미지 본래 비율 그대로 (scaledToFit).
/// fallback placeholder 도 스크린샷 비율 (9:19.5) 을 따라 짧은 가로 직사각형으로 어색하게
/// 잡히지 않게 한다.
struct SharePreviewImage: View {
    let imageRef: ImageRef

    /// 일반적인 스크린샷 비율 — iPhone Portrait safe-area (9:19.5).
    /// fallback placeholder 와 정상 이미지 양쪽의 시각 균형을 위해 동일 비율을 기본값으로 둔다.
    private static let fallbackAspect: CGFloat = 9.0 / 19.5

    var body: some View {
        Group {
            if let uiImage = loadImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.10), radius: 14, x: 0, y: 8)
            } else {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.5))
                    .aspectRatio(Self.fallbackAspect, contentMode: .fit)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundStyle(ShareDesign.subtitle)
                    )
            }
        }
    }

    private func loadImage() -> UIImage? {
        let url = AppGroup.containerURL.appendingPathComponent(imageRef.relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}

// MARK: - Press style

private struct ScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
