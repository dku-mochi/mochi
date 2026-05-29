import XCTest
import ComposableArchitecture
import CoreDomain
import CorePersistence
@testable import FeatureInbox

@MainActor
final class InboxFeatureTests: XCTestCase {
    func test_onAppear_loads_captures_from_repository() async {
        let repo = InMemoryMochiItemRepository()
        let mochiItem = MochiItem(source: IngestSource(channel: .appDirectInput, text: "hello"))
        try? await repo.upsert(mochiItem)
        let stored = try? await repo.find(id: mochiItem.id)

        let store = TestStore(initialState: InboxFeature.State()) {
            InboxFeature()
        } withDependencies: {
            $0.mochiItemRepository = repo
        }

        await store.send(.onAppear) { $0.isLoading = true }
        await store.receive(\.mochiItemsLoaded) {
            $0.isLoading = false
            $0.mochiItems = stored.map { [$0] } ?? []
        }
    }
}
