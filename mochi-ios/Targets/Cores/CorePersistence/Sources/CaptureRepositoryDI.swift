import Dependencies
import CoreDomain

public enum CaptureRepositoryKey: DependencyKey {
    public static let liveValue: any CaptureRepository = InMemoryCaptureRepository()
    public static let testValue: any CaptureRepository = InMemoryCaptureRepository()
}

public extension DependencyValues {
    var captureRepository: any CaptureRepository {
        get { self[CaptureRepositoryKey.self] }
        set { self[CaptureRepositoryKey.self] = newValue }
    }
}
