import XCTest
import ComposableArchitecture
import CoreDomain
@testable import FeatureMochiItem

@MainActor
final class MochiItemFeatureTests: XCTestCase {
    func test_event_finalAnalysis_updates_state() async {
        let source = IngestSource(channel: .appDirectInput, text: "x")
        let analysis = MochiItemAnalysis(
            summary: "ok", intent: .memo, entities: [], actionCandidates: [],
            tags: [], importance: .medium, confidence: 0.85,
            modelVersion: "test", analyzedAt: .init()
        )

        let store = TestStore(initialState: MochiItemFeature.State(source: source)) {
            MochiItemFeature()
        }

        await store.send(.event(.finalAnalysis(analysis))) {
            $0.finalAnalysis = analysis
        }
    }
}
