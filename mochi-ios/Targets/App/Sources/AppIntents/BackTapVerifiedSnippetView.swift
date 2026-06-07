import SwiftUI
import UIKit
import AppIntents

/// 온보딩 백탭 검증이 성공했을 때 ``CaptureScreenshotIntent`` 가 띄우는 snippet 카드.
///
/// 일반 백탭과 달리 검증 모드(`AppGroup.isBackTapVerificationActive`)에서는 진짜 스크린샷을
/// stash 하지 않으므로 "캡쳐 / 메모" 선택 버튼이 없다. 대신 "백탭이 작동한다" 는 즉각적인
/// 시각 확인만 준다 — 온보딩 쪽은 별도로 `AppGroup.backTapVerificationDidHit` 을 폴링해
/// 체크리스트를 완료 처리한다 (이 카드는 사용자용 피드백, 마커는 프로그램용 신호).
///
/// **다크모드 안전 컬러**: snippet view 안에서는 `@Environment(\.colorScheme)` 이 항상
/// `.light` 를 반환하는 iOS 18+ 버그가 있어 `Color(uiColor:)` dynamic 으로 통일한다
/// (``BackTapSnippetView`` 와 동일 근거).
@available(iOS 17.0, *)
struct BackTapVerifiedSnippetView: View {
    /// `FeatureOnboarding.OnboardingTheme.primary` 와 동일 값 — 모듈 경계로 import 불가해 복제.
    private static let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)
    private static let labelColor = Color(uiColor: .label)
    private static let secondaryLabel = Color(uiColor: .secondaryLabel)

    var body: some View {
        HStack(spacing: 12) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Self.brandPrimary)
                    Text("백탭이 작동해요!")
                        .font(.system(.headline, design: .rounded).weight(.bold))
                        .foregroundStyle(Self.labelColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Text("이제 어디서든 뒷면을 두 번 탭하면 제가 나타나요")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Self.secondaryLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - Result wrapper

/// ``CaptureScreenshotIntent`` 의 두 snippet 분기(일반 캡처 / 검증)를 **단일 구체 View 타입**으로
/// 묶는다. `some IntentResult & ShowsSnippetView` 의 opaque 반환은 분기마다 타입이 같아야 하는데,
/// `AnyView` 로 type-erase 하면 시스템이 snippet 으로 렌더링하지 못한다 — 그래서 구체 wrapper 를 쓴다.
@available(iOS 17.0, *)
struct BackTapResultSnippet: View {
    enum Kind: Equatable {
        case capture(captureID: String)
        case verified
    }
    let kind: Kind

    var body: some View {
        switch kind {
        case .capture(let id): BackTapSnippetView(captureID: id)
        case .verified: BackTapVerifiedSnippetView()
        }
    }
}
