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
    static let cardSolid      = Color.white.opacity(0.92)
    static let cardStroke     = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.15)
    /// 출처칩 텍스트 — 라벤더 배경 위 WCAG AA 대비 확보용 진보라 (#4C3EAD).
    static let chipText       = Color(red: 0.30, green: 0.24, blue: 0.68)
    /// 프리뷰 하단 "아래로 이어짐" 페이드 색 — 배경 그라데이션 상단 라벤더와 맞춰 이질감 최소화.
    static let fadeHint       = Color(red: 0.86, green: 0.85, blue: 0.96)
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
            Image(systemName: "viewfinder")
                .font(.system(size: 12, weight: .semibold))
            Text("\(name)에서 캡처")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(ShareDesign.chipText)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(ShareDesign.primary.opacity(0.12))
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

/// 미리보기 우상단 이미지 제거 — 어두운 반투명 원 + 흰 trash 아이콘.
/// `xmark` 는 "시트 닫기"로 오해되기 쉬워 `trash` 로 "이건 사진 삭제"임을 명확히 한다.
/// 좌상단 "취소"(텍스트, 모달 dismiss)와 시각·의미 모두 분리. 44pt 터치타깃.
struct RemoveImageButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.42), in: Circle())
        }
        .frame(width: 44, height: 44)
        .padding(6)
        .accessibilityLabel(Text("스크린샷 제거"))
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
                    Text("메모 추가하기 (선택)")
                        .font(memoFont)
                        .foregroundStyle(ShareDesign.subtitle.opacity(0.55))
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
                .fill(Color.black.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(ShareDesign.title.opacity(0.10), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview image

/// App Group container 의 captures/ PNG 를 카드에 **전체폭 fit + 세로 스크롤**로 표시한다.
///
/// 백탭 캡처는 풀스크린(≈9:19.5)이라 가용 높이보다 훨씬 길다. 이전엔 ``scaledToFill`` 상단정렬로
/// 아래를 하드컷했는데, 사용자가 "왜 이 영역만 전송되지?" 로 오해했다. 그래서 이미지를 카드 폭에
/// 맞춰(``scaledToFit``) 세로로 길게 펼치고 **세로 스크롤**로 끝까지 확인하게 한다 — 잘린 게 아니라
/// 화면이 짧아 일부만 보일 뿐임을 스크롤 인디케이터 + 하단 페이드("아래로 이어짐")로 전달한다.
/// 헤더·CTA 는 이 뷰 바깥(부모 VStack)에 고정돼 스크롤과 무관하게 항상 함께 보인다.
///
/// 캡처 상단 상태바(~6%)는 실기기 상태바와 중복돼 잘라낸다(콘텐츠가 아니라 인식에 무해).
struct SharePreviewImage: View {
    let imageRef: ImageRef

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if let uiImage = loadImage() {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
            } else {
                ZStack {
                    ShareDesign.cardSolid
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(ShareDesign.subtitle)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            // "아래로 이어짐" 단서 — 콘텐츠가 하드컷이 아니라 계속됨을 암시(스크롤 인디케이터와 함께).
            LinearGradient(
                colors: [ShareDesign.fadeHint.opacity(0), ShareDesign.fadeHint],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(ShareDesign.cardStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    private func loadImage() -> UIImage? {
        let url = AppGroup.containerURL.appendingPathComponent(imageRef.relativePath)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data) else { return nil }
        // 풀스크린 캡처 상단 상태바(~6%)를 잘라 중복 상태바를 없앤 뒤 top-align 으로 상단 콘텐츠 보존.
        guard let cg = img.cgImage else { return img }
        let cropY = Int(CGFloat(cg.height) * 0.06)
        guard cropY > 0,
              let cropped = cg.cropping(to: CGRect(x: 0, y: cropY, width: cg.width, height: cg.height - cropY))
        else { return img }
        return UIImage(cgImage: cropped, scale: img.scale, orientation: img.imageOrientation)
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
