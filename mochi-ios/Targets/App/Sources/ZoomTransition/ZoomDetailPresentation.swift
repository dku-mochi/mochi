import SwiftUI
import UIKit
import ComposableArchitecture
import DesignSystem
import FeatureDetail

extension View {
    /// 기록 상세를 "카드 통째 → 전체화면" zoom present 로 띄운다.
    /// `store` non-nil → present, nil → dismiss (TCA @Presents 양방향).
    func zoomDetailPresentation(
        store: Binding<StoreOf<DetailFeature>?>,
        hero: HeroSourceFrames?
    ) -> some View {
        background(
            ZoomDetailPresenter(store: store, hero: hero)
                .frame(width: 0, height: 0)
        )
    }
}

private struct ZoomDetailPresenter: UIViewControllerRepresentable {
    @Binding var store: StoreOf<DetailFeature>?
    let hero: HeroSourceFrames?

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.sync(store: store, hero: hero, host: host, onDismiss: { store = nil })
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var hosting: UIViewController?
        private var hero: HeroSourceFrames?
        private var onDismiss: (() -> Void)?
        private weak var scrollView: UIScrollView?
        /// 상세 hero 이미지 alpha 를 비행 타이밍에 맞춰 토글하기 위한 store 참조.
        private var detailStore: StoreOf<DetailFeature>?
        /// present 때 찍은 카드 썸네일 비트맵 — dismiss 비행에 재사용한다.
        /// (상세에서 새로 스냅샷 뜨면 '캡처' 배지가 같이 찍혀 축소되는 게 거슬리므로,
        ///  배지가 없는 카드 비트맵을 돌려보낸다.)
        private var cardThumbImage: UIImage?

        private let cardRadius = HomeDesign.Radius.md

        /// 상세 화면에서 hero 이미지(`ScreenshotPreviewImage`)가 차지하는 글로벌 frame.
        /// DetailView 레이아웃: `NavigationStack`(inline bar) → `ScrollView`.padding(lg=16)
        ///   → `RecallHeader` 최상단 이미지(가로 꽉, 4:3, DetailView.swift:124-134).
        /// 상세 VC 는 present 시점에 아직 레이아웃되지 않아 실측이 불가능하므로 레이아웃 상수로
        /// 예측하고, cross-fade(상세 fade-in)가 미세 오차를 가린다.
        private static func detailImageFrame(in window: UIWindow) -> CGRect {
            let lg = HomeDesign.Spacing.lg          // ScrollView content padding
            let navBarHeight: CGFloat = 44          // inline navigation bar
            let width = window.bounds.width - lg * 2
            let height = width * 3.0 / 4.0          // 카드·상세 통일된 4:3
            let y = window.safeAreaInsets.top + navBarHeight + lg
            return CGRect(x: lg, y: y, width: width, height: height)
        }

        func sync(
            store: StoreOf<DetailFeature>?,
            hero: HeroSourceFrames?,
            host: UIViewController,
            onDismiss: @escaping () -> Void
        ) {
            if let store {
                guard hosting == nil, host.view.window != nil else { return }
                self.onDismiss = onDismiss
                present(store: store, hero: hero, host: host)
            } else if let hosting {
                dismiss(hosting)
            }
        }

        // MARK: - present
        //
        // 핵심 아이디어 (공유 요소 = 썸네일 이미지):
        //  카드와 상세에 동일하게 존재하는 "썸네일 이미지"만 hero 로 비행시키고, 나머지(카드 텍스트·
        //  상세 본문)는 cross-fade 한다. 카드 통째를 비행시키면 카드(가로 4:3)→풀스크린(세로) 비율이
        //  안 맞아 늘어나며 찌그러지지만, 썸네일(178×134≈4:3)→상세 이미지(가로 꽉, 4:3)는 같은 비율이라
        //  왜곡 없이 자란다.
        //  1. present 전 — 카드 썸네일 영역(`hero.cardImage`)을 window 에서 비트맵 스냅샷.
        //  2. 상세 VC 를 alpha=0 으로 present (시스템 전환 없음).
        //  3. 스냅샷을 window 최상위에 올려 카드 썸네일 위치에서 출발.
        //  4. 스냅샷: 카드 썸네일 → 상세 hero 이미지 위치 (spring 확대, scaleAspectFill).
        //  5. 상세 VC: 스냅샷이 어느정도 자란 뒤 fade-in.
        //  6. 스냅샷: 상세 이미지(비동기 로딩)가 뜰 시간을 두고 fade-out 후 제거.
        //  → 이미지가 없는 카드(memo/url, `cardImage == nil`)는 공유 요소가 없으므로 fade+scale 폴백.

        private func present(
            store: StoreOf<DetailFeature>,
            hero: HeroSourceFrames?,
            host: UIViewController
        ) {
            guard let window = host.view.window else { return }
            self.hero = hero
            self.detailStore = store

            let hosting = UIHostingController(
                rootView: NavigationStack { DetailView(store: store) }
            )
            hosting.modalPresentationStyle = .overFullScreen
            hosting.view.alpha = 0
            self.hosting = hosting

            // ① 비행용 원본 캡처 로드 — 화면 비트맵을 뜨면(drawHierarchy) 카드의 종류 배지가
            //    같이 찍혀 확대되므로, relativePath 로 배지·테두리 없는 순수 이미지를 직접 로드한다.
            //    카드가 가로 스크롤에서 잘려 있어도 완전한 이미지가 펼쳐지며 비행한다.
            let thumbFrame = hero?.cardImage
            let cardImage = thumbFrame != nil
                ? loadContainerThumbnailSync(relativePath: hero?.imageRelativePath, maxPixel: 1000)
                : nil
            cardThumbImage = cardImage   // dismiss 비행에 재사용
            let snap: UIImageView?
            if let thumb = thumbFrame, let cardImage {
                let imageView = UIImageView(image: cardImage)
                imageView.frame = thumb
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = cardRadius
                snap = imageView
            } else {
                snap = nil
            }

            // ② 상세 VC 를 시스템 애니메이션 없이 즉시 present (alpha=0 이라 보이지 않음).
            //    모든 애니메이션은 present **completion**(= view 가 window 에 부착 완료된 시점)에서 건다.
            //    present(animated:false) 직후 동기적으로 hosting.view.alpha 를 애니메이트하면 view 가
            //    아직 부착 전이라 애니메이션이 무시되고 즉시 1 로 점프해 "갑자기 나타남"이 된다.
            host.present(hosting, animated: false) { [weak self, weak hosting] in
                guard let hosting else { return }
                guard let snap else {
                    // 공유 이미지 없음(memo/url) 폴백 — 비행 없으니 상세 이미지를 가릴 이유 없다.
                    self?.detailStore?.send(.setHeroImageHidden(false))
                    hosting.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                    UIView.animate(
                        withDuration: 0.30,
                        delay: 0,
                        usingSpringWithDamping: 1.0,
                        initialSpringVelocity: 0
                    ) {
                        hosting.view.alpha = 1
                        hosting.view.transform = .identity
                    }
                    return
                }

                // ③ 스냅샷을 상세 위(window 최상위)에 올리고, 이미지 비행과 상세 fade-in 을
                //    **같은 블록에서 동시에** 진행한다(이미지는 날아가고, 그 밑에서 상세가 차오름).
                window.addSubview(snap)
                let dest = Self.detailImageFrame(in: window)
                UIView.animate(
                    withDuration: 0.50,
                    delay: 0,
                    usingSpringWithDamping: 0.82,
                    initialSpringVelocity: 0.10,
                    options: [.allowAnimatedContent]
                ) {
                    snap.frame = dest          // 이미지 비행
                    hosting.view.alpha = 1     // 상세 fade-in (동시)
                }

                // ④ 스냅샷은 상세 이미지에 안착한 뒤(후반) 사라진다 — 이미지가 끊겨 보이지 않게.
                UIView.animate(withDuration: 0.20, delay: 0.34, options: [.curveEaseIn]) {
                    snap.alpha = 0
                } completion: { _ in snap.removeFromSuperview() }

                // 비행 스냅샷이 사라지기 시작하는 시점(④ delay)에 상세 hero 이미지를 켠다 —
                // 그 전까지는 숨겨둬(heroImageHidden) 비행 스냅샷과 이중으로 겹쳐 보이지 않게.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
                    self?.detailStore?.send(.setHeroImageHidden(false))
                }
            }

            // 드래그 dismiss gesture + 내부 ScrollView 추적
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            hosting.view.addGestureRecognizer(pan)
            DispatchQueue.main.async { [weak self, weak hosting] in
                self?.scrollView = hosting?.view.firstScrollView()
            }
        }

        // MARK: - dismiss (상세 hero 이미지 → 카드 썸네일 위치로 축소)
        //
        // present 의 대칭: 상세 이미지 영역만 스냅샷 떠서 카드 썸네일 자리로 돌려보내고, 본문은 fade-out.
        // 상세 전체를 카드 크기로 축소하면 "창문이 쪼그라드는" 느낌이라 공간 연속성이 깨진다.

        private func dismiss(_ hosting: UIViewController) {
            guard self.hosting === hosting else { return }
            self.hosting = nil

            guard let window = hosting.view.window,
                  let thumb = hero?.cardImage,
                  let image = cardThumbImage else {
                // 공유 이미지 없음(memo/url) 폴백 — 그대로 fade-out
                let animator = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 1) {
                    hosting.view.alpha = 0
                }
                animator.addCompletion { _ in hosting.dismiss(animated: false); self.onDismiss?() }
                animator.startAnimation()
                return
            }

            // 목업(스냅샷)을 화면에 올리는 순간 상세 hero 이미지를 숨겨, 둘이 겹쳐 보이지 않게 한다.
            detailStore?.send(.setHeroImageHidden(true))

            // present 때 떠둔 원본 캡처(배지 없음)를 상세 이미지 위치에서 카드 썸네일 자리로 축소.
            let source = Self.detailImageFrame(in: window)
            let snap = UIImageView(image: image)
            snap.frame = source
            snap.contentMode = .scaleAspectFill
            snap.clipsToBounds = true
            snap.layer.cornerRadius = cardRadius
            window.addSubview(snap)

            // 본문(이미지 외 chrome) fade-out
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
                hosting.view.alpha = 0
            }

            // 스냅샷을 카드 썸네일 자리로 축소
            UIView.animate(
                withDuration: 0.40,
                delay: 0,
                usingSpringWithDamping: 0.92,
                initialSpringVelocity: 0,
                options: [.allowAnimatedContent]
            ) {
                snap.frame = thumb
            } completion: { _ in
                snap.removeFromSuperview()
                self.detailStore = nil
                hosting.dismiss(animated: false)
                self.onDismiss?()
            }
        }

        // MARK: - 드래그 dismiss (아래로 당기면 닫기)

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let hosting, let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let progress = min(max(translation.y / max(view.bounds.height, 1), 0), 1)

            switch gesture.state {
            case .changed:
                let scale = 1 - progress * 0.2
                view.transform = CGAffineTransform(translationX: translation.x * 0.3, y: translation.y)
                    .scaledBy(x: scale, y: scale)
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view).y
                if gesture.state == .ended, progress > 0.3 || velocity > 900 {
                    // 드래그 닫기 — 이미 손끝 위치를 따라온 상태라, identity 로 되돌렸다가 스냅샷
                    // 비행시키면 화면이 튄다. 현재 위치에서 그대로 아래로 슬라이드 + fade 한다.
                    self.hosting = nil
                    UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn]) {
                        view.transform = CGAffineTransform(translationX: 0, y: view.bounds.height)
                        view.alpha = 0
                    } completion: { _ in
                        hosting.dismiss(animated: false)
                        self.onDismiss?()
                    }
                } else {
                    UIView.animate(withDuration: 0.3) { view.transform = .identity }
                }
            default:
                break
            }
        }

        // 아래 방향 + 내부 ScrollView 가 최상단일 때만 드래그 dismiss 시작
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            guard velocity.y > abs(velocity.x) else { return false }
            if let scrollView {
                return scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 0.5
            }
            return true
        }
    }
}

// MARK: - UIView helpers

private extension UIView {
    func firstScrollView() -> UIScrollView? {
        if let sv = self as? UIScrollView { return sv }
        for sub in subviews { if let found = sub.firstScrollView() { return found } }
        return nil
    }
}
