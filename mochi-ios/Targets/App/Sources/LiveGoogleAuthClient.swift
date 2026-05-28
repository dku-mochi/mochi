import CoreAuth
import Foundation
import GoogleSignIn
import UIKit

/// GoogleSignIn-iOS 8.x 의 시스템 시트 진입점.
///
/// **이 구현이 CoreAuth 가 아닌 App 타겟에 있는 이유:** ``CoreAuth/GoogleAuthClient.swift`` 의 doc-comment 참조.
/// 요약: GoogleSignIn-iOS Package.swift 가 AppAuthCore 를 transitive 로 link 하지 않아 하위 framework
/// 에서 import 하면 OBJC_CLASS_$_OID* undefined symbol 가 난다 → 최상위 binary 에서만 import.
///
/// `GIDClientID` 는 ``Info.plist`` 에 등록되어 있다고 가정 (docs/TODO.md §3.1).
final class LiveGoogleAuthClient: GoogleAuthClient {

    @MainActor
    func authorize() async throws -> GoogleRawCredential {
        // docs/TODO.md §3.1 에서 Reversed Client ID 를 채우기 전까지 Info.plist 에 placeholder 가
        // 남아 있다. 그대로 사용자에게 흐릿한 SDK 에러를 보여주는 대신, 빌드 단계에서 잡지 못한 설정 누락을
        // 명시적으로 알린다 (codex review P1).
        if Self.googleClientIDLooksLikePlaceholder() {
            throw AuthError.providerFailed(
                message: "Google 로그인 설정이 비어 있습니다. docs/TODO.md §3.1 의 Reversed Client ID 를 채워 주세요."
            )
        }

        guard let presenting = Self.topViewController() else {
            throw AuthError.providerFailed(message: "활성 화면을 찾지 못했습니다.")
        }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
            return try Self.toCredential(result.user)
        } catch let error as NSError {
            if error.code == GIDSignInError.canceled.rawValue {
                throw AuthError.canceled
            }
            throw AuthError.providerFailed(message: error.localizedDescription)
        }
    }

    private static func googleClientIDLooksLikePlaceholder() -> Bool {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        return clientID.isEmpty || clientID.contains("PLACEHOLDER_REVERSED_CLIENT_ID")
    }

    @MainActor @discardableResult
    func handle(url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }

    @MainActor
    func restorePreviousSignIn() async -> GoogleRawCredential? {
        guard GIDSignIn.sharedInstance.hasPreviousSignIn() else { return nil }
        return try? await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.restorePreviousSignIn { user, error in
                if let user, let credential = try? Self.toCredential(user) {
                    continuation.resume(returning: credential)
                } else {
                    continuation.resume(
                        throwing: error ?? AuthError.providerFailed(message: "Google 세션 복원 실패")
                    )
                }
            }
        }
    }

    private static func toCredential(_ user: GIDGoogleUser) throws -> GoogleRawCredential {
        guard let idToken = user.idToken?.tokenString else {
            throw AuthError.providerFailed(message: "Google idToken 누락")
        }
        return GoogleRawCredential(
            idToken: idToken,
            userIdentifier: user.userID ?? "",
            email: user.profile?.email,
            displayName: user.profile?.name
        )
    }

    @MainActor
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        guard let root = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else {
            return nil
        }
        var current = root
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}
