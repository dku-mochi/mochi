import NMapsGeometry
import NMapsMap
import SwiftUI

/// 네이버 지도 프리뷰 — 조작 대상이 아닌 카드 미디어.
///
/// 카메라를 좌표에 고정하고 뷰 전체 터치를 끈다(`isUserInteractionEnabled = false`) —
/// 탭 제스처·핀은 SwiftUI 레이어(PlaceMapSection)가 담당하고, 지도는 순수 배경 타일이다.
/// 카메라 target 이 곧 뷰 중심이므로 핀은 ZStack center 오버레이만으로 좌표에 정확히 앉는다.
/// 인증 키는 App Info.plist `NMFNcpKeyId` 를 SDK 가 자동 로드한다(키 부재 시 이 뷰를 만들지
/// 않고 MapKit 폴백 — PlaceMapSection.hasNaverMapKey).
struct NaverMapPreview: UIViewRepresentable {
    let lat: Double
    let lng: Double

    /// 골목 이름까지 읽히는 배율 — 기존 MapKit 프리뷰(span Δ0.004)와 같은 체감 스케일.
    private static let zoom: Double = 15.5

    func makeUIView(context: Context) -> NMFMapView {
        let map = NMFMapView()
        // 프리뷰 계약: 지도는 만지는 것이 아니라 보는 것. 제스처 플래그 다섯 개를 개별로 끄는
        // 대신 UIKit 터치를 통째로 차단해 SwiftUI onTapGesture 가 카드 탭을 온전히 받는다.
        // 네이버 로고는 고지 의무라 그대로 노출된다(클릭만 비활성 — SDK 가이드 허용 범위).
        map.isUserInteractionEnabled = false
        map.moveCamera(cameraUpdate)
        return map
    }

    func updateUIView(_ map: NMFMapView, context: Context) {
        map.moveCamera(cameraUpdate)
    }

    private var cameraUpdate: NMFCameraUpdate {
        NMFCameraUpdate(position: NMFCameraPosition(NMGLatLng(lat: lat, lng: lng), zoom: Self.zoom))
    }
}
