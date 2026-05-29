import Foundation
import ComposableArchitecture
import CoreDomain
import CorePersistence
import CoreNetworking

/// 백탭 snippet 의 **메모** 분기에서 떠오르는 풀스크린 모달의 reducer.
///
/// **흐름 (2026-05-25 snippet pivot)**: 백탭의 캡쳐/메모 선택은 외부 앱 위의 snippet 카드가
/// 담당하고, 메모 분기만 모찌 앱을 깨운다 (textarea 입력에 키보드 필요). 캡쳐 분기는
/// ``CommitBackTapCaptureIntent`` 가 background 에서 처리하므로 모달은 더 이상 .selecting /
/// .capturing 을 다루지 않는다.
///
/// **외부 진입점**: ``OpenBackTapMemoIntent.perform()`` 가
/// `pending-backtap/<captureID>.memo` marker 파일을 떨구고 모찌 앱을 foreground 로 깨운다.
/// ``RootFeature`` 가 marker 발견 시 captureID 를 추출해 본 reducer 를 띄운다.
///
/// **두 분기**:
/// - `memoSaveTapped` — 사용자 입력 텍스트로 `MochiItem(channel: .appDirectInput, text:)` upsert +
///   `POST /api/v1/mochi_items` 시도. 실패해도 `.pendingUpload` 가 Realm 에 남아 ``MochiItemSyncWorker``
///   가 재시도.
/// - `dismissTapped` — 사용자 취소. memo marker 폐기 후 모달 닫기.
///
/// **invariant**: 모든 분기에서 `<captureID>.memo` marker 가 폐기됨. delegate `.dismiss` 발사 직전
/// 시점에 pending-backtap 디렉터리에는 본 모달의 marker 가 남아 있지 않아야 한다.
@Reducer
public struct BackTapModalFeature: Sendable {
    @ObservableState
    public struct State: Equatable, Sendable {
        /// `OpenBackTapMemoIntent` 가 생성한 ID. 그대로 ``MochiItem.id`` · 백엔드 capture id ·
        /// idempotency key 가 됨.
        public let captureID: UUID
        public var phase: Phase
        public var memoText: String

        public init(captureID: UUID) {
            self.captureID = captureID
            self.phase = .memo
            self.memoText = ""
        }
    }

    public enum Phase: Equatable, Sendable {
        case memo         // textarea 입력 대기
        case savingMemo   // 메모 저장 진행 중
    }

    public enum Action: Sendable {
        case dismissTapped
        case memoTextChanged(String)
        case memoSaveTapped
        case memoSaveFinished
        case delegate(Delegate)

        public enum Delegate: Equatable, Sendable {
            case dismiss
        }
    }

    public enum CancelID: Hashable, Sendable { case work }

    @Dependency(\.mochiItemRepository) var repository
    @Dependency(\.mochiAPIClient)    var api

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .memoTextChanged(text):
                state.memoText = text
                return .none

            case .memoSaveTapped:
                guard state.phase == .memo else { return .none }
                let trimmed = state.memoText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return .none }
                state.phase = .savingMemo
                let id = state.captureID
                return .run { [repository, api] send in
                    do {
                        try await commitMemo(
                            text: trimmed,
                            captureID: id,
                            repository: repository,
                            api: api
                        )
                    } catch {
                        // 무시. fallback 은 MochiItemSyncWorker 가 담당.
                    }
                    // 어떤 분기든 marker 폐기 — invariant.
                    discardMemoMarker(captureID: id)
                    await send(.memoSaveFinished)
                }
                .cancellable(id: CancelID.work)

            case .memoSaveFinished:
                return .send(.delegate(.dismiss))

            case .dismissTapped:
                discardMemoMarker(captureID: state.captureID)
                return .merge(
                    .cancel(id: CancelID.work),
                    .send(.delegate(.dismiss))
                )

            case .delegate:
                return .none
            }
        }
    }
}

// MARK: - Helpers

/// `<captureID>.memo` marker 파일 폐기. 중복 호출은 무해 (try?).
private func discardMemoMarker(captureID: UUID) {
    let url = AppGroup.pendingBackTapDirectoryURL
        .appendingPathComponent(AppGroup.pendingBackTapMemoFilename(captureID: captureID.uuidString))
    try? FileManager.default.removeItem(at: url)
}

/// 사용자가 모달의 textarea 에서 입력한 메모를 MochiItem 로 저장 + 백엔드 ingest.
private func commitMemo(
    text: String,
    captureID: UUID,
    repository: any MochiItemRepository,
    api: any MochiAPIClient
) async throws {
    let source = IngestSource(
        id: captureID,
        channel: .appDirectInput,
        text: text
    )
    try await repository.upsert(MochiItem(source: source))

    let dto = try await api.ingestMochiItem(
        MochiItemIngestRequest(
            channel: .appDirectInput,
            text: text
        ),
        idempotencyKey: captureID.uuidString
    )
    try await repository.updateSync(
        mochiItemID: captureID,
        to: .uploaded(serverID: dto.id, at: Date())
    )
}
