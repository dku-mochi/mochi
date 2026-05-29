import SwiftUI
import UIKit
import UserNotifications
import UserNotificationsUI

import CoreLiveActivity

/// 모찌 알림이 펼쳐졌을 때 표시되는 custom UI 의 호스트.
///
/// `Info.plist` 의 `UNNotificationExtensionCategory = "MOCK_USECASE_V0"` 와 알림의
/// `categoryIdentifier` 가 매칭되면 시스템이 본 view controller 를 알림 안에 embed 한다.
///
/// SwiftUI view (`MultiSelectCandidateView`) 를 `UIHostingController` 로 감싸 child VC 로
/// 추가하는 패턴. iOS 16+ 의 SwiftUI 가 notification content extension 안에서 동작한다
/// (Apple Forums 121795).
///
/// **자유 텍스트 입력은 안 됨** — Apple design 차원에서 TextField 가 막힘. 사용자가 "다른
/// 의도" 를 누르면 `UNNotificationAction(options: .foreground)` 를 발사해 모찌 앱으로
/// 진입한다 (액션 라우팅은 `MockUseCaseNotificationPrototype` 의 category 정의 참고).
final class NotificationViewController: UIViewController, UNNotificationContentExtension {

    private var hostingController: UIHostingController<MultiSelectCandidateView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
    }

    func didReceive(_ notification: UNNotification) {
        let userInfo = notification.request.content.userInfo
        let candidates = Self.candidates(from: userInfo)
        let caption = (userInfo["caption"] as? String) ?? notification.request.content.subtitle

        let view = MultiSelectCandidateView(caption: caption, candidates: candidates)
        embed(view: view)

        // 본 extension 영역의 사이즈를 컨텐츠에 맞춰 동적 조절. Apple 권고: 가능한 작게.
        // (UNNotificationExtensionInitialContentSizeRatio 가 초기값, 이건 동적 갱신.)
        let approxHeight: CGFloat = 56 /* caption */ + CGFloat(candidates.count) * 56 + 80 /* footer */
        preferredContentSize = CGSize(width: self.view.bounds.width, height: approxHeight)
    }

    private func embed(view: MultiSelectCandidateView) {
        if let existing = hostingController {
            existing.willMove(toParent: nil)
            existing.view.removeFromSuperview()
            existing.removeFromParent()
        }
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    // MARK: - userInfo decode

    /// 알림 페이로드의 `candidates` 배열을 디코드. payload 손상 시 mock 기본값 사용.
    private static func candidates(from userInfo: [AnyHashable: Any]) -> [MockUseCaseActivityAttributes.Candidate] {
        guard let raw = userInfo["candidates"] as? [[String: Any]] else {
            return MockUseCaseDefaults.candidates
        }
        let decoded: [MockUseCaseActivityAttributes.Candidate] = raw.compactMap { dict in
            guard
                let label = dict["label"] as? String,
                let intent = dict["intent"] as? String,
                let app = dict["applicability"] as? Double
            else { return nil }
            return .init(label: label, intent: intent, applicability: app)
        }
        return decoded.isEmpty ? MockUseCaseDefaults.candidates : decoded
    }
}

/// 페이로드가 비었을 때 대비 mock 후보. lab/ 의 v6 마우스 케이스.
enum MockUseCaseDefaults {
    static let candidates: [MockUseCaseActivityAttributes.Candidate] = [
        .init(label: "구매 고민", intent: "todo",      applicability: 0.95),
        .init(label: "가격 비교", intent: "knowledge", applicability: 0.75),
        .init(label: "위시리스트", intent: "memo",     applicability: 0.55),
    ]
}
