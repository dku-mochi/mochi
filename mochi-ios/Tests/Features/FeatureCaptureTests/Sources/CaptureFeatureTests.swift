import XCTest
import ComposableArchitecture
import CoreDomain
@testable import FeatureCapture

@MainActor
final class CaptureFeatureTests: XCTestCase {
    func test_event_finalAnalysis_updates_state() async {
        let source = CaptureSource(channel: .appDirectInput, text: "x")
        let analysis = CaptureAnalysis(
            summary: "ok", intent: .memo, entities: [], actionCandidates: [],
            tags: [], importance: .medium, confidence: 0.85,
            modelVersion: "test", analyzedAt: .init()
        )

        let store = TestStore(initialState: CaptureFeature.State(source: source)) {
            CaptureFeature()
        }

        await store.send(.event(.finalAnalysis(analysis))) {
            $0.finalAnalysis = analysis
        }
    }
}
