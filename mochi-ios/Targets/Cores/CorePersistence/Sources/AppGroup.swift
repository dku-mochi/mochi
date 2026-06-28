import Foundation

/// App, ShareExtension이 공유하는 App Group 식별자와 컨테이너 URL.
///
/// 동일 식별자가 다음 파일들에 박혀 있어야 한다:
/// - Targets/App/Support/App.entitlements
/// - Targets/ShareExtension/Support/ShareExtension.entitlements
public enum AppGroup {
    public static let identifier = "group.app.mochi"

    public static var containerURL: URL {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            assertionFailure("App Group container 접근 실패 — entitlements를 확인하세요: \(identifier)")
            return FileManager.default.temporaryDirectory
        }
        return url
    }

    public static var realmFileURL: URL {
        containerURL.appendingPathComponent("mochi.realm")
    }

    public static var capturedImagesDirectoryURL: URL {
        let url = containerURL.appendingPathComponent("captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 로그아웃·계정 전환 시 로컬 캡처 이미지를 전부 삭제한다(프라이버시 — 이전 사용자 이미지 잔존 방지).
    /// 디렉토리 자체는 유지하고 내용만 비운다. Realm 항목 삭제(`MochiItemRepository.deleteAll`)와 함께 호출한다.
    public static func clearCapturedImages() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: capturedImagesDirectoryURL, includingPropertiesForKeys: nil)) ?? []
        for url in urls { try? fm.removeItem(at: url) }
    }

    /// ShareExtension이 데이터를 즉시 메인 앱과 공유할 수 없을 때 사용하는 inbound 큐.
    public static var inboundQueueURL: URL {
        let url = containerURL.appendingPathComponent("inbound-queue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 온보딩 백탭 검증 핸드셰이크 마커(`verify.active`/`verify.hit`)가 사는 App Group 디렉터리.
    ///
    /// 백탭 캡처는 ShareExtension(`Take Screenshot → Share → 모찌`) 단일 경로로 이관됐고(2026-06-02),
    /// 옛 AppIntent snippet 경로(PNG/`.memo` stash)는 제거됐다(2026-06-25). 남은 용도는 아래
    /// 검증 핸드셰이크뿐이라, 디렉터리 이름은 컨벤션 유지차 보존한다.
    public static var pendingBackTapDirectoryURL: URL {
        let url = containerURL.appendingPathComponent("pending-backtap", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 백탭 온보딩 검증 핸드셰이크 (1회성, App Group 파일 마커)

    /// 온보딩의 "지금 백탭 해보세요" 단계가 쓰는 단명 핸드셰이크.
    ///
    /// 목적: 사용자가 단축어를 추가하고 뒷면 탭에 연결했는지를 *간접 ack* 가 아니라
    /// **백탭이 실제로 모찌(ShareExtension)에 도달하는지** 로 증명한다. 검증 창이 열려 있는 동안
    /// `ShareExtensionPrincipal` 은 진짜 저장 대신 hit 마커만 남긴다 — 검증용 백탭이
    /// 쓰레기 `MochiItem` 을 만들어 메모리를 오염시키지 않게 하기 위함이다.
    ///
    /// **신호는 App Group 파일 마커로 주고받는다** (UserDefaults 아님). ShareExtension 은
    /// 별도 프로세스라, `UserDefaults(suiteName:)` 는 `kCFPreferencesAnyUser ... detaching
    /// from cfprefsd` 경고와 함께 프로세스 간 전파가 불안정하다. 반면 App Group 컨테이너의
    /// 파일은 같은 inode 라 즉시 공유돼, 메인 앱 ↔ extension 사이의 검증된 전파 패턴이다.
    /// 온보딩은 CorePersistence 를 직접 의존하지 않아 `BackTapVerificationClient` 가 이 API 를 감싼다.

    /// 검증 창 유효 시간. 지나면 `isBackTapVerificationActive` 가 자동으로 false 가 되어,
    /// 정리에 실패해도 다음 백탭이 검증 모드로 새지 않는다 (fail-safe).
    public static let backTapVerificationTTL: TimeInterval = 120

    private static var verifyActiveURL: URL {
        pendingBackTapDirectoryURL.appendingPathComponent("verify.active")
    }
    private static var verifyHitURL: URL {
        pendingBackTapDirectoryURL.appendingPathComponent("verify.hit")
    }

    /// 온보딩이 검증 단계에 진입할 때 호출 — 이전 hit 을 청소하고 창(active)을 연다.
    public static func beginBackTapVerification() {
        try? FileManager.default.removeItem(at: verifyHitURL)
        writeTimestamp(Date(), to: verifyActiveURL)
    }

    /// `ShareExtensionPrincipal` 이 분기 판단에 쓴다 — 창이 열려 있고 TTL 이내인가.
    public static var isBackTapVerificationActive: Bool {
        guard let start = readTimestamp(verifyActiveURL) else { return false }
        return Date().timeIntervalSince1970 - start < backTapVerificationTTL
    }

    /// 검증 모드의 백탭이 도달했을 때 호출 (`ShareExtensionPrincipal`) —
    /// hit 을 남기고 **창을 즉시 소비(active 제거)**한다. 검증은 1회성이라 이 직후의 일반 백탭은
    /// 다시 정상 저장 흐름으로 떠야 한다 (stale 검증 모드로 ShareExtension 이 계속 검증 카드만
    /// 띄우는 것 방지).
    public static func markBackTapVerificationHit() {
        writeTimestamp(Date(), to: verifyHitURL)
        try? FileManager.default.removeItem(at: verifyActiveURL)
    }

    /// 온보딩이 폴링으로 확인 — hit 마커가 존재하는가. `begin` 이 이전 hit 을 청소하므로
    /// 존재 = 이번 창에서 찍힌 hit (active 가 markHit 으로 소비돼도 감지가 유지된다).
    public static var backTapVerificationDidHit: Bool {
        FileManager.default.fileExists(atPath: verifyHitURL.path)
    }

    /// 검증 종료(감지 성공 / 타임아웃 / 단계 이탈) 시 호출 — 마커를 모두 비운다.
    public static func endBackTapVerification() {
        try? FileManager.default.removeItem(at: verifyActiveURL)
        try? FileManager.default.removeItem(at: verifyHitURL)
    }

    private static func writeTimestamp(_ date: Date, to url: URL) {
        try? Data("\(date.timeIntervalSince1970)".utf8).write(to: url, options: .atomic)
    }

    private static func readTimestamp(_ url: URL) -> TimeInterval? {
        guard let data = try? Data(contentsOf: url),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return TimeInterval(str.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - 공유 백엔드 baseURL (ShareExtension 직접 전송용)

    private static let apiBaseURLKey = "mochi.apiBaseURL"

    /// 메인 앱이 부팅 시 결정한 백엔드 baseURL. ShareExtension 은 `AppDependencies.bootstrap()`
    /// 이 돌지 않아 baseURL 을 모르므로, 직접 전송 시 이 값을 읽는다. 없으면(앱 미실행) 직접
    /// 전송을 포기하고 inbound 큐로 폴백한다.
    public static var sharedAPIBaseURL: URL? {
        UserDefaults(suiteName: identifier)?
            .string(forKey: apiBaseURLKey)
            .flatMap(URL.init(string:))
    }

    /// 메인 앱 부팅 시 호출 — 결정한 baseURL 을 App Group 으로 공유한다.
    public static func setSharedAPIBaseURL(_ url: URL) {
        UserDefaults(suiteName: identifier)?.set(url.absoluteString, forKey: apiBaseURLKey)
    }
}
