import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

/// Sign in with Apple 흐름의 시스템 시트 진입점.
///
/// **흐름:**
/// 1. ``rawNonce = 32 byte CSPRNG → base64url``
/// 2. ``hashedNonce = SHA-256(rawNonce) → hex``
/// 3. ``ASAuthorizationAppleIDRequest`` 에 ``hashedNonce`` 를 nonce 로 세팅
/// 4. Apple 시트 → ``identityToken`` 안에 ``nonce: hashedNonce`` 가 포함됨
/// 5. ``rawNonce`` 를 서버로 보내, 서버가 SHA-256 후 동일성 검증 (replay 방어)
public protocol AppleAuthClient: Sendable {
    @MainActor func authorize() async throws -> AppleRawCredential
}

public final class LiveAppleAuthClient: NSObject, AppleAuthClient {

    public override init() {}

    @MainActor
    public func authorize() async throws -> AppleRawCredential {
        let rawNonce = Self.generateNonce()
        let hashedNonce = Self.sha256(rawNonce)

        let provider = ASAuthorizationAppleIDProvider()
        let request = provider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = hashedNonce

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = AppleDelegate(rawNonce: rawNonce)
        controller.delegate = delegate
        controller.presentationContextProvider = delegate

        return try await withCheckedThrowingContinuation { continuation in
            delegate.onComplete = { result in
                continuation.resume(with: result)
            }
            controller.performRequests()
        }
    }

    private static func generateNonce(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func sha256(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
private final class AppleDelegate: NSObject,
                                   ASAuthorizationControllerDelegate,
                                   ASAuthorizationControllerPresentationContextProviding {
    let rawNonce: String
    var onComplete: ((Result<AppleRawCredential, Error>) -> Void)?
    /// 약한 self-ownership 패턴: continuation 콜백이 끝날 때까지 delegate 가 살아 있어야 한다.
    /// ASAuthorizationController.delegate 는 weak 이므로 strong reference 를 유지.
    private var retainSelf: AppleDelegate?

    init(rawNonce: String) {
        self.rawNonce = rawNonce
        super.init()
        retainSelf = self
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        defer { retainSelf = nil }
        guard
            let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let identityTokenData = credential.identityToken,
            let identityToken = String(data: identityTokenData, encoding: .utf8)
        else {
            onComplete?(.failure(AuthError.providerFailed(message: "Apple identityToken 누락")))
            return
        }

        let fullName = Self.formatName(credential.fullName)
        let result = AppleRawCredential(
            identityToken: identityToken,
            rawNonce: rawNonce,
            fullName: fullName,
            userIdentifier: credential.user
        )
        onComplete?(.success(result))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        defer { retainSelf = nil }
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            onComplete?(.failure(AuthError.canceled))
            return
        }
        onComplete?(.failure(AuthError.providerFailed(message: error.localizedDescription)))
    }

    private static func formatName(_ name: PersonNameComponents?) -> String? {
        guard let name else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let formatted = formatter.string(from: name).trimmingCharacters(in: .whitespaces)
        return formatted.isEmpty ? nil : formatted
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
