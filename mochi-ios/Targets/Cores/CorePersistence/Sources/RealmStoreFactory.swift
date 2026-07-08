import Foundation
import RealmSwift

/// Main app (AppIntents 포함) 과 ShareExtension 이 동일한 Realm 파일을 안전하게 공유하기 위한 팩토리.
///
/// - App Group 컨테이너에 파일을 두고
/// - schemaVersion·migrationBlock을 중앙에서 한 곳에 정의해 모든 프로세스가 동일 스키마 가정으로 열도록 한다.
public enum RealmStoreFactory {
    public static let currentSchemaVersion: UInt64 = 16

    public static func makeConfiguration() -> Realm.Configuration {
        let config = Realm.Configuration(
            fileURL: AppGroup.realmFileURL,
            schemaVersion: currentSchemaVersion,
            // v4 → v5 (2026-06-04 intent 빅뱅): intentRawValue/confidence/intentCandidates 제거 →
            // intentInstances(RealmIntentInstance) + needsReview + reviewOptions. lifecycle 2분할.
            // v5 → v6: RealmMochiItem.userTitle 추가 (기록상세 제목 인라인 교정 로컬 오버라이드).
            // v6 → v7: RealmMochiItem.category 추가 (홈 이번주 리플레이 카테고리).
            // v7 → v8: RealmIntentInstance.payloadEndDate/payloadEndTime 추가 (기간형 일정).
            // v8 → v9: RealmMochiItem.shoppingProductQuery 추가 (상세 구매 링크 — 쇼핑 검색어).
            // v9 → v10: RealmMochiItem.referenceLinks(RealmReferenceLink) 추가 (상세 URL 카드 — Agent 참고 링크).
            // v10 → v11: RealmMochiItem.isFavorite 추가 (즐겨찾기 신호 — 서버 동기화).
            // v11 → v12: RealmReferenceLink.subtitle/priceText 추가 (URL 카드 메타 — 누르기 전 식별 단서).
            // v12 → v13: RealmMochiItem.privacyPolicyRawValue/sensitivityLevelRawValue + RealmImageRef.redactedRelativePath
            //            추가 (민감 캡처 저장 정책 + 블러본 경로).
            // v13 → v14: RealmMochiItem.analysisOcrText 추가 (분석 전용 ephemeral OCR — drain~업로드 사이 보관,
            //            업로드 워커가 정책 따라 동봉. 검색·노출 미사용 isolated 컬럼).
            // v14 → v15: RealmMochiItem.place(RealmPlace) 추가 (상세 지도 섹션 — Agent 지오코딩 장소).
            // v15 → v16: RealmPlace.rating/ratingCount/imageURLString 추가 (장소 카드 별점·매장사진 — Google Places 보강).
            // prod 아님 — 실데이터 폐기 허용이라 점진 migration 대신 파일을 재생성한다.
            deleteRealmIfMigrationNeeded: true,
            objectTypes: [
                RealmMochiItem.self,
                RealmImageRef.self,
                RealmExtractedEntity.self,
                RealmActionCandidate.self,
                RealmIntentInstance.self,
                RealmReviewOption.self,
                RealmReferenceLink.self,
                RealmPlace.self,
            ]
        )
        // 모든 프로세스가 동일 fileURL/schemaVersion을 보도록 default로 박는다.
        Realm.Configuration.defaultConfiguration = config
        return config
    }

    public static func openRealm() throws -> Realm {
        _ = makeConfiguration()
        return try Realm()
    }

    /// 전용 직렬 큐에 갇힌 Realm — 알림 토큰을 메인 run loop 밖에서 굴리기 위한 경로.
    /// 종료(close) 시 InterprocessMutex 를 user-interactive 인 메인 스레드가 아니라 이 큐에서 잡게 해
    /// priority inversion 을 피한다 (근거는 ``RealmChangeObserver``).
    public static func openRealm(queue: DispatchQueue) throws -> Realm {
        _ = makeConfiguration()
        return try Realm(queue: queue)
    }
}
