import Dependencies
import Foundation
import CoreDomain

public enum MochiAPIClientKey: DependencyKey {
    public static let liveValue: any MochiAPIClient = NotConfiguredAPIClient()
    public static let testValue: any MochiAPIClient = NotConfiguredAPIClient()
}

public extension DependencyValues {
    var mochiAPIClient: any MochiAPIClient {
        get { self[MochiAPIClientKey.self] }
        set { self[MochiAPIClientKey.self] = newValue }
    }
}

/// 라이브 클라이언트가 주입되지 않았을 때 즉시 명시적인 에러를 던지는 sentinel.
public struct NotConfiguredAPIClient: MochiAPIClient {
    public init() {}
    public func ingestMochiItem(_ request: MochiItemIngestRequest, idempotencyKey: String) async throws -> MochiItemDTO {
        throw Self.error
    }
    public func presignCaptureUpload(sha256: String, mimeType: String) async throws -> PresignUploadDTO {
        throw Self.error
    }
    public func putCaptureImage(uploadURL: URL, data: Data, mimeType: String) async throws {
        throw Self.error
    }
    public func getMochiItem(id: UUID) async throws -> MochiItemDTO {
        throw Self.error
    }
    public func listMochiItems(limit: Int) async throws -> [MochiItemDTO] {
        throw Self.error
    }
    public func presignCaptureDownload(objectKey: String) async throws -> URL {
        throw Self.error
    }
    public func search(query: String, scope: SearchScope) async throws -> SearchResponse {
        throw Self.error
    }
    public func similarItems(serverID: UUID, limit: Int) async throws -> [SimilarItemRef] {
        throw Self.error
    }
    public func registerPushToken(token: String, kind: PushTokenKind, environment: PushEnvironment, mochiItemID: UUID?) async throws {
        throw Self.error
    }
    public func reanalyzeMochiItem(id: UUID, userHint: String) async throws {
        throw Self.error
    }
    public func updateInstanceLifecycle(
        mochiServerID: UUID,
        instanceID: UUID,
        to newState: InstanceLifecycle
    ) async throws -> MochiItemDTO {
        throw Self.error
    }
    public func deleteMochiItem(mochiServerID: UUID) async throws {
        throw Self.error
    }
    public func setFavorite(mochiServerID: UUID, isFavorite: Bool) async throws -> MochiItemDTO {
        throw Self.error
    }
    public func updateMochiItem(
        mochiServerID: UUID, _ request: MochiItemUpdateRequestDTO
    ) async throws -> MochiItemDTO {
        throw Self.error
    }
    public func upcomingActionables() async throws -> [UpcomingActionableDTO] {
        throw Self.error
    }
    public func monthlyDigest(monthStart: Date) async throws -> MonthlyDigestDTO {
        throw Self.error
    }
    public func recallFeed(limit: Int) async throws -> [RecallFeedEntryDTO] {
        throw Self.error
    }
    public func recallLanding(eventID: UUID) async throws -> RecallFeedEntryDTO {
        throw Self.error
    }
    public func recordRecallReaction(eventID: UUID, reaction: RecallReaction) async throws {
        throw Self.error
    }
    public func upcomingNotifications(limit: Int) async throws -> [UpcomingNotificationDTO] {
        throw Self.error
    }
    public func rescheduleUpcoming(eventID: UUID, fireAt: Date) async throws {
        throw Self.error
    }
    public func vetoUpcoming(eventID: UUID) async throws {
        throw Self.error
    }
    public func sentNotifications(limit: Int) async throws -> [SentNotificationDTO] {
        throw Self.error
    }
    private static let error = APIErrorEnvelope(
        code: "client.not_configured",
        message: "MochiAPIClient not wired",
        requestID: "n/a",
        retryAfter: nil
    )
}
