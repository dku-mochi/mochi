import SwiftUI
import CoreDomain
import CorePersistence

/// 백탭 단축어가 "앱과 공유" 액션으로 호출한 ShareExtension 의 1-step UI.
///
/// **흐름**: 단축어가 스크린샷 1장(+ optional 출처앱 sentinel) 전달 → ``ShareExtensionPrincipal`` 이
/// 이 View 를 마운트. 사용자는 미리보기 확인 + optional 메모 입력 후 "저장" 한 번으로 dismiss.
///
/// **일반 메모 모드**: 백탭이 오발화했거나 스크린샷이 필요 없으면 (×) 로 스크린샷을 버리고
/// 메모만 남긴다 — 이미지가 빠지면 `imageRefs=[]` + channel `.appDirectInput` 으로 적재되고,
/// ``ShareExtensionPrincipal`` 이 고아 PNG 를 청소한다. 실수 복구용 "되돌리기" 스낵바 제공.
///
/// **출처앱 칩**: sentinel 로 받은 출처앱은 ``SourceAppChip`` 으로 보여주고, 백엔드 `text` 에는
/// 정규화 1줄로 합친다 (사용자 메모는 `user_memo` 로 끝까지 격리).
///
/// **저장 피드백**: 제출 즉시 ``ShareSuccessOverlay`` (모찌 + "기억했어요!") 가 화면을 덮는다 —
/// best-effort 직접전송 대기 구간(이전엔 무피드백 멈춤)을 성공 모먼트로 채우고, 취소는 숨겨
/// 중복 조작을 막는다. 오버레이가 터치를 가로채 CTA 중복 탭도 함께 차단된다.
///
/// 디자인 토큰/컴포넌트는 ``ShareDesign`` 을 통해 ``ShareEntryView`` 와 공유한다.
struct BackTapShareView: View {
    let imageRefs: [ImageRef]
    let channelGuess: IngestChannel
    let sourceApp: String?
    /// sentinel 로 받은 화면상 URL(Safari 등) — 기록상세 "원본에서 보기"용. 없으면 nil.
    let url: URL?
    /// 사용자 코너 크롭(정규화 0...1, 표시 이미지 기준). 제출 시 ``ShareImageCropper`` 가 파일에 적용한다.
    let onSubmit: (InboundIngestPayload, CGRect) -> Void
    let onCancel: () -> Void

    @State private var memo: String = ""
    @State private var crop = ShareCropImage.fullCrop
    @State private var imageRemoved = false
    @State private var showUndo = false
    @State private var isSubmitting = false
    @State private var appeared = false
    @FocusState private var memoFocused: Bool

    var body: some View {
        ZStack {
            ShareDesign.backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ShareTopBar(
                    sourceApp: sourceApp,
                    isSubmitting: isSubmitting,
                    onCancel: onCancel,
                    onRemoveImage: imageRemoved ? nil : removeImage
                )
                .shareEntrance(0, appeared: appeared)

                if !imageRemoved, let firstImage = imageRefs.first {
                    ShareCropImage(imageRef: firstImage, crop: $crop)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        .shareEntrance(1, appeared: appeared)
                }

                if imageRemoved {
                    memoOnlyHint
                        .frame(maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                ShareMemoField(memo: $memo, compact: !imageRemoved)
                    .focused($memoFocused)
                    .shareEntrance(2, appeared: appeared)

                SharePrimaryButton(title: "모찌에 저장", icon: "sparkles", action: submit)
                    .shareEntrance(3, appeared: appeared)
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 16)

            if isSubmitting {
                ShareSuccessOverlay()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .overlay(alignment: .bottom) {
            if showUndo {
                undoSnackbar
                    .padding(.bottom, 92)
            }
        }
        .onAppear { appeared = true }
    }

    /// 스크린샷을 뺀 뒤 비는 공간의 empty state — "비어 보임 ≠ 깨짐" 을 모찌가 알려준다.
    /// 키보드가 올라오면 자연스럽게 압축되어 사라진다 (maxHeight: .infinity).
    private var memoOnlyHint: some View {
        VStack(spacing: 10) {
            Image("mochi-hello")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)

            Text("메모만 남길게요")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(ShareDesign.subtitle)
        }
    }

    private var undoSnackbar: some View {
        HStack(spacing: 12) {
            Text("스크린샷을 뺐어요")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
            Button("되돌리기", action: undoRemove)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.80, green: 0.76, blue: 1.0))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Capsule().fill(ShareDesign.snackbarFill))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func removeImage() {
        withAnimation(.easeInOut(duration: 0.25)) {
            imageRemoved = true
            showUndo = true
        }
        memoFocused = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation { showUndo = false }
        }
    }

    private func undoRemove() {
        withAnimation(.easeInOut(duration: 0.2)) {
            imageRemoved = false
            showUndo = false
        }
    }

    private func submit() {
        guard !isSubmitting else { return }   // 중복 탭 방지 — 매 submit 마다 payload.id 가 새로 생겨 중복 적재 위험
        memoFocused = false
        withAnimation(.easeInOut(duration: 0.2)) { isSubmitting = true }
        ShareHaptics.success()
        let text = CaptureContextSentinel.composeText(sourceApp: sourceApp, base: nil)
        onSubmit(
            InboundIngestPayload(
                url: imageRemoved ? nil : url,
                text: text,
                userMemo: memo.isEmpty ? nil : memo,
                channelGuess: imageRemoved ? .appDirectInput : channelGuess,
                imageRefs: imageRemoved ? [] : imageRefs
            ),
            imageRemoved ? ShareCropImage.fullCrop : crop
        )
    }
}
