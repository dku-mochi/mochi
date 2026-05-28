import XCTest
import ComposableArchitecture
import CoreDomain
import CorePersistence
@testable import FeatureInbox

@MainActor
final class InboxFeatureTests: XCTestCase {
    func test_onAppear_loads_captures_from_repository() async {
        let repo = InMemoryCaptureRepository()
        let capture = Capture(source: CaptureSource(channel: .appDirectInput, text: "hello"))
        try? await repo.upsert(capture)

        let store = TestStore(initialState: InboxFeature.State()) {
            InboxFeature()
        } withDependencies: {
            $0.captureRepository = repo
        }

        await store.send(.onAppear) { $0.isLoading = true }
        await store.receive(\.capturesLoaded) {
            $0.isLoading = false
            $0.captures = [capture]
        }
    }
}
