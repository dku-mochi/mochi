import SwiftUI
import CoreDomain
import CorePersistence

/// 라이트/다크 듀얼 토큰 — `UIColor(dynamicProvider:)` 로 trait 변화에 자동 추종한다.
private extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// ShareExtension 전용 디자인 토큰 + 공통 컴포넌트.
///
/// 라이트는 `FeatureOnboarding.OnboardingTheme` 와 동일한 라벤더 톤. 모듈 경계상 직접 import 불가
/// 라 RGB 값을 정적 상수로 복제한다 (`BackTapSnippetView` 도 같은 패턴).
/// `OnboardingTheme` 변경 시 본 파일도 sync 필요.
/// 다크는 ShareExtension 고유 — 백탭 캡처는 야간 사용 빈도가 높아 밤에 화면이 확 밝아지는
/// 이질감을 없앤다 (깊은 인디고·플럼 톤으로 라벤더 정체성 유지).
enum ShareDesign {
    static let backgroundGradient = LinearGradient(
        stops: [
            .init(color: Color(
                light: Color(red: 0.84, green: 0.83, blue: 0.96),
                dark: Color(red: 0.11, green: 0.10, blue: 0.19)
            ), location: 0.0),
            .init(color: Color(
                light: Color(red: 0.89, green: 0.87, blue: 0.96),
                dark: Color(red: 0.13, green: 0.11, blue: 0.21)
            ), location: 0.45),
            .init(color: Color(
                light: Color(red: 0.93, green: 0.88, blue: 0.94),
                dark: Color(red: 0.16, green: 0.12, blue: 0.21)
            ), location: 1.0),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static let title = Color(
        light: Color(red: 0.21, green: 0.20, blue: 0.45),
        dark: Color(red: 0.92, green: 0.91, blue: 0.99)
    )
    static let subtitle = Color(
        light: Color(red: 0.36, green: 0.34, blue: 0.55),
        dark: Color(red: 0.73, green: 0.71, blue: 0.87)
    )
    static let muted = Color(
        light: Color(red: 0.55, green: 0.55, blue: 0.70),
        dark: Color(red: 0.58, green: 0.57, blue: 0.72)
    )
    /// 다크에선 한 단계 밝혀 어두운 배경 위 가독성을 지킨다.
    static let primary = Color(
        light: Color(red: 0.55, green: 0.46, blue: 0.93),
        dark: Color(red: 0.66, green: 0.59, blue: 0.98)
    )
    /// 다크에선 그림자가 안 보이므로 글로우처럼 더 진하게.
    static let primaryShadow = Color(
        light: Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.30),
        dark: Color(red: 0.45, green: 0.36, blue: 0.85).opacity(0.50)
    )
    static let cardFill = Color(
        light: Color.white.opacity(0.55),
        dark: Color.white.opacity(0.07)
    )
    static let cardSolid = Color(
        light: Color.white.opacity(0.92),
        dark: Color(red: 0.21, green: 0.19, blue: 0.31)
    )
    static let cardStroke = Color(
        light: Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.15),
        dark: Color.white.opacity(0.10)
    )
    /// 출처칩 텍스트 — 라이트는 라벤더 위 WCAG AA 확보용 진보라(#4C3EAD), 다크는 연보라.
    static let chipText = Color(
        light: Color(red: 0.30, green: 0.24, blue: 0.68),
        dark: Color(red: 0.81, green: 0.77, blue: 1.0)
    )
    /// 메모 입력란 채움 — 배경보다 살짝 가라앉은(recessed) 톤. 라이트=어둡게, 다크=밝게.
    static let memoFill = Color(
        light: Color.black.opacity(0.045),
        dark: Color.white.opacity(0.06)
    )
    /// 스낵바 캡슐 채움 — 양 모드 모두 흰 텍스트가 얹히므로 어두운 면을 유지한다.
    static let snackbarFill = Color(
        light: Color(red: 0.21, green: 0.20, blue: 0.45).opacity(0.92),
        dark: Color(red: 0.30, green: 0.28, blue: 0.47).opacity(0.96)
    )

    /// primary CTA 채움 — 단색 보라 대신 좌상→우하 그라데이션으로 깊이를 더한다 (양 모드 공용).
    static let primaryGradient = LinearGradient(
        colors: [
            Color(red: 0.62, green: 0.53, blue: 0.97),
            Color(red: 0.50, green: 0.40, blue: 0.90),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Haptics

/// 익스텐션에서도 동작하는 가벼운 햅틱 래퍼 — 실패해도 무해(no-op).
enum ShareHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    /// 크롭 모드 진입(모서리를 잡은 순간) — 가벼운 탭.
    static func lightTap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// 크롭 확정(손을 뗀 순간) — 선택 변경 햅틱.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Entrance choreography

/// 시트 등장 직후 콘텐츠가 위→아래 순서로 떠오르는 스태거드 입장 안무.
/// `index` 순서대로 0.06s 간격 spring. `appeared` 는 부모가 `onAppear` 에서 켠다.
private struct ShareEntranceModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(
                .spring(response: 0.5, dampingFraction: 0.82).delay(Double(index) * 0.06),
                value: appeared
            )
    }
}

extension View {
    func shareEntrance(_ index: Int, appeared: Bool) -> some View {
        modifier(ShareEntranceModifier(index: index, appeared: appeared))
    }
}

// MARK: - Top bar

/// 상단 고정 바 — 좌측 "취소", 중앙 출처칩. 인사말 헤더를 없애고 그 수직 공간을 프리뷰에
/// 양보한다 (이 화면의 주인공은 캡처 내용). 출처칩이 컨텍스트 단서 역할을 이어받고,
/// 모찌 캐릭터는 저장 성공 모먼트(``ShareSuccessOverlay``)로 옮겨간다.
/// 저장 중엔 취소를 숨겨 중복 조작을 막는다 (기존 overlay 패턴과 동일 근거).
struct ShareTopBar: View {
    let sourceApp: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    /// 이미지가 있을 때만 — 스크린샷을 빼고 메모만 남기는 액션. 미리보기 위(탑바)로 옮겨
    /// 코너 크롭 핸들과 자리 충돌을 없앤다. nil 이면 표시하지 않는다.
    var onRemoveImage: (() -> Void)? = nil

    var body: some View {
        ZStack {
            if let sourceApp {
                SourceAppChip(name: sourceApp)
            }
            HStack {
                if !isSubmitting {
                    ShareCloseButton(action: onCancel)
                }
                Spacer()
                if !isSubmitting, let onRemoveImage {
                    ShareRemoveImageButton(action: onRemoveImage)
                }
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Success moment

/// 저장 직후 dismiss 까지 보이는 성공 모먼트 — 모찌가 글로우와 함께 스프링 바운스로 떠오르고
/// "기억했어요!" 가 따라온다. 하루에도 수십 번 뜨는 표면이라 짧은 정서적 보상이 반복 사용의
/// 동기가 된다 (이전엔 로딩 닷 → 무보상 dismiss).
///
/// 큐 적재(로컬 atomic write)가 진실원천이고 직접전송은 best-effort 라, 전송 완료를 기다리지
/// 않는 낙관적 "기억했어요" 가 정직하다. 노출 시간은 ``ShareExtensionPrincipal`` 의
/// `minSuccessDisplay` 가 보장한다.
struct ShareSuccessOverlay: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    // 캐릭터 뒤 소프트 글로우 — 다크모드에서 특히 "빛나는 순간" 으로 읽힌다.
                    Circle()
                        .fill(ShareDesign.primary.opacity(0.22))
                        .frame(width: 132, height: 132)
                        .blur(radius: 26)
                        .scaleEffect(appeared ? 1.0 : 0.3)

                    // mochi-cheer — 만세 + 눈 감고 웃는 "완료" 전용 포즈 (인사 포즈와 구분).
                    Image("mochi-cheer")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                        .scaleEffect(appeared ? 1.0 : 0.45)
                        .rotationEffect(.degrees(appeared ? 0 : -8))
                }
                .animation(.spring(response: 0.42, dampingFraction: 0.62), value: appeared)

                Text("기억했어요!")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(ShareDesign.title)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .animation(.spring(response: 0.45, dampingFraction: 0.8).delay(0.12), value: appeared)
            }
        }
        .onAppear { appeared = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("모찌에 저장 완료"))
    }
}

// MARK: - Primary CTA

/// 보라 그라데이션 라운드 primary 버튼 — `OnboardingButton` 과 동일 톤.
/// 제출 피드백은 버튼 내 로딩이 아니라 ``ShareSuccessOverlay`` 가 전담한다.
struct SharePrimaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 17)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(ShareDesign.primaryGradient)
                    .overlay(
                        // 상단 안쪽 하이라이트 — 빛을 받는 듯한 유리 질감.
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.35), .white.opacity(0.05)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
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
            Image(systemName: "viewfinder")
                .font(.system(size: 12, weight: .semibold))
            Text("\(name)에서 캡처")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(ShareDesign.chipText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(.white.opacity(0.55))
                .overlay(Capsule().stroke(ShareDesign.cardStroke, lineWidth: 1))
        )
        .accessibilityLabel(Text("\(name)에서 캡처됨"))
    }
}

// MARK: - Close button

/// 좌상단 "취소" 텍스트 — iOS 모달 dismiss 관례. 이미지 삭제(콘텐츠 제거)와
/// 시각언어를 분리해 "닫기 ≠ 스크린샷 빼기" 혼동을 없앤다.
struct ShareCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("취소")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(ShareDesign.subtitle)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("취소"))
    }
}

// MARK: - Remove image button

/// 탑바 우측 "사진 빼기" 필 — 스크린샷을 버리고 메모만 남긴다. 코너 크롭 핸들이 미리보기 모서리를
/// 차지하므로, 제거 액션은 미리보기 위(탑바)로 올려 자리 충돌을 없앴다. 좌측 "취소"(모달 dismiss)와
/// 의미·시각 모두 분리한다. 44pt 터치타깃.
struct ShareRemoveImageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                Text("사진 빼기")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(ShareDesign.subtitle)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(ShareDesign.cardFill)
                    .overlay(Capsule().stroke(ShareDesign.cardStroke, lineWidth: 1))
            )
            .contentShape(Capsule())
        }
        .frame(minHeight: 44)
        .accessibilityLabel(Text("스크린샷 빼고 메모만 남기기"))
    }
}

// MARK: - Memo field

/// 흰 카드 위 메모 입력 필드 — 좌측 연필 아이콘 + 입력으로 "여긴 적는 곳" 을 명시한다.
///
/// `compact` = true 면 단일행 슬림 모드, 텍스트·placeholder 수직 center (스크린샷이 대부분
/// 차지하는 케이스 — height 52pt). false 면 3~6줄 펼친 모드, 상단 정렬 (텍스트/URL 위주).
///
/// **레이아웃 주의**: 배경 `RoundedRectangle` 은 반드시 `.background()` modifier 로 둔다.
/// `ZStack` 안에 child 로 두면 Shape 의 greedy 한 성격 때문에 부모 VStack 의 가용 공간을
/// 다 잡아먹어 메모가 비대해진다.
struct ShareMemoField: View {
    @Binding var memo: String
    var compact: Bool = false

    private let radius: CGFloat = 10
    private var minH: CGFloat { compact ? 48 : 92 }
    /// 16pt 고정 — 가독성 확보 + 포커스 시 줌 유발 회피. compact/expanded 공통.
    private let memoFont: Font = .system(size: 16, design: .rounded)

    var body: some View {
        HStack(alignment: compact ? .center : .top, spacing: 9) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ShareDesign.subtitle.opacity(0.6))
                .padding(.top, compact ? 0 : 1)

            ZStack(alignment: compact ? .leading : .topLeading) {
                if memo.isEmpty {
                    // 0.7 — 0.55 는 라벤더 위에서 "비활성 필드" 로 오해될 만큼 흐렸다.
                    Text("메모 추가하기 (선택)")
                        .font(memoFont)
                        .foregroundStyle(ShareDesign.subtitle.opacity(0.7))
                        .allowsHitTesting(false)
                }
                TextField("", text: $memo, axis: .vertical)
                    .font(memoFont)
                    .foregroundStyle(ShareDesign.title)
                    .lineLimit(compact ? 1...2 : 3...6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, compact ? 0 : 12)
        .frame(minHeight: minH, alignment: compact ? .leading : .topLeading)
        // 움푹한(inset) 입력란 — 흰 솔리드는 "떠 있는 버튼"처럼 보여, 배경보다 살짝 어두운 톤 +
        // 안쪽 stroke 로 "여기 적는 곳" 을 표준 텍스트필드처럼 표현한다. (그림자 없음 = recessed)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(ShareDesign.memoFill)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(ShareDesign.title.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

// MARK: - Press style

private struct ScalePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
