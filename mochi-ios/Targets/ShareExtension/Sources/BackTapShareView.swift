import SwiftUI
import CoreDomain
import CorePersistence

/// 백탭 단축어가 "앱과 공유" 액션으로 호출한 ShareExtension 의 1-step UI.
///
/// **흐름**: 단축어가 스크린샷 1장만 전달 (URL/text 없음) → ``ShareExtensionPrincipal`` 이
/// 이 View 를 마운트. 사용자는 미리보기 확인 + optional 메모 입력 후 "저장" 한 번으로 dismiss.
///
/// **레이아웃**: 스크린샷이 화면 대부분을 차지하고, 메모/CTA 는 하단에 컴팩트하게 배치.
/// 사용자가 무엇을 캡처했는지 한눈에 확인하는 게 본질이므로 이미지가 주연.
///
/// 디자인 토큰/컴포넌트는 ``ShareDesign`` 을 통해 ``ShareEntryView`` 와 공유한다.
struct BackTapShareView: View {
    let imageRefs: [ImageRef]
    let channelGuess: IngestChannel
    let onSubmit: (InboundIngestPayload) -> Void
    let onCancel: () -> Void

    @State private var memo: String = ""

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 14) {
                header

                if let firstImage = imageRefs.first {
                    SharePreviewImage(imageRef: firstImage)
                        .frame(maxHeight: .infinity)
                }

                ShareMemoField(memo: $memo, compact: true)
                SharePrimaryButton(title: "모찌에 저장", action: submit)
            }
            .padding(.horizontal, 16)
            .padding(.top, 52)
            .padding(.bottom, 16)
        }
        .overlay(alignment: .topLeading) {
            ShareCloseButton(action: onCancel)
                .padding(.top, 10)
                .padding(.leading, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            Text("모찌에 남길까요?")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .foregroundStyle(ShareDesign.title)
        }
    }

    private func submit() {
        onSubmit(InboundIngestPayload(
            url: nil,
            text: nil,
            userMemo: memo.isEmpty ? nil : memo,
            channelGuess: channelGuess,
            imageRefs: imageRefs
        ))
    }
}
