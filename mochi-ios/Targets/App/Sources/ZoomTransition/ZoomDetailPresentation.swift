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
        /// 홈 위에 까는 dim — 떠난 카드의 잔상을 가리고 모달 깊이를 만든다. 모든 종료 경로에서 제거.
        private weak var dimView: UIView?
        /// 진행 중인 dismiss 비행을 즉시 끝내는 클로저 — present(알림 등 교체 진입)가 끼어들 때 호출해
        /// 죽어가는 VC 를 UIKit 계층에서 곧바로 떼어낸다. 안 그러면 dismiss 비행(최대 0.45s) 동안 VC 가
        /// 남아 presenter 탐색에 잡혀 그 위에 새 VC 가 쌓이고, 이전 dismiss 의 completion 이 새 상세를
        /// 오염시켜 '투명한데 뒤가 먹통'이 된다. dismiss 정상 완료 시 nil 로 비운다.
        private var finishPendingDismiss: (() -> Void)?

        private let cardRadius = HomeDesign.Radius.md
        private let detailHeaderRadius = HomeDesign.Radius.lg
        private let dimMaxAlpha: CGFloat = 0.45
        /// 드래그 dismiss 중 상세 화면에 입히는 최대 코너 라운딩 (Photos 앱 컨벤션).
        private let dragCornerRadius: CGFloat = 28

        /// 상세 화면에서 hero 이미지(`ScreenshotPreviewImage`)가 차지하는 글로벌 frame.
        /// DetailView 레이아웃: `NavigationStack`(inline bar) → `ScrollView`.padding(lg=16)
        ///   → `RecallHeader` 최상단 이미지(가로 꽉, 4:3, DetailView.swift RecallHeader).
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
        // App Store 카드 스타일의 3겹 합성 (위에서 아래로):
        //  [이미지 스냅샷] — 카드 썸네일 → 상세 헤더로 비행하는 공유 요소 (radius 16→20, top corner)
        //  [흰 컨테이너 + 카드 잔상] — 카드 몸체가 화면 크기로 자라며 상세에 녹아 사라진다
        //  [상세 VC] — 컨테이너가 자라는 동안 그 밑에서 차오른다
        //  [dim] — 홈을 어둡게 눌러 깊이를 만들고, 떠난 카드의 잔상을 가린다
        //
        //  1. present 전 — 카드 영역을 window 에서 통째 스냅샷(잔상), 원본 캡처를 직접 로드(비행체).
        //     화면 비트맵의 이미지는 종류 배지가 같이 찍혀 확대되므로 비행체는 relativePath 로 따로 뜬다.
        //  2. 상세 VC 를 alpha=0 으로 present (시스템 전환 없음). 애니메이션은 모두 completion 에서.
        //  3. 비행이 끝난 뒤 상세 hero 이미지를 켜고 스냅샷이 그 위에서 사라진다 — 끊김 없는 착지.
        //  → 이미지가 없는 카드(memo/url)도 컨테이너 확장은 동일 — 카드가 자라는 감각을 공유한다.
        //  → hero 자체가 없으면(캘린더 진입) 중앙 scale 폴백.

        private func present(
            store: StoreOf<DetailFeature>,
            hero: HeroSourceFrames?,
            host: UIViewController
        ) {
            guard let window = host.view.window else { return }
            // 진행 중이던 dismiss 가 있으면 즉시 끝낸다 — 죽어가는 VC 가 계층에 남아 아래 presenter
            // 탐색에 잡혀 그 위에 새 VC 가 쌓이는 교체 진입 경합('투명 먹통')을 차단한다.
            finishPendingDismiss?()
            self.detailStore = store

            // present 할 곳 — sheet(캘린더 DaySheet 등)가 떠 있으면 최상단 presented VC.
            // host 에서 직접 present 하면 "already presenting" 으로 실패하고, sheet 는
            // 열어둔 채 상세가 위를 덮어 닫으면 보던 목록으로 돌아간다.
            var presenter: UIViewController = host
            while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
                presenter = presented
            }

            // sheet 위 present 면 hero frame 은 sheet 콘텐츠 루트 기준(SwiftUI .global)이라
            // window 좌표로 보정한다 — 메인 계층(.global == window)은 presenter == host 라 보정 없음.
            var hero = hero
            if presenter !== host, let raw = hero {
                hero = HeroSourceFrames(
                    card: presenter.view.convert(raw.card, to: window),
                    cardImage: raw.cardImage.map { presenter.view.convert($0, to: window) },
                    imageRelativePath: raw.imageRelativePath
                )
            }
            self.hero = hero

            let hosting = UIHostingController(
                rootView: DetailRootView(store: store)
            )
            hosting.modalPresentationStyle = .overFullScreen
            hosting.view.alpha = 0
            self.hosting = hosting

            // ① 비행용 원본 캡처 로드 — 배지·테두리 없는 순수 이미지. 카드가 가로 스크롤에서
            //    잘려 있어도 완전한 이미지가 펼쳐지며 비행한다.
            let thumbFrame = hero?.cardImage
            let flightImage = thumbFrame != nil
                ? loadContainerThumbnailSync(relativePath: hero?.imageRelativePath, maxPixel: 1000)
                : nil
            cardThumbImage = flightImage

            // ② dim — 홈(rootVC) 위, 곧 present 될 상세(UITransitionView) **아래**에 깔린다.
            //    SwiftUI 앱의 rootViewController 는 UIHostingController 라, 그 .view 에 평범한 UIView 를
            //    addSubview 하면 "broken view hierarchy" 경고가 난다. 대신 window 에 직접 붙이고,
            //    present 를 이 뒤(⑤)에서 호출해 상세가 dim 위로 쌓이게 — z-order 는 추가 순서로 잡는다.
            let dim = UIView(frame: window.bounds)
            dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            dim.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.165, alpha: 1) // ink900
            dim.alpha = 0
            // 장식 전용 — present 가 드물게 실패해 dim 이 남아도 터치를 막지 않게.
            dim.isUserInteractionEnabled = false
            window.addSubview(dim)
            dimView = dim

            // ③ 카드 몸체 컨테이너 — 카드 frame 에서 출발하는 흰 면 + 카드 잔상 스냅샷.
            //    t0 에 카드를 정확히 덮어 "카드가 떠오른다"로 읽히고, 자라면서 상세로 녹는다.
            var container: UIView?
            var cardSnap: UIView?
            if let cardFrame = hero?.card, cardFrame.width > 0 {
                let body = UIView(frame: cardFrame)
                body.backgroundColor = .white
                body.layer.cornerRadius = cardRadius
                body.layer.cornerCurve = .continuous
                body.clipsToBounds = true
                if let snap = window.resizableSnapshotView(
                    from: cardFrame, afterScreenUpdates: false, withCapInsets: .zero
                ) {
                    snap.frame = body.bounds
                    snap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    body.addSubview(snap)
                    cardSnap = snap
                }
                container = body
            }

            // ④ 비행체 — 카드 썸네일 위치에서 출발. 양 끝 모두 위쪽 모서리만 둥글므로 top corner 만 마스크.
            var imageSnap: UIImageView?
            if let thumbFrame, let flightImage {
                let imageView = UIImageView(image: flightImage)
                imageView.frame = thumbFrame
                // 가로 캡처는 fit + 흰 레터박스 — 카드·상세 헤더(가로=fit)와 모양을 맞춰 비행 중 튐 제거.
                // 0.55s 빠른 확대라 레터박스 블러는 생략(카드·상세 정지 화면만 블러).
                let isLandscape = flightImage.size.width > flightImage.size.height
                imageView.contentMode = isLandscape ? .scaleAspectFit : .scaleAspectFill
                imageView.backgroundColor = isLandscape ? .white : .clear
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = cardRadius
                imageView.layer.cornerCurve = .continuous
                imageView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                imageSnap = imageView
            }

            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)

            // ⑤ 상세 VC 를 시스템 애니메이션 없이 즉시 present (alpha=0 이라 보이지 않음).
            //    모든 애니메이션은 present **completion**(= view 가 window 에 부착 완료된 시점)에서 건다.
            //    present(animated:false) 직후 동기적으로 애니메이트하면 view 부착 전이라 무시된다.
            presenter.present(hosting, animated: false) { [weak self, weak hosting] in
                guard let self, let hosting else { return }

                guard let container else {
                    // hero 없음(캘린더 진입 등) — 중앙 scale 폴백 + dim.
                    self.detailStore?.send(.setHeroImageHidden(false))
                    hosting.view.transform = CGAffineTransform(scaleX: 0.94, y: 0.94)
                    UIView.animate(
                        withDuration: 0.30,
                        delay: 0,
                        usingSpringWithDamping: 1.0,
                        initialSpringVelocity: 0
                    ) {
                        hosting.view.alpha = 1
                        hosting.view.transform = .identity
                        dim.alpha = self.dimMaxAlpha
                    }
                    return
                }

                window.addSubview(container)
                if let imageSnap { window.addSubview(imageSnap) }
                let destImage = Self.detailImageFrame(in: window)

                // 본 비행 — 컨테이너 확장 + 이미지 비행 + dim. 하나의 스프링으로 묶어 일체감.
                let flight = UIViewPropertyAnimator(duration: 0.55, dampingRatio: 0.86) {
                    container.frame = window.bounds
                    container.layer.cornerRadius = self.dragCornerRadius
                    imageSnap?.frame = destImage
                    imageSnap?.layer.cornerRadius = self.detailHeaderRadius
                    dim.alpha = self.dimMaxAlpha
                }

                // 카드 잔상은 초반에 소멸 — 텍스트가 늘어나며 따라오는 어색함을 끊는다.
                UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                    cardSnap?.alpha = 0
                }
                // 상세 컨텐츠는 카드가 충분히 자란 뒤 그 밑에서 차오른다.
                UIView.animate(withDuration: 0.32, delay: 0.10, options: [.curveEaseOut]) {
                    hosting.view.alpha = 1
                }
                // 흰 컨테이너는 후반에 상세 화면으로 녹아 사라진다 (상세 bg 가 near-white 라 이음새 없음).
                UIView.animate(withDuration: 0.26, delay: 0.22, options: [.curveEaseInOut]) {
                    container.alpha = 0
                } completion: { _ in container.removeFromSuperview() }

                flight.addCompletion { _ in
                    // 착지: 상세 hero 이미지를 즉시 켜고(상세 쪽은 애니메이션 없이 reveal),
                    // SwiftUI 커밋이 화면에 반영될 시간을 두 프레임쯤 둔 뒤 스냅샷을 걷는다.
                    // 동일 이미지 crossfade 는 합성 불투명도가 1 아래로 꺼져 깜박이므로,
                    // "밑에서 완전히 켜진 뒤 위를 걷어내는" 순서만 허용한다.
                    self.detailStore?.send(.setHeroImageHidden(false))
                    if let imageSnap {
                        UIView.animate(withDuration: 0.20, delay: 0.12, options: [.curveEaseOut]) {
                            imageSnap.alpha = 0
                        } completion: { _ in imageSnap.removeFromSuperview() }
                    }
                }
                flight.startAnimation()
            }

            // 드래그 dismiss gesture + 내부 ScrollView 추적
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.delegate = self
            hosting.view.addGestureRecognizer(pan)
            DispatchQueue.main.async { [weak self, weak hosting] in
                self?.scrollView = hosting?.view.firstScrollView()
            }

            // present 실패 self-heal — presenter 가 dismiss 진행 중이던 드문 경합에서
            // UIKit present 가 조용히 실패하면(completion 미호출) dim·상태가 남아
            // 이후 상세 진입이 영구히 막힌다. 다음 runloop 에 부착 여부를 확인해 거둔다.
            DispatchQueue.main.async { [weak self, weak hosting] in
                guard let self, let hosting, hosting.presentingViewController == nil else { return }
                self.dimView?.removeFromSuperview()
                self.hosting = nil
                self.detailStore = nil
                self.onDismiss?()  // store nil → state.detail 정리, 재시도 가능
            }
        }

        // MARK: - dismiss (상세 hero 이미지 → 카드 썸네일 위치로 축소)
        //
        // present 의 대칭: 상세 이미지 영역만 스냅샷 떠서 카드 썸네일 자리로 돌려보내고, 본문은 fade-out.
        // 상세 전체를 카드 크기로 축소하면 "창문이 쪼그라드는" 느낌이라 공간 연속성이 깨진다.
        // 드래그로 변형(transform)된 상태에서 와도 convert 가 현재 위치를 반영해 그 자리에서 출발한다.

        private func dismiss(_ hosting: UIViewController) {
            guard self.hosting === hosting else { return }
            self.hosting = nil
            runDismissTransition(hosting)
        }

        private func runDismissTransition(_ hosting: UIViewController) {
            // 이 dismiss 가 책임질 자원을 로컬로 캡처하고, Coordinator 의 '현재 상세' 참조는 즉시 비운다.
            // dismiss 비행(최대 0.45s) 도중 새 present 가 끼어들어 self 를 자기 상세로 채워도, 이 dismiss 의
            // 정리(completion)는 캡처한 로컬만 건드려 새 상세를 오염시키지 않는다(교체 진입 '투명 먹통' 방지).
            let dim = dimView
            let onDismiss = self.onDismiss
            let store = self.detailStore
            self.dimView = nil
            self.onDismiss = nil
            self.detailStore = nil

            guard let window = hosting.view.window,
                  store?.path.isEmpty ?? true,   // 자식 push 중 닫기(드래그/메뉴)는 hero 비행 스킵 → fade. 스택 전체 종료.
                  let thumb = hero?.cardImage,
                  let image = cardThumbImage,
                  let source = visibleDetailImageFrame(of: hosting, in: window) else {
                // 공유 이미지 없음(memo/url·hero 없음)·hero 이미지가 스크롤로 화면 밖·자식 상세 위에서 닫음 —
                // 살짝 줄어들며 fade-out (이미지 비행 없이도 "제자리로 돌아가는" 뉘앙스).
                let animator = UIViewPropertyAnimator(duration: 0.30, dampingRatio: 1) {
                    hosting.view.alpha = 0
                    hosting.view.transform = hosting.view.transform.scaledBy(x: 0.96, y: 0.96)
                    dim?.alpha = 0
                }
                var didTearDown = false
                let teardown: () -> Void = {
                    guard !didTearDown else { return }   // 정상 완료와 가로채기 finalize 가 겹쳐도 1회만.
                    didTearDown = true
                    dim?.removeFromSuperview()
                    hosting.dismiss(animated: false)
                }
                animator.addCompletion { [weak self] _ in
                    self?.finishPendingDismiss = nil
                    teardown()
                    onDismiss?()   // 정상 종료 — 슬롯(state.detail) 비우기
                }
                self.finishPendingDismiss = { [weak self] in
                    self?.finishPendingDismiss = nil
                    animator.stopAnimation(true)
                    teardown()
                    // onDismiss 는 호출하지 않는다 — 끼어든 present 가 이미 슬롯을 차지했으므로 비우면 안 된다.
                }
                animator.startAnimation()
                return
            }

            // 목업(스냅샷)을 화면에 올리는 순간 상세 hero 이미지를 숨겨, 둘이 겹쳐 보이지 않게 한다.
            store?.send(.setHeroImageHidden(true))

            let snap = UIImageView(image: image)
            snap.frame = source
            // present 비행체와 동일 정책 — 가로 캡처는 fit + 흰 레터박스로 돌려보낸다.
            let isLandscape = image.size.width > image.size.height
            snap.contentMode = isLandscape ? .scaleAspectFit : .scaleAspectFill
            snap.backgroundColor = isLandscape ? .white : .clear
            snap.clipsToBounds = true
            snap.layer.cornerRadius = detailHeaderRadius
            snap.layer.cornerCurve = .continuous
            snap.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            window.addSubview(snap)

            // 본문(이미지 외 chrome) fade-out
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseIn]) {
                hosting.view.alpha = 0
            }

            // 스냅샷을 카드 썸네일 자리로 축소 + dim 해제를 한 스프링으로.
            let flight = UIViewPropertyAnimator(duration: 0.45, dampingRatio: 0.9) {
                snap.frame = thumb
                snap.layer.cornerRadius = self.cardRadius
                dim?.alpha = 0
            }
            var didTearDown = false
            let teardown: () -> Void = {
                guard !didTearDown else { return }   // 정상 완료와 가로채기 finalize 가 겹쳐도 1회만.
                didTearDown = true
                snap.removeFromSuperview()
                dim?.removeFromSuperview()
                hosting.dismiss(animated: false)
            }
            flight.addCompletion { [weak self] _ in
                self?.finishPendingDismiss = nil
                teardown()
                onDismiss?()   // 정상 종료 — 슬롯(state.detail) 비우기
            }
            self.finishPendingDismiss = { [weak self] in
                self?.finishPendingDismiss = nil
                flight.stopAnimation(true)
                teardown()
                // onDismiss 는 호출하지 않는다 — 끼어든 present 가 이미 슬롯을 차지했으므로 비우면 안 된다.
            }
            flight.startAnimation()
        }

        /// 상세 hero 이미지의 **현재** 글로벌 frame — 스크롤 오프셋과 드래그 transform 을 반영한다.
        /// 이미지가 스크롤로 절반 이상 가려졌으면 nil → 비행 대신 fade 폴백.
        private func visibleDetailImageFrame(of hosting: UIViewController, in window: UIWindow) -> CGRect? {
            var rect = Self.detailImageFrame(in: window)
            if let scrollView {
                let scrolled = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
                guard scrolled < rect.height * 0.5 else { return nil }
                rect.origin.y -= scrolled
            }
            // hosting.view 좌표(= identity 기준 window 와 동일)에서 window 로 — transform 반영.
            return hosting.view.convert(rect, to: window)
        }

        // MARK: - 드래그 dismiss (아래로 당기면 닫기)
        //
        // Photos 컨벤션: 당길수록 화면이 줄고 코너가 둥글어지며 dim 이 걷힌다.
        // 임계를 넘겨 놓으면 그 자리에서 카드로 복귀하는 본 dismiss 비행으로 이어진다.

        @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let hosting, let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            let progress = min(max(translation.y / max(view.bounds.height, 1), 0), 1)

            switch gesture.state {
            case .began:
                view.clipsToBounds = true
                view.layer.cornerCurve = .continuous
            case .changed:
                // 콘텐츠 위에서 끌어내릴 때(스크롤뷰 pan 과 동시 인식) 스크롤은 rubber-band 하지
                // 않게 최상단에 고정한다 — 화면 이동과 오버스크롤이 겹쳐 두 배로 밀리는 것 방지.
                if translation.y > 0, let scrollView {
                    scrollView.contentOffset = CGPoint(x: 0, y: -scrollView.adjustedContentInset.top)
                }
                let scale = 1 - progress * 0.18
                view.transform = CGAffineTransform(translationX: translation.x * 0.35, y: translation.y)
                    .scaledBy(x: scale, y: scale)
                view.layer.cornerRadius = dragCornerRadius * min(progress * 4, 1)
                dimView?.alpha = dimMaxAlpha * (1 - progress * 0.9)
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: view).y
                if gesture.state == .ended, progress > 0.25 || velocity > 900 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.hosting = nil
                    runDismissTransition(hosting)
                } else {
                    UIView.animate(
                        withDuration: 0.42,
                        delay: 0,
                        usingSpringWithDamping: 0.86,
                        initialSpringVelocity: 0
                    ) {
                        view.transform = .identity
                        view.layer.cornerRadius = 0
                        self.dimView?.alpha = self.dimMaxAlpha
                    }
                }
            default:
                break
            }
        }

        // 아래 방향 + 내부 ScrollView 가 최상단일 때 드래그 dismiss 시작.
        // root·자식(비슷한 기록 push) 어느 화면에서든 아래로 끌면 스택 전체를 한 번에 닫는다(→ 홈).
        // 가로 엣지 스와이프(시스템 back, 한 칸 뒤로)와는 velocity 방향으로 분리된다.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
            let velocity = pan.velocity(in: view)
            guard velocity.y > abs(velocity.x) else { return false }   // 세로 우세만(가로 엣지 pop 과 분리)
            // 현재 화면(root 또는 push 된 자식)의 ScrollView 를 그때그때 잡는다 — push 가 끝나면
            // hosting.view 트리의 첫 ScrollView 가 보통 현재 화면 것이다(전환 애니메이션 중 짧게 root·자식
            // ScrollView 가 공존할 수 있으나, 제스처는 손가락이 멈춘 화면에서 시작되므로 현재 화면을 잡는다).
            // dismiss 는 자식 위에선 hero 없이 fade(runDismissTransition 의 path 가드).
            let sv = hosting?.view.firstScrollView()
            scrollView = sv
            if let sv {
                return sv.contentOffset.y <= -sv.adjustedContentInset.top + 0.5
            }
            return true
        }

        // 스크롤뷰의 pan 과 동시 인식 — 이게 없으면 스크롤 콘텐츠 위에서는 스크롤뷰가 제스처를
        // 독점해 navigation bar 영역에서만 드래그 dismiss 가 가능하다. 최상단에서 끌어내리는
        // 오버스크롤도 dismiss 로 이어지게 한다 (.changed 에서 contentOffset 고정으로 이중 이동 방지).
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.view is UIScrollView
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
