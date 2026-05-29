import Foundation
import RealmSwift

/// Main app (AppIntents 포함) 과 ShareExtension 이 동일한 Realm 파일을 안전하게 공유하기 위한 팩토리.
///
/// - App Group 컨테이너에 파일을 두고
/// - schemaVersion·migrationBlock을 중앙에서 한 곳에 정의해 모든 프로세스가 동일 스키마 가정으로 열도록 한다.
public enum RealmStoreFactory {
    public static let currentSchemaVersion: UInt64 = 3

    public static func makeConfiguration() -> Realm.Configuration {
        var config = Realm.Configuration(
            fileURL: AppGroup.realmFileURL,
            schemaVersion: currentSchemaVersion,
            migrationBlock: { _, oldVersion in
                // v1 → v2: RealmImageRef.sha256/objectKey 추가, RealmExtractedEntity.provenance* 추가.
                // v2 → v3: RealmMochiItem.intentCandidates/intentTopGap + RealmIntentCandidate 추가.
                // 누락 필드는 default 값으로 자동 채워지므로 별도 변환은 불필요.
                _ = oldVersion
            },
            objectTypes: [
                RealmMochiItem.self,
                RealmImageRef.self,
                RealmExtractedEntity.self,
                RealmActionCandidate.self,
                RealmIntentCandidate.self,
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
