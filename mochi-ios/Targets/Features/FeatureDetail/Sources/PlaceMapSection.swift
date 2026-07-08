import SwiftUI
import MapKit
import CoreDomain
import DesignSystem

/// 장소 섹션 — Agent 가 지오코딩한 장소(`entities kind=place`)를 지도 위에 되살린다.
///
/// "저장한 가게를 다시 찾아가는 길"이 이 섹션의 존재 이유라, 지도는 조작 대상이 아니라 **프리뷰**다
/// (스크롤 제스처 충돌도 없앤다): 지도를 탭하면 네이버 지도에서 그 장소를 열고, 길찾기 버튼은
/// 네이버 지도 앱의 대중교통 길찾기로 바로 딥링크한다(미설치면 웹 지도로 폴백).
/// 카드 문법은 회수 헤더와 동일 — 미디어(지도)가 카드 상단을 edge-to-edge 로 채우고 본문이 받친다.
struct PlaceMapSection: View {
    let place: Place
    @Environment(\.openURL) private var openURL

    private var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeDesign.Spacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(HomeDesign.Color.purple500)
                Text("장소")
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, HomeDesign.Spacing.xs)

            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            mapPreview
            infoRow
        }
        .background(HomeDesign.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: HomeDesign.Radius.lg, style: .continuous))
        .cardShadow()
    }

    // MARK: - 지도 프리뷰 (탭 → 네이버 지도)

    private var mapPreview: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            Annotation(place.name, coordinate: coordinate) {
                pin
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))  // 주변 POI 를 지워 핀이 주인공
        .frame(height: 168)
        .overlay(alignment: .bottomTrailing) {
            naverChip
                .padding(HomeDesign.Spacing.sm)
                .allowsHitTesting(false)  // 칩은 어포던스 표시 — 탭은 지도 전체가 받는다
        }
        .contentShape(Rectangle())
        .onTapGesture { openNaverMap() }
        // onTapGesture 는 VoiceOver 가 버튼으로 못 읽으므로 트레잇·라벨을 직접 부여한다(회수 헤더 이미지와 동일).
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("네이버 지도에서 \(place.name) 보기")
    }

    /// 400m 남짓 반경 — 골목 이름까지 읽히는 배율로 "어디쯤인지"가 한눈에 잡힌다.
    private var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004)
        )
    }

    /// 모찌 정체성 핀 — 브랜드 퍼플 원 + 흰 링. 지도 타일 위라 layered shadow 로 띄운다.
    private var pin: some View {
        ZStack {
            Circle().fill(HomeDesign.Color.purple600)
            Image(systemName: "mappin")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 32, height: 32)
        .overlay(Circle().stroke(.white, lineWidth: 2.5))
        .shadow(color: HomeDesign.Color.ink900.opacity(0.18), radius: 4, x: 0, y: 2)
        .shadow(color: HomeDesign.Color.ink900.opacity(0.10), radius: 10, x: 0, y: 5)
    }

    /// "탭하면 네이버 지도" 어포던스 칩 — 지도 위라 Material 로 얹는다(사진 위 '캡처' 배지 컨벤션).
    private var naverChip: some View {
        HStack(spacing: 4) {
            Text("네이버 지도")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8.5, weight: .heavy))
        }
        .foregroundStyle(HomeDesign.Color.textPrimary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.06), lineWidth: 1))
    }

    // MARK: - 장소 정보 + 길찾기

    private var infoRow: some View {
        HStack(alignment: .center, spacing: HomeDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(HomeDesign.Color.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(HomeDesign.Color.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            directionsButton
        }
        .padding(HomeDesign.Spacing.md)
    }

    /// "업종 · 주소" 한 줄 — 관련 링크 카드의 local subtitle("업종 · 지역")과 같은 독법.
    private var subtitle: String? {
        let parts = [place.categoryLeaf, place.displayAddress].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 길찾기 CTA — 네이버 브랜드는 민트(ReferenceBrandStyle 의 naver_map 매핑과 동일 어휘).
    private var directionsButton: some View {
        Button(action: openDirections) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.system(size: 12, weight: .bold))
                Text("길찾기")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(Capsule().fill(HomeDesign.Color.mint400))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel("\(place.name)까지 네이버 지도 길찾기")
    }

    // MARK: - 네이버 지도 연결

    /// 지도 탭 — 네이버 지도에서 장소 열기. 서버가 준 검색 URL 우선, 없으면 이름으로 검색.
    private func openNaverMap() {
        openURL(webMapURL)
    }

    /// 길찾기 — 네이버 지도 앱 딥링크(대중교통). 미설치·실패 시 웹 지도로 폴백한다.
    /// `openURL` 완료 핸들러가 폴백을 판정하므로 `LSApplicationQueriesSchemes` 등록이 필요 없다.
    private func openDirections() {
        guard let appURL = directionsAppURL else {
            openURL(webMapURL)
            return
        }
        openURL(appURL) { accepted in
            if !accepted { openURL(webMapURL) }
        }
    }

    private var directionsAppURL: URL? {
        var components = URLComponents()
        components.scheme = "nmap"
        components.host = "route"
        components.path = "/public"
        components.queryItems = [
            URLQueryItem(name: "dlat", value: String(place.lat)),
            URLQueryItem(name: "dlng", value: String(place.lng)),
            URLQueryItem(name: "dname", value: place.name),
            URLQueryItem(name: "appname", value: Bundle.main.bundleIdentifier ?? "app.mochi"),
        ]
        return components.url
    }

    private var webMapURL: URL {
        if let mapURL = place.mapURL { return mapURL }
        // path segment 전용 인코딩 — urlPathAllowed 에서 '/' 를 빼 상호 속 '/' 가 경로를 가르지 않게.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let query = place.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        // 이름조차 인코딩 불가한 극단 폴백 — 네이버 지도 홈.
        return URL(string: "https://map.naver.com/p/search/\(query)") ?? URL(string: "https://map.naver.com")!
    }
}

#Preview {
    ScrollView {
        PlaceMapSection(
            place: Place(
                name: "몽탄",
                lat: 37.5360103,
                lng: 126.97225,
                category: "한식>육류,고기요리",
                address: "서울특별시 용산구 한강로1가 251-1",
                roadAddress: "서울특별시 용산구 백범로99길 50",
                mapURL: URL(string: "https://map.naver.com/p/search/%EB%AA%BD%ED%83%84")
            )
        )
        .padding(HomeDesign.Spacing.lg)
    }
    .background(HomeDesign.Color.bg)
}
