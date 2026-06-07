import SwiftUI

/// 온보딩 백탭 검증이 ShareExtension 까지 도달했을 때 잠깐 보여주는 확인 카드.
///
/// 백탭의 실제 진입점은 snippet(`CaptureScreenshotIntent`)이 아니라 이 ShareExtension 이다 —
/// 사용자 단축어가 `Take Screenshot → Share → 모찌` 로 흐르기 때문. 검증 모드일 때는 진짜
/// 저장을 하지 않고(검증용 스크린샷이 쓰레기 `MochiItem` 으로 남지 않게) "백탭이 작동해요" 만
/// 알린 뒤 자동으로 닫힌다. 온보딩 쪽은 별도로 `AppGroup.backTapVerificationDidHit` 을 폴링해
/// 체크리스트를 완료 처리한다 (이 카드는 사용자용 피드백, 파일 마커는 프로그램용 신호).
struct BackTapVerifyShareView: View {
    let onDone: () -> Void

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient.ignoresSafeArea()

            VStack(spacing: 18) {
                Image("mochi-hello")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .shadow(color: ShareDesign.primaryShadow, radius: 16, x: 0, y: 8)

                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(ShareDesign.primary)
                    Text("백탭이 작동해요!")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundStyle(ShareDesign.title)
                }

                Text("이제 어디서든 뒷면을 두 번 탭하면\n제가 나타날게요")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(ShareDesign.subtitle)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
            .padding(32)
        }
        .task {
            try? await Task.sleep(for: .seconds(1.6))
            onDone()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("백탭이 작동해요. 이제 뒷면을 두 번 탭하면 모찌가 나타납니다."))
    }
}
