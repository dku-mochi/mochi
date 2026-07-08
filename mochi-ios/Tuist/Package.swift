// swift-tools-version: 5.10
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
    productTypes: [
        // ComposableArchitecture는 모듈마다 import하므로 dynamic framework가 빌드 시간 유리
        "ComposableArchitecture": .framework,
        "Dependencies": .framework,
        "Perception": .framework,
        "PerceptionCore": .framework,
        "SwiftNavigation": .framework,
        // Realm dynamic framework — Swift/ObjC 브릿지 오류 방지
        "Realm": .framework,
        "RealmSwift": .framework,
        // GoogleSignIn 관련 패키지는 모두 static 유지 (.staticFramework 도 X) —
        // framework 변환 시 GoogleSignIn-iOS Package.swift 가 AppAuthCore 를 product 의존성에
        // 명시하지 않아 transitive ObjC 심볼(OIDAuthState 등) 이 누락된다 (tuist#6360).
        // static 으로 두면 GoogleSignIn .o 가 최종 App 바이너리 link 단계에 합쳐지고,
        // 같은 link 명령에서 명시 link 한 AppAuthCore archive 에서 OBJC 심볼이 해소된다.
    ]
)
#endif

let package = Package(
    name: "MochiPackages",
    dependencies: [
        // TCA — The Composable Architecture (1.x mature, swift-dependencies 통합)
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture.git", exact: "1.17.1"),

        // swift-dependencies — Core 모듈이 TCA 전체를 import하지 않고도 DI를 정의할 수 있게 한다
        .package(url: "https://github.com/pointfreeco/swift-dependencies.git", exact: "1.5.1"),
        .package(url: "https://github.com/pointfreeco/swift-perception.git", exact: "1.6.0"),
        .package(url: "https://github.com/pointfreeco/swift-navigation.git", exact: "2.8.0"),

        // OpenAPI generator 런타임 (백엔드 /api/v1 OpenAPI 스펙 기반 Swift 클라이언트 생성용)
        .package(url: "https://github.com/apple/swift-openapi-runtime.git", exact: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession.git", exact: "1.0.2"),

        // 로컬 저장 — Realm (대량 캡처/임베딩 메타데이터에 안정적, App Group 공유 가능)
        .package(url: "https://github.com/realm/realm-swift.git", exact: "10.54.6"),

        // 이미지 캐싱 (캡처 썸네일/원본 미리보기)
        .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "8.1.3"),

        // 네이버 지도 SDK (공식 SPM 미러, binary xcframework) — 기록상세 장소 지도 프리뷰
        .package(url: "https://github.com/navermaps/SPM-NMapsMap.git", exact: "3.23.3"),

        // 사진 뷰어 — 기록상세 스크린샷 확대(zoom transition / pinch / drag dismiss)
        .package(url: "https://github.com/JiongXing/PhotoBrowser", from: "4.0.3"),

        // Sign In with Google — Apple AuthenticationServices 와 함께 본 앱의 두 진입점.
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", exact: "8.0.0"),

        // GoogleSignIn 의 transitive — Tuist 에서 product 로 link 하려면 1st-party 로 명시해야 한다.
        .package(url: "https://github.com/openid/AppAuth-iOS.git", from: "1.7.5"),
        .package(url: "https://github.com/google/GTMAppAuth.git", from: "4.1.1"),
        .package(url: "https://github.com/google/gtm-session-fetcher.git", from: "3.4.0"),
    ]
)
