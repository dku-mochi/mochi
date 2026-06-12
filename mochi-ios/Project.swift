import ProjectDescription

// MARK: - Constants

private let bundleIdPrefix = "app.mochi"
private let deploymentTarget = "17.0"
private let swiftVersion = "5.0"
private let developmentTeam = "U9SLX327XS"
private let marketingVersion = "0.1.5"
private let currentProjectVersion = "5"
private let appGroup = "group.app.mochi"

private let baseSettings: SettingsDictionary = [
    "SWIFT_VERSION": .string(swiftVersion),
    "DEVELOPMENT_TEAM": .string(developmentTeam),
    "IPHONEOS_DEPLOYMENT_TARGET": .string(deploymentTarget),
    "SWIFT_STRICT_CONCURRENCY": "targeted",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    // App·ShareExtension 의 Info.plist 가 모두 이 두 변수를 참조한다.
    // 확장 타겟에서 누락되면 CFBundleVersion 이 빈 문자열이 되어 installd 가 설치를 거부한다.
    "MARKETING_VERSION": .string(marketingVersion),
    "CURRENT_PROJECT_VERSION": .string(currentProjectVersion),
]

// MARK: - Helpers

private enum Layer: String {
    case core = "Cores"
    case feature = "Features"
}

private func module(
    _ name: String,
    layer: Layer,
    dependencies: [TargetDependency] = [],
    resources: ResourceFileElements? = nil
) -> Target {
    .target(
        name: name,
        destinations: .iOS,
        product: .framework,
        bundleId: "\(bundleIdPrefix).\(name)",
        deploymentTargets: .iOS(deploymentTarget),
        sources: ["Targets/\(layer.rawValue)/\(name)/Sources/**"],
        resources: resources,
        dependencies: dependencies,
        settings: .settings(base: baseSettings)
    )
}

private func unitTests(
    for moduleName: String,
    layer: Layer,
    dependencies: [TargetDependency] = []
) -> Target {
    .target(
        name: "\(moduleName)Tests",
        destinations: .iOS,
        product: .unitTests,
        bundleId: "\(bundleIdPrefix).\(moduleName)Tests",
        deploymentTargets: .iOS(deploymentTarget),
        sources: ["Tests/\(layer.rawValue)/\(moduleName)Tests/Sources/**"],
        dependencies: [.target(name: moduleName)] + dependencies,
        settings: .settings(base: baseSettings)
    )
}

// MARK: - Project

let project = Project(
    name: "Mochi",
    organizationName: "Mochi",
    options: .options(
        defaultKnownRegions: ["en", "ko"],
        developmentRegion: "ko"
    ),
    packages: [
        .remote(url: "https://github.com/pointfreeco/swift-composable-architecture.git", requirement: .exact("1.17.1")),
        .remote(url: "https://github.com/pointfreeco/swift-dependencies.git", requirement: .exact("1.5.1")),
        .remote(url: "https://github.com/pointfreeco/swift-perception.git", requirement: .exact("1.6.0")),
        .remote(url: "https://github.com/pointfreeco/swift-navigation.git", requirement: .exact("2.8.0")),
        // ComposableArchitecture transitive — App 타겟에서 직접 link 해서 undefined symbol 방지.
        .remote(url: "https://github.com/pointfreeco/swift-case-paths.git", requirement: .exact("1.7.3")),
        .remote(url: "https://github.com/pointfreeco/swift-identified-collections.git", requirement: .exact("1.1.1")),
        .remote(url: "https://github.com/apple/swift-openapi-runtime.git", requirement: .exact("1.6.0")),
        .remote(url: "https://github.com/apple/swift-openapi-urlsession.git", requirement: .exact("1.0.2")),
        .remote(url: "https://github.com/realm/realm-swift.git", requirement: .exact("10.54.6")),
        .remote(url: "https://github.com/onevcat/Kingfisher.git", requirement: .exact("8.1.3")),
        .remote(url: "https://github.com/JiongXing/PhotoBrowser", requirement: .upToNextMajor(from: "4.0.3")),
        // Sign In with Google + transitive (AppAuth / GTM*) — packageSettings 에서 framework 화.
        .remote(url: "https://github.com/google/GoogleSignIn-iOS.git", requirement: .exact("8.0.0")),
        .remote(url: "https://github.com/openid/AppAuth-iOS.git", requirement: .upToNextMajor(from: "1.7.5")),
        .remote(url: "https://github.com/google/GTMAppAuth.git", requirement: .upToNextMajor(from: "4.1.1")),
        .remote(url: "https://github.com/google/gtm-session-fetcher.git", requirement: .upToNextMajor(from: "3.4.0")),
    ],
    settings: .settings(base: baseSettings),
    targets: [
        // MARK: Cores
        module(
            "CoreDomain",
            layer: .core,
            dependencies: []
        ),
        module(
            "CorePersistence",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreNetworking"),
                // MochiItemSyncWorker 가 foreground 분석 완료를 SSE 로 받는다(`@Dependency(\.agentStreamClient)`).
                // CoreAgentClient → CoreNetworking/CoreDomain 만 의존하므로 사이클 없음.
                .target(name: "CoreAgentClient"),
                .package(product: "RealmSwift"),
                .package(product: "Dependencies"),
            ]
        ),
        module(
            "CoreNetworking",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                .package(product: "OpenAPIRuntime"),
                .package(product: "OpenAPIURLSession"),
                .package(product: "Dependencies"),
            ]
        ),
        module(
            "CoreAgentClient",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreNetworking"),
                .package(product: "Dependencies"),
            ]
        ),
        module(
            "CoreIntegrations",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                .package(product: "Dependencies"),
                .sdk(name: "EventKit", type: .framework),
                .sdk(name: "EventKitUI", type: .framework),
            ]
        ),
        module(
            "DesignSystem",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                // LocalThumbnail 이 App Group 컨테이너(`AppGroup.containerURL`)에서 캡처 이미지를
                // 다운샘플 로드한다. AppGroup 은 CorePersistence 소유. acyclic(Cores 어디에도
                // import DesignSystem 없음) 확인됨 — FeatureInbox→DesignSystem 승격 시 추가.
                .target(name: "CorePersistence"),
                .package(product: "Kingfisher"),
            ]
        ),
        module(
            "CoreLiveActivity",
            layer: .core,
            dependencies: []
        ),

        module(
            "CoreAuth",
            layer: .core,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreNetworking"),
                .package(product: "Dependencies"),
                // GoogleSignIn 은 **최상위 App 타겟에서만** link 한다.
                // 이유: GoogleSignIn-iOS Package.swift 가 AppAuthCore (ObjC: OIDAuthState 등)
                // 를 product 의존성에 명시하지 않아 하위 framework 에서 link 하면 undefined symbol
                // 발생 (google/GoogleSignIn-iOS#408, tuist/tuist#6360).
                // CoreAuth 는 GoogleAuthClient protocol 만 제공하고, Live 구현
                // (Targets/App/Sources/LiveGoogleAuthClient.swift) 가 App 타겟 안에서 GoogleSignIn import.
                .sdk(name: "AuthenticationServices", type: .framework),
                .sdk(name: "Security", type: .framework),
            ]
        ),

        // MARK: Features
        // TCA 는 static product 이고 @_exported import 로 Dependencies / CasePaths /
        // IdentifiedCollections 의 타입을 노출한다. 이 타입을 직접 쓰는 dynamic
        // framework (Feature*) 는 해당 패키지들을 명시적으로 link 해야
        // "Undefined symbol: Dependencies.Dependency / CasePathsCore.* / IdentifiedCollections.*"
        // linker error 가 발생하지 않는다 (App 타겟과 동일한 이유).
        module(
            "FeatureMochiItem",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CorePersistence"),
                .target(name: "CoreNetworking"),
                .target(name: "CoreAgentClient"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureInbox",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CorePersistence"),
                .target(name: "CoreNetworking"),
                .target(name: "CoreIntegrations"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureSearch",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreAgentClient"),
                .target(name: "CorePersistence"),
                .target(name: "CoreNetworking"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureChat",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreAgentClient"),
                .target(name: "CoreNetworking"),
                .target(name: "CorePersistence"),
                .target(name: "CoreIntegrations"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureDetail",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CorePersistence"),
                .target(name: "CoreNetworking"),
                .target(name: "CoreIntegrations"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "JXPhotoBrowser"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureSettings",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CorePersistence"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureAuth",
            layer: .feature,
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CoreAuth"),
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        module(
            "FeatureOnboarding",
            layer: .feature,
            dependencies: [
                .target(name: "DesignSystem"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ],
            resources: ["Targets/Features/FeatureOnboarding/Resources/**"]
        ),

        // MARK: App Shell
        .target(
            name: "Mochi",
            // iPhone 전용 (TARGETED_DEVICE_FAMILY=1). iPad 를 포함하면 App Store 가
            // multitasking 용 4방향 orientation 을 강제하는데, 본 앱은 portrait 전용 디자인이라
            // iPad 를 빼서 Portrait 단독으로 통과시킨다. 내장 확장도 동일 family 로 맞춘다.
            destinations: [.iPhone],
            product: .app,
            bundleId: bundleIdPrefix,
            deploymentTargets: .iOS(deploymentTarget),
            infoPlist: .file(path: "Targets/App/Support/Info.plist"),
            sources: ["Targets/App/Sources/**"],
            resources: ["Targets/App/Resources/**"],
            entitlements: .file(path: "Targets/App/Support/App.entitlements"),
            // realm-swift 는 자체 Xcode project 를 가진 mixed Swift/ObjC 패키지라
            // Tuist 의 dynamic PackageProduct embed 자동화(<Name>_<hash>_PackageProduct.framework
            // 규칙)에서 빠진다. 결과적으로 link 는 되지만 .app/Frameworks/ 에 RealmSwift.framework
            // 가 embed 되지 않아 실기기에서 dyld 가 @rpath/RealmSwift.framework/RealmSwift 를
            // 찾지 못하고 즉시 크래시한다. PackageFrameworks 산출물을 강제로 복사·서명한다.
            // ShareExtension 은 부모 .app 의 Frameworks/ 를 공유하므로 본 App 타겟에서만 embed 하면 된다.
            scripts: [
                .post(
                    script: #"""
                    set -e
                    DST_DIR="${BUILT_PRODUCTS_DIR}/${FRAMEWORKS_FOLDER_PATH}"
                    DST="${DST_DIR}/RealmSwift.framework"
                    # Xcode SPM 은 빌드 종류에 따라 dynamic framework 산출 위치가 다르다.
                    # 일반 빌드(build/run): BUILT_PRODUCTS_DIR/PackageFrameworks/ 하위.
                    # archive 빌드: PackageFrameworks/ 는 비고, BUILT_PRODUCTS_DIR 루트 직하.
                    # 두 경로를 모두 확인해야 archive 시 "framework not found" 로 죽지 않는다.
                    SRC="${BUILT_PRODUCTS_DIR}/PackageFrameworks/RealmSwift.framework"
                    if [ ! -d "$SRC" ]; then
                        SRC="${BUILT_PRODUCTS_DIR}/RealmSwift.framework"
                    fi
                    if [ ! -d "$SRC" ]; then
                        echo "error: RealmSwift.framework not found in PackageFrameworks/ nor BUILT_PRODUCTS_DIR root" >&2
                        exit 1
                    fi
                    mkdir -p "$DST_DIR"
                    /usr/bin/rsync -a --delete "$SRC/" "$DST/"
                    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
                        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
                            --preserve-metadata=identifier,entitlements --timestamp=none "$DST"
                    fi
                    """#,
                    name: "Embed RealmSwift.framework",
                    inputPaths: ["$(BUILT_PRODUCTS_DIR)/PackageFrameworks/RealmSwift.framework/RealmSwift"],
                    outputPaths: ["$(BUILT_PRODUCTS_DIR)/$(FRAMEWORKS_FOLDER_PATH)/RealmSwift.framework/RealmSwift"],
                    basedOnDependencyAnalysis: true
                ),
                // Debug 빌드에서 호스트 Mac 의 현재 LAN IP 를 .app/Info.plist 의 ``MOCHI_DEV_HOST``
                // 키에 박는다 (AppDependencies.resolveBaseURL 이 우선 참조). 실기기에서 같은 Wi-Fi
                // 의 macOS 백엔드(localhost:8000)를 가리키도록 빌드만 다시 누르면 자동 갱신된다.
                //
                // Release 에선 noop — MOCHI_DEV_HOST 가 빈 문자열로 남아 운영 URL fallback 이 쓰인다.
                // Info.plist 수정 후 codesign 을 다시 적용하지 않으면 실기기에서 launch 가 거부된다.
                //
                // basedOnDependencyAnalysis=false: 입력 파일이 호스트 네트워크 상태이므로 Xcode 가
                // up-to-date 로 판단해 스킵하지 않게 매 빌드 강제 실행.
                .post(
                    script: #"""
                    set -e
                    if [ "${CONFIGURATION}" != "Debug" ]; then
                        exit 0
                    fi
                    LAN_HOST=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || true)
                    if [ -z "$LAN_HOST" ]; then
                        LAN_HOST=$(/usr/sbin/ipconfig getifaddr en1 2>/dev/null || true)
                    fi
                    if [ -z "$LAN_HOST" ]; then
                        echo "warning: Mac LAN IP not detectable (en0/en1). MOCHI_DEV_HOST left empty — app will fall back to localhost." >&2
                        exit 0
                    fi
                    PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
                    if [ ! -f "$PLIST" ]; then
                        echo "error: Info.plist not found at $PLIST" >&2
                        exit 1
                    fi
                    /usr/libexec/PlistBuddy -c "Set :MOCHI_DEV_HOST $LAN_HOST" "$PLIST" 2>/dev/null \
                        || /usr/libexec/PlistBuddy -c "Add :MOCHI_DEV_HOST string $LAN_HOST" "$PLIST"
                    echo "MOCHI_DEV_HOST → $LAN_HOST"
                    # Info.plist 가 codesign 의 일부이므로 수정 후 .app 전체를 다시 서명.
                    if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
                        /usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
                            --preserve-metadata=identifier,entitlements --timestamp=none \
                            "${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}"
                    fi
                    """#,
                    name: "Inject Dev LAN Host",
                    basedOnDependencyAnalysis: false
                ),
            ],
            dependencies: [
                .target(name: "FeatureAuth"),
                .target(name: "FeatureOnboarding"),
                .target(name: "FeatureMochiItem"),
                .target(name: "FeatureInbox"),
                .target(name: "FeatureSearch"),
                .target(name: "FeatureChat"),
                .target(name: "FeatureDetail"),
                .target(name: "FeatureSettings"),
                .target(name: "CoreDomain"),
                .target(name: "CoreAuth"),
                .target(name: "CorePersistence"),
                .target(name: "CoreNetworking"),
                // AppDependencies 가 `LiveAgentStreamClient`(SSE) 를 직접 생성·주입한다 →
                // import CoreAgentClient 는 직접 의존을 요구(전이 의존만으론 모듈 미해결).
                .target(name: "CoreAgentClient"),
                .target(name: "CoreIntegrations"),
                .target(name: "DesignSystem"),
                .target(name: "CoreLiveActivity"),
                .target(name: "ShareExtension"),
                .target(name: "MochiWidgets"),
                .package(product: "ComposableArchitecture"),
                // RealmStoreFactory.makeConfiguration() 의 반환 타입(Realm.Configuration) 의
                // metadata 가 MochiApp 에서 참조되므로 App 타겟에서 직접 link.
                .package(product: "RealmSwift"),
                .package(product: "GoogleSignIn"),
                .package(product: "AppAuth"),
                .package(product: "AppAuthCore"),
                .package(product: "GTMAppAuth"),
                .package(product: "GTMSessionFetcherCore"),
                // TCA 는 static product 라 transitive deps 가 자동 링크되지 않는다.
                // App 타겟 최종 링킹 시 undefined symbol 을 막기 위해 명시.
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Dependencies"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ],
            settings: .settings(
                base: baseSettings.merging([
                    "PRODUCT_NAME": "Mochi",
                    // GoogleSignIn 의 ObjC 카테고리/클래스(OIDAuthState 등)가 link 단계에서
                    // dead-strip 되지 않도록 -ObjC 강제. AppAuthCore 가 static product 일 때 필수.
                    "OTHER_LDFLAGS": .array(["$(inherited)", "-ObjC"]),
                    // "Embed RealmSwift.framework" post-build script 가 BUILT_PRODUCTS_DIR
                    // (DerivedData) 에 접근하려면 user script sandbox 를 꺼야 한다. baseSettings
                    // 는 보안 목적으로 YES 를 유지하고 App 타겟에서만 override.
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                ])
            )
        ),

        // MARK: Share Extension
        .target(
            name: "ShareExtension",
            destinations: [.iPhone],
            product: .appExtension,
            bundleId: "\(bundleIdPrefix).ShareExtension",
            deploymentTargets: .iOS(deploymentTarget),
            infoPlist: .file(path: "Targets/ShareExtension/Support/Info.plist"),
            sources: ["Targets/ShareExtension/Sources/**"],
            resources: ["Targets/ShareExtension/Resources/**"],
            entitlements: .file(path: "Targets/ShareExtension/Support/ShareExtension.entitlements"),
            dependencies: [
                .target(name: "CoreDomain"),
                .target(name: "CorePersistence"),
                // ShareExt 직접 전송(best-effort): CoreNetworking(OpenAPIMochiClient),
                // CoreAuth(KeychainTokenStore — GoogleSignIn 은 App 타겟 전용이라 안전). 실패 시 큐 폴백.
                .target(name: "CoreNetworking"),
                .target(name: "CoreAuth"),
                .target(name: "DesignSystem"),
            ],
            settings: .settings(base: baseSettings.merging([
                // Xcode 16 의 Debug Dylib 분리(`ENABLE_DEBUG_DYLIB`, Debug 기본 YES)는 타겟 코드를
                // `ShareExtension.debug.dylib` 로 떼어내고 실행파일은 그걸 로드하는 stub 만 남긴다.
                // 메인 앱은 정상 launch 경로라 무관하지만, **app extension** 은 시스템이
                // `runextension`/`WFExtensionEnumerator` 로 NSExtension 을 인스턴스화할 때 stub 에서
                // principal class(`ShareExtensionPrincipal`)를 못 찾아
                // "Failed to create NSExtension ... (null)" 로 로드에 실패한다 — 백탭 단축어가
                // ShareExtension 을 띄우지 못하고 무한 대기하던 근본 원인. NO 로 코드를 실행파일에
                // 통합해 모든 로드 경로(공유시트·단축어)에서 principal class 발견을 보장한다.
                "ENABLE_DEBUG_DYLIB": "NO",
            ]))
        ),

        // MARK: Widget Extension (Live Activity)
        // Lock Screen + Dynamic Island. ActivityKit + WidgetKit + App Intents (iOS 17+) 로
        // interactive button. ActivityAttributes 의 type identity 는 CoreLiveActivity 공유.
        .target(
            name: "MochiWidgets",
            destinations: [.iPhone],
            product: .appExtension,
            bundleId: "\(bundleIdPrefix).MochiWidgets",
            deploymentTargets: .iOS(deploymentTarget),
            infoPlist: .file(path: "Targets/Widgets/Support/Info.plist"),
            sources: ["Targets/Widgets/Sources/**"],
            resources: ["Targets/Widgets/Resources/**"],
            entitlements: .file(path: "Targets/Widgets/Support/Widgets.entitlements"),
            dependencies: [
                .target(name: "CoreLiveActivity"),
                // LA 후보 버튼(SelectCandidateIntent)이 위젯 프로세스에서 reanalyze 를 직접 호출한다 —
                // ShareExtension 직접전송과 동일 패턴(App Group baseURL + Keychain 토큰 + OpenAPIMochiClient).
                .target(name: "CoreNetworking"),
                .target(name: "CoreAuth"),
                .target(name: "CorePersistence"),
            ],
            settings: .settings(base: baseSettings)
        ),

        // App Intents (QuickCaptureIntent / CaptureScreenshotIntent / MochiShortcuts) 는
        // 별도 extension 타겟이 아니라 **메인 App 타겟 안** 에 있다 (`Targets/App/Sources/AppIntents/`).
        // 이유: `AppShortcutsProvider` 와 그것이 참조하는 `AppIntent` 들은 반드시 메인 앱 타겟에
        // 위치해야 시스템이 인덱싱한다 (Apple Developer Forums thread/759160).
        // extension 타겟에 두면 단축어 앱·"앱과 공유"·Siri·Spotlight 어디에서도 발견되지 않음.

        // MARK: Tests
        unitTests(for: "CoreDomain", layer: .core),
        // CoreNetworking: MochiItemSyncWorker 테스트가 MochiAPIClient 스텁·DTO 를 직접 구성한다.
        unitTests(for: "CorePersistence", layer: .core, dependencies: [.target(name: "CoreDomain"), .target(name: "CoreNetworking")]),
        unitTests(for: "CoreAgentClient", layer: .core, dependencies: [.target(name: "CoreDomain")]),
        unitTests(
            for: "FeatureMochiItem",
            layer: .feature,
            dependencies: [
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        unitTests(
            for: "FeatureInbox",
            layer: .feature,
            dependencies: [
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        unitTests(
            for: "FeatureSearch",
            layer: .feature,
            dependencies: [
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
        unitTests(
            for: "FeatureChat",
            layer: .feature,
            dependencies: [
                .target(name: "CoreAgentClient"),
                .target(name: "CoreIntegrations"),
                .package(product: "Clocks"),
                .package(product: "ComposableArchitecture"),
                .package(product: "Dependencies"),
                .package(product: "CasePaths"),
                .package(product: "IdentifiedCollections"),
                .package(product: "Perception"),
                .package(product: "PerceptionCore"),
                .package(product: "SwiftNavigation"),
            ]
        ),
    ],
    schemes: [
        .scheme(
            name: "Mochi",
            shared: true,
            buildAction: .buildAction(targets: ["Mochi"]),
            testAction: .targets([
                "CoreDomainTests",
                "CorePersistenceTests",
                "CoreAgentClientTests",
                "FeatureMochiItemTests",
                "FeatureInboxTests",
                "FeatureSearchTests",
                "FeatureChatTests",
            ]),
            runAction: .runAction(executable: "Mochi")
        ),
    ],
    additionalFiles: [
        "README.md",
        ".swiftlint.yml",
        "Targets/App/Support/Info.plist",
        "Targets/App/Support/App.entitlements",
    ]
)

// MARK: - App Group constant export (for documentation only — not consumed by Tuist)

// AppGroup identifier used across App, ShareExtension, and CorePersistence:
// "\(appGroup)" → must match the entitlements files in Targets/*/Support/*.entitlements.
_ = appGroup
