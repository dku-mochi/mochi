import SwiftUI
import AppIntents
import CorePersistence

/// 백탭 snippet 카드의 SwiftUI view.
///
/// ``CaptureScreenshotIntent`` 가 PNG 를 `pending-backtap/<captureID>.png` 에 stash 한 직후
/// `.result(view: BackTapSnippetView(...))` 로 반환하면 시스템이 이 view 를 **외부 앱 위에**
/// snippet 카드로 띄운다 (Papago 와 동일한 메커니즘). 사용자는 YouTube 같은 외부 앱을 보던
/// 컨텍스트를 잃지 않고 두 버튼 중 선택한다.
///
/// **두 분기 (의도 분리)**:
/// - "이 화면 캡쳐" → ``CommitBackTapCaptureIntent`` — 미리보기 이미지를 그대로 저장.
///   `openAppWhenRun = false` 라 외부 앱 계속 보임.
/// - "새 메모" → ``OpenBackTapMemoIntent`` — **화면과 무관한 별도 메모 작성**. 미리보기는
///   폐기되고 모찌가 foreground 진입해 textarea 표시 (`openAppWhenRun = true`).
///
/// **레이아웃 (시안 B — 분할형)**:
/// ```
/// ┌─────────────────────────────────┐
/// │ ╭──────╮  🐹 모찌에 남길까요?    │
/// │ │      │                        │
/// │ │ thumb│  [📷 이 화면 캡쳐]      │
/// │ │      │  [✏️ 새 메모]           │
/// │ ╰──────╯                        │
/// └─────────────────────────────────┘
/// ```
/// 좌측 90×140pt thumbnail + 우측 헤더·세로 버튼 스택. WWDC25 가 권고하는 340pt height
/// 한계 안에 여유롭게 들어와 스크롤·잘림 위험 0 (총 ~165pt). 두 버튼이 세로라 탭 타겟 명확.
///
/// **다크모드 안전 컬러 (Forums 783911 / FB17603899)**: snippet view 안에서는
/// `@Environment(\.colorScheme)` 가 항상 `.light` 를 반환하는 iOS 18+ 버그가 있다. 결과적으로
/// `Color.primary` / `Color.secondary` 등 colorScheme 의존 semantic color 도 라이트로 평가되어
/// 다크 디바이스에서 가독성이 깨진다. `Color(uiColor: .label)` 같은 **UIColor dynamic** 은
/// trait collection 기반이라 정상 동작 — 모든 텍스트·구분선 색을 그쪽으로 통일.
/// `.ultraThinMaterial` 같은 material 도 같은 이유로 검게 깨지므로 사용 금지.
///
/// **하드코딩된 brand 컬러**: `FeatureOnboarding.OnboardingTheme` 은 모듈 경계로 import 불가능
/// (AppIntents 는 App 타겟 안, FeatureOnboarding 은 별도 framework). brand soft purple
/// `Color(red: 0.55, green: 0.46, blue: 0.93)` 값 복제. `OnboardingTheme.primary` 변경 시 동기화.
///
/// **이미지 자산**: `mochi-hello` 는 `Targets/App/Resources/Assets.xcassets` 에 있고
/// AppIntents 가 App 타겟 내부라 main bundle 로 접근 가능. PNG 미리보기는 App Group 컨테이너의
/// 파일 시스템에서 직접 load — snippet redraw 마다 file load 가 일어나지만 사용자 interaction
/// 빈도가 낮아 부담 무시 가능.
@available(iOS 17.0, *)
struct BackTapSnippetView: View {
    /// `CaptureScreenshotIntent.perform()` 가 만든 UUID 의 문자열 형태. 캡쳐 분기의 Realm
    /// `MochiItem.id` · 백엔드 idempotency key. 메모 분기는 새 UUID 를 발급한다 (P1 #3 invariant —
    /// 메모와 캡쳐는 의미상 다른 capture, 같은 ID 재사용 시 Realm `update: .modified` 가 screenshot
    /// row 를 silent overwrite). pending PNG 파일명은 `AppGroup.pendingBackTapPNGFilename(captureID:)`
    /// 로 derive — P2 #10: 파일명 파라미터를 별도 전달하지 않아 parameter 신뢰 문제 차단.
    let captureID: String

    /// `FeatureOnboarding.OnboardingTheme.primary` 와 동일 값. 모듈 경계로 import 불가능해 복제.
    private static let brandPrimary = Color(red: 0.55, green: 0.46, blue: 0.93)
    /// `OnboardingTheme.primaryShadow` 와 동일 식.
    private static let brandPrimaryShadow = Color(red: 0.55, green: 0.46, blue: 0.93).opacity(0.30)

    /// snippet view 다크모드 버그(Forums 783911) 회피용 — UIColor dynamic 은 trait collection
    /// 기반이라 colorScheme bug 영향 없음.
    private static let labelColor = Color(uiColor: .label)
    private static let separatorColor = Color(uiColor: .separator)
    private static let surfaceColor = Color(uiColor: .systemGray5)
    private static let placeholderSurface = Color(uiColor: .systemGray6)

    /// pending PNG 를 미리보기로 로드. file 이 없거나 디코드 실패면 nil — view 가 placeholder
    /// thumbnail 을 보여준다 (race 로 sweep 됐을 가능성 등).
    private var screenshotImage: UIImage? {
        let url = AppGroup.pendingBackTapDirectoryURL
            .appendingPathComponent(AppGroup.pendingBackTapPNGFilename(captureID: captureID))
        guard let data = try? Data(contentsOf: url),
              let img = UIImage(data: data) else { return nil }
        return img
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 10) {
                header
                Spacer(minLength: 0)
                buttons
            }
        }
        .padding(12)
    }

    // MARK: - Thumbnail (좌측, 확인용)

    /// 90×140pt — iPhone 스크린샷(≈9:19.5)을 `scaledToFill` 로 채워 시각적으로 꽉 차게.
    /// 위/아래 살짝 잘리지만 사용자는 직전에 본 화면이라 식별 가능. 파일이 없으면 placeholder.
    private var thumbnail: some View {
        Group {
            if let img = screenshotImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                Self.placeholderSurface
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 24, weight: .regular))
                            .foregroundStyle(Self.separatorColor)
                    )
            }
        }
        .frame(width: 90, height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Self.separatorColor, lineWidth: 1)
        )
    }

    // MARK: - Header (우측 상단)

    private var header: some View {
        HStack(spacing: 8) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text("모찌에 남길까요?")
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(Self.labelColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Buttons (우측 하단, 세로 스택)

    private var buttons: some View {
        VStack(spacing: 8) {
            Button(intent: CommitBackTapCaptureIntent(captureID: captureID)) {
                captureLabel
            }
            .buttonStyle(.plain)

            Button(intent: OpenBackTapMemoIntent(screenshotCaptureID: captureID)) {
                memoLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var captureLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 15, weight: .semibold))
            Text("이 화면 캡쳐")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Self.brandPrimary)
                .shadow(color: Self.brandPrimaryShadow, radius: 8, x: 0, y: 4)
        )
    }

    private var memoLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15, weight: .semibold))
            Text("새 메모")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
        }
        .foregroundStyle(Self.labelColor)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Self.surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Self.brandPrimary.opacity(0.4), lineWidth: 1.5)
        )
    }
}
