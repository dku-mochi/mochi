import Dependencies
import CoreDomain

public enum MochiItemRepositoryKey: DependencyKey {
    public static let liveValue: any MochiItemRepository = InMemoryMochiItemRepository()
    public static let testValue: any MochiItemRepository = InMemoryMochiItemRepository()
}

public extension DependencyValues {
    var mochiItemRepository: any MochiItemRepository {
        get { self[MochiItemRepositoryKey.self] }
        set { self[MochiItemRepositoryKey.self] = newValue }
    }
}
