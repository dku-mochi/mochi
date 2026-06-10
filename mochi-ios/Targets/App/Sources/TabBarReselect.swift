import SwiftUI
import UIKit

/// SwiftUI TabView 의 *현재 선택 탭 재탭* 감지 helper.
///
/// iOS 17 의 TabView selection binding 은 같은 값으로 set 시 setter 호출이 안 되어
/// reducer 에 "재탭" 이벤트가 전달되지 않는다. `UITabBarController.delegate` 의
/// `shouldSelect` 는 같은 탭 재탭에도 항상 호출되므로 그것을 hook 해 우회.
///
/// 사용: 각 탭의 root view 에 `.background(TabBarReselect { ... })`.
struct TabBarReselect: UIViewControllerRepresentable {
    let onReselect: () -> Void

    func makeUIViewController(context: Context) -> ProbeViewController {
        let vc = ProbeViewController()
        vc.onReselect = onReselect
        return vc
    }

    func updateUIViewController(_ uiViewController: ProbeViewController, context: Context) {
        uiViewController.onReselect = onReselect
    }

    final class ProbeViewController: UIViewController, UITabBarControllerDelegate {
        var onReselect: (() -> Void)?
        private weak var previousDelegate: (any UITabBarControllerDelegate)?
        private var hookInstalled = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installHookIfNeeded()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installHookIfNeeded()
        }

        private func installHookIfNeeded() {
            guard !hookInstalled, let tbc = self.tabBarController else { return }
            // iOS 17 SwiftUI TabView 는 자체 delegate 를 설치한다 — nil 가드를 두면 우리 hook 가 설치 X.
            // 기존 delegate 를 보존해 forwarding 하면 SwiftUI 내부 selection 처리도 그대로 작동.
            previousDelegate = tbc.delegate
            tbc.delegate = self
            hookInstalled = true
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            shouldSelect viewController: UIViewController
        ) -> Bool {
            // 같은 탭 재탭 감지: selectedViewController === 새 viewController.
            if let selected = tabBarController.selectedViewController, selected === viewController {
                onReselect?()
            }
            return previousDelegate?.tabBarController?(tabBarController, shouldSelect: viewController) ?? true
        }

        func tabBarController(
            _ tabBarController: UITabBarController,
            didSelect viewController: UIViewController
        ) {
            previousDelegate?.tabBarController?(tabBarController, didSelect: viewController)
        }
    }
}
