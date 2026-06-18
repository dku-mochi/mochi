import SwiftUI
import UIKit

/// 원형 네비게이션 버튼의 칩(라벨). bg(F2F4F7)·dim 위에서도 또렷한 모달 어포던스 —
/// 기록 상세 toolbar 버튼(X·즐겨찾기·메뉴)·카테고리 턴테이블 back 이 같은 모양을 쓰도록 단일화한다.
/// 버튼 동작(탭 핸들러)은 호출부가 `Button { } label: { CircularGlyph(...) }` 로 감싼다.
public struct CircularGlyph: View {
    let systemName: String
    var diameter: CGFloat
    var glyphSize: CGFloat

    public init(_ systemName: String, diameter: CGFloat = 30, glyphSize: CGFloat = 13) {
        self.systemName = systemName
        self.diameter = diameter
        self.glyphSize = glyphSize
    }

    public var body: some View {
        Image(systemName: systemName)
            .font(.system(size: glyphSize, weight: .semibold))
            .foregroundStyle(HomeDesign.Color.textPrimary)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(HomeDesign.Color.surface))
            .overlay(Circle().stroke(HomeDesign.Color.border, lineWidth: 1))
            .shadow(color: HomeDesign.Color.ink900.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

// MARK: - 커스텀 back 버튼과 함께 쓰는 네이티브 스와이프-백

public extension View {
    /// 시스템 back/네비바를 숨기고 커스텀 back 버튼을 쓰는 화면에서도 **가장자리 스와이프-백**을 살린다.
    /// `UINavigationController.interactivePopGestureRecognizer` 를 다시 켜고, 루트(스택 1개)에선
    /// 시작하지 않도록 delegate 를 건다(루트에서 스와이프 시 프리즈 방지). 네이티브 pop 이라 전환·애니메이션이
    /// 시스템과 동일하다.
    func interactiveSwipeBackEnabled() -> some View {
        background(InteractiveSwipeBack().frame(width: 0, height: 0))
    }
}

private struct InteractiveSwipeBack: UIViewControllerRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIViewController(context: Context) -> UIViewController { Probe(coordinator: context.coordinator) }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var nav: UINavigationController?
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            (nav?.viewControllers.count ?? 0) > 1
        }
    }

    /// 뷰 계층에 끼어 부모 UINavigationController 를 찾아 pop 제스처를 되살리는 0pt probe.
    final class Probe: UIViewController {
        let coordinator: Coordinator
        init(coordinator: Coordinator) {
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            guard let nav = navigationController else { return }
            coordinator.nav = nav
            nav.interactivePopGestureRecognizer?.isEnabled = true
            nav.interactivePopGestureRecognizer?.delegate = coordinator
        }
    }
}
