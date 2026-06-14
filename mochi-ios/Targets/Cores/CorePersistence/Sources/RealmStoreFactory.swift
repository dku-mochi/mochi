import Foundation
import RealmSwift

/// Main app (AppIntents 포함) 과 ShareExtension 이 동일한 Realm 파일을 안전하게 공유하기 위한 팩토리.
///
/// - App Group 컨테이너에 파일을 두고
/// - schemaVersion·migrationBlock을 중앙에서 한 곳에 정의해 모든 프로세스가 동일 스키마 가정으로 열도록 한다.
public enum RealmStoreFactory {
    public static let currentSchemaVersion: UInt64 = 11

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
}
