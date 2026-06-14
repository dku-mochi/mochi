import Foundation
import CoreDomain

/// `MochiItemDTO`(분석 응답) → 도메인 `MochiItemAnalysis` 매핑 — **단일 원천**.
///
/// 폴링(`MochiItemSyncWorker.pollAnalysisOnce`)과 SSE(`LiveAgentStreamClient`)가 둘 다 `final`
/// 시점에 `GET /mochi_items/{id}` 응답을 분석 도메인으로 변환한다. 두 경로가 따로 매핑하면 계약이
/// 갈라지므로 여기 한 곳에 둔다. **`lifecycleKind == "analyzed"` 인 DTO 에만 의미가 있다**(호출부가 보장).
public extension MochiItemDTO {
    func toMochiItemAnalysis() -> MochiItemAnalysis {
        MochiItemAnalysis(
            summary: summary ?? "",
            category: category,
            shoppingProductQuery: shoppingProductQuery,
            referenceLinks: referenceLinks.compactMap { dto in
                URL(string: dto.url).map {
                    ReferenceLink(
                        url: $0,
                        title: dto.title,
                        label: dto.label,
                        role: dto.role,
                        provider: dto.provider,
                        rankProfile: dto.rankProfile,
                        source: dto.source,
                        usefulness: dto.usefulness
                    )
                }
            },
            instances: intentInstances.map { i in
                IntentInstance(
                    id: i.id,
                    intentType: i.intentType,
                    payload: Self.payload(from: i.payload),
                    label: i.label,
                    reasoning: i.reasoning,
                    lifecycle: Self.instanceLifecycle(kind: i.lifecycleKind, reason: i.lifecycleArchiveReason)
                )
            },
            needsReview: needsReview,
            reviewOptions: reviewOptions.map {
                ReviewOption(intentType: $0.intentType, label: $0.label, reasoning: $0.reasoning)
            },
            entities: [],
            actionCandidates: [],
            tags: [],
            importance: MochiItemAnalysis.Importance(rawValue: importance) ?? .medium,
            modelVersion: "gemini-3.1-flash-lite",
            analyzedAt: Date()
        )
    }

    /// 서버 `MochiItemDTO` → 도메인 `MochiItem` 역매핑 — 앱 재설치 후 서버→로컬 복구(pull) 전용.
    ///
    /// **서버 PK = 로컬 PK 규약(복구 한정)**: 재설치 후 로컬엔 매칭 키가 없으므로 서버 id 를 그대로
    /// `MochiItem.id`(=Realm primary key)로 채택한다. 그래야 재pull 이 같은 행을 upsert 해 멱등이다
    /// (`MochiItem.swift` 의 "서버 id 는 로컬 id 와 다르다" 규약은 *새 캡처* 에 대한 것이고, 복구
    /// 항목은 이미 서버가 정본이라 서버 id 를 정체성으로 삼는다). `syncState` 는 항상
    /// `.uploaded(serverID:)` — 이미 서버에 있는 항목이다.
    ///
    /// 이미지 `relativePath` 는 빈 문자열로 둔다(로컬 파일 없음) — 호출자(`pullRemote`)가 `objectKey`
    /// 로 원본을 내려받아 `captures/` 에 저장하고 경로를 채운다.
    func toMochiItem() -> MochiItem {
        let refs = imageRefs.map { ref in
            ImageRef(
                relativePath: "",
                mimeType: ref.mimeType,
                byteSize: ref.byteSize,
                sha256: ref.sha256,
                objectKey: ref.objectKey
            )
        }
        let source = IngestSource(
            id: id,
            channel: channel,
            url: url,
            text: text,
            imageRefs: refs,
            userMemo: userMemo,
            capturedAt: capturedAt
        )
        // analyzed 인 항목만 분석을 복원한다(그 외는 analysis==nil → 폴링이 GET 으로 마저 확인).
        let analysis = (lifecycleKind == "analyzed") ? toMochiItemAnalysis() : nil
        return MochiItem(
            source: source,
            analysis: analysis,
            lifecycleState: Self.processingState(from: lifecycleKind),
            syncState: .uploaded(serverID: id, at: createdAt),
            userTitle: nil,           // userTitle 은 로컬 오버라이드 — 서버 미보관, 대표 제목으로 폴백.
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private static func processingState(from kind: String) -> ProcessingState {
        switch kind {
        case "analyzing": return .analyzing
        case "analyzed":  return .analyzed
        case "failed":    return .failed(reason: "server")
        default:          return .ingested
        }
    }

    private static func payload(from dto: IntentPayloadDTO?) -> IntentPayload {
        guard let dto else { return IntentPayload() }
        return IntentPayload(
            title: dto.title, date: dto.date, time: dto.time,
            endDate: dto.endDate, endTime: dto.endTime, deadline: dto.deadline,
            person: dto.person, topic: dto.topic, url: dto.url, note: dto.note
        )
    }

    /// 응답 instance 의 의미상태(kind+reason)를 도메인으로. 새로 적재된 instance 는 대개 `active`.
    /// archived 면 서버가 실은 reason(`todoCompleted` 등)을 함께 보내므로 그대로 복원한다 —
    /// 완료 todo 가 `userManual` 로 둔갑하던 round-trip 손실을 막는다(reason 누락 시에만 userManual 폴백).
    private static func instanceLifecycle(kind: String, reason: String?) -> InstanceLifecycle {
        switch kind {
        case "decaying":        return .decaying
        case "reviewRequested": return .reviewRequested
        case "archived":
            let archiveReason = reason.flatMap(InstanceLifecycle.ArchiveReason.init(rawValue:)) ?? .userManual
            return .archived(reason: archiveReason)
        default:                return .active
        }
    }
}
