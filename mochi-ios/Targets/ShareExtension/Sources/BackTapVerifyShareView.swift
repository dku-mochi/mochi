import SwiftUI

/// 온보딩 백탭 검증이 ShareExtension 까지 도달했을 때 보여주는 확인 카드.
///
/// 백탭의 실제 진입점은 snippet 이 아니라 이 ShareExtension 이다 — 단축어가
/// `Take Screenshot → Share → 모찌` 로 흐른다(CHANGELOG 2026-06-02 ShareExtension 단일 경로 확정).
/// 검증 모드에선 진짜 저장을 하지 않고(쓰레기 `MochiItem` 방지) "백탭이 작동해요" 만 알린다.
///
/// **닫기는 "완료" 탭으로만**: 자동(타이머) `completeRequest` 는 ShareExtension scene 을 끝까지
/// teardown 하지 못해(카드는 fade 되지만 익스텐션 윈도우가 살아남아 홈제스처까지 막고 잠금/해제
/// 전엔 안 꺼짐) 앱이 먹통이 됐다. 정상 동작하는 일반 캡처(`BackTapShareView`)는 **사용자 탭**으로
/// `completeRequest` 를 부르는데, 검증만 타이머로 불러서 생긴 차이였다. 그래서 검증도 캡처와
/// 똑같이 사용자 탭(`onDone`)으로 종료한다. 온보딩 쪽은 별도로 `AppGroup.backTapVerificationDidHit`
/// 을 폴링해 체크리스트를 이미 완료 처리하므로(이 카드는 사용자 피드백, 마커는 프로그램 신호),
/// 사용자는 결과를 확인하고 "완료" 로 닫으면 된다.
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

                SharePrimaryButton(title: "완료", action: onDone)
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }
            .padding(32)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("백탭이 작동해요. 이제 뒷면을 두 번 탭하면 모찌가 나타납니다."))
    }
}
