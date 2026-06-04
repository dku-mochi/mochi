// swift-tools-version:5.9
// CodeGen — swift-openapi-generator 를 standalone 으로 돌리기 위한 사이드카 패키지.
// Tuist 가 빌드하는 앱과 무관(Targets/ 밖). `make openapi` → openapi.json 동기화 후
// `swift run swift-openapi-generator generate ...` 로 CoreNetworking/Sources/Generated 를 채운다.
// 생성 코드는 swift-openapi-runtime 1.6.0 / urlsession 1.0.2 (앱 의존성과 동일) 과 호환.
import PackageDescription

let package = Package(
    name: "CodeGen",
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", "1.7.0" ..< "2.0.0"),
    ]
)
