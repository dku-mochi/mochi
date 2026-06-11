#if DEBUG
import SwiftUI
import ComposableArchitecture
import CoreDomain

/// 기록 상세 화면 미리보기 — mock 데이터로 주요 상태를 Xcode Canvas 에서 확인.
///
/// `EmptyReducer` 로 onAppear(repository.find) 를 no-op 처리해 DI 없이 State 의 mock 을 그대로 렌더한다.
/// (제목 인라인 교정은 reducer 가 필요하므로 preview 에선 정적 렌더만 — 인터랙션은 시뮬레이터에서 확인.)
private enum DetailPreviewData {
    static let knowledge = MochiItem(
        source: IngestSource(
            channel: .youtube,
            url: URL(string: "https://www.youtube.com/watch?v=abc"),
            capturedAt: Date()
        ),
        analysis: MochiItemAnalysis(
            summary: "이 영상은 LangChain 의 Agent 구조와 Tool Use 패턴을 단계별로 설명해요. 핵심은 ReAct 루프와 메모리 연결입니다.",
            instances: [
                IntentInstance(
                    intentType: .knowledge,
                    payload: IntentPayload(title: "LangChain Agent 구조 정리", topic: "AI Agent"),
                    reasoning: "학습·참고용 지식 자료로 보여요."
                )
            ],
            entities: [
                ExtractedEntity(kind: .organization, value: "LangChain"),
                ExtractedEntity(kind: .other, value: "ReAct")
            ],
            actionCandidates: [.openURL(URL(string: "https://www.youtube.com/watch?v=abc")!)],
            tags: ["AI", "Agent", "LangChain"],
            importance: .medium,
            modelVersion: "preview",
            analyzedAt: Date()
        ),
        lifecycleState: .analyzed,
        syncState: .uploaded(serverID: UUID(), at: Date())
    )

    static let multiIntent = MochiItem(
        source: IngestSource(
            channel: .kakaoTalk,
            text: "내일 3시 디자인 시스템 회의, 끝나고 발표자료 정리 부탁해요",
            capturedAt: Date()
        ),
        analysis: MochiItemAnalysis(
            summary: "내일 오후 3시 디자인 시스템 회의 일정과, 회의 후 발표자료 정리 할 일이 있어요.",
            instances: [
                IntentInstance(
                    intentType: .schedule,
                    payload: IntentPayload(title: "디자인 시스템 회의", date: "내일", time: "15:00", person: "팀"),
                    reasoning: "시간이 명시된 약속이에요."
                ),
                IntentInstance(
                    intentType: .todo,
                    payload: IntentPayload(title: "발표자료 정리", deadline: "회의 후"),
                    reasoning: "마감이 있는 할 일로 보여요."
                )
            ],
            needsReview: true,
            entities: [ExtractedEntity(kind: .time, value: "15:00")],
            actionCandidates: [
                .createCalendarEvent(title: "디자인 시스템 회의", startISO8601: "2026-06-07T15:00:00Z", endISO8601: nil)
            ],
            tags: ["회의", "발표"],
            importance: .high,
            modelVersion: "preview",
            analyzedAt: Date()
        ),
        lifecycleState: .analyzed,
        syncState: .uploaded(serverID: UUID(), at: Date())
    )

    /// 행동(할일·일정·링크)이 하나도 없는 메모 — ② 섹션이 숨고 헤더+③ 만 남는 최소 골격 확인용.
    static let memoOnly = MochiItem(
        source: IngestSource(
            channel: .appDirectInput,
            text: "포트폴리오 사이트 레퍼런스 — 미니멀 레이아웃에 큰 타이포, 프로젝트는 스크롤 한 줄로.",
            userMemo: "다음 사이드 프로젝트 때 참고",
            capturedAt: Date()
        ),
        analysis: MochiItemAnalysis(
            summary: "포트폴리오 사이트를 만들 때 참고할 디자인 방향 메모예요. 미니멀 레이아웃과 큰 타이포그래피가 핵심이에요.",
            instances: [
                IntentInstance(
                    intentType: .memo,
                    payload: IntentPayload(title: "포트폴리오 디자인 레퍼런스"),
                    reasoning: "나중에 다시 볼 기록으로 보여요."
                )
            ],
            entities: [],
            actionCandidates: [],
            tags: ["디자인"],
            importance: .medium,
            modelVersion: "preview",
            analyzedAt: Date()
        ),
        lifecycleState: .analyzed,
        syncState: .uploaded(serverID: UUID(), at: Date())
    )

    static let processing = MochiItem(
        source: IngestSource(
            channel: .screenshot,
            imageRefs: [
                ImageRef(relativePath: "preview/none.heic", mimeType: "image/heic", byteSize: 0, sha256: "0")
            ],
            capturedAt: Date()
        ),
        analysis: nil,
        lifecycleState: .analyzing,
        syncState: .uploaded(serverID: UUID(), at: Date())
    )

    static func store(_ item: MochiItem) -> StoreOf<DetailFeature> {
        var state = DetailFeature.State(mochiItemID: item.id)
        state.mochiItem = item
        return Store(initialState: state) {
            EmptyReducer<DetailFeature.State, DetailFeature.Action>()
        }
    }
}

#Preview("지식 · 단일") {
    NavigationStack { DetailView(store: DetailPreviewData.store(DetailPreviewData.knowledge)) }
}

#Preview("멀티 의도 · 헷갈림") {
    NavigationStack { DetailView(store: DetailPreviewData.store(DetailPreviewData.multiIntent)) }
}

#Preview("메모 · 행동 없음") {
    NavigationStack { DetailView(store: DetailPreviewData.store(DetailPreviewData.memoOnly)) }
}

#Preview("분석 중") {
    NavigationStack { DetailView(store: DetailPreviewData.store(DetailPreviewData.processing)) }
}
#endif
