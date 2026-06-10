import Foundation

public extension SampleMochiItems {

    /// 검색 디자인 명세(`모찌 검색.html` data.jsx) 의 데모 시드 7건.
    /// mochiAnswer 키워드 매핑(병원/AI/과제) 이 의존하는 id 라 *수정 시 답변 helper 도 같이*.
    static func designDemo(now: Date = .init()) -> [MochiItem] {
        let cal = Calendar(identifier: .gregorian)

        func at(daysAgo: Double, hour: Int, minute: Int = 0) -> Date {
            let base = now.addingTimeInterval(-(daysAgo * 86_400))
            var c = cal.dateComponents([.year, .month, .day], from: base)
            c.hour = hour
            c.minute = minute
            return cal.date(from: c) ?? base
        }

        func todo(_ title: String, deadline: String? = nil, note: String? = nil) -> IntentInstance {
            IntentInstance(intentType: .todo,
                           payload: .init(title: title, deadline: deadline, note: note),
                           label: title)
        }
        func sched(_ title: String, date: String? = nil, time: String? = nil, person: String? = nil) -> IntentInstance {
            IntentInstance(intentType: .schedule,
                           payload: .init(title: title, date: date, time: time, person: person),
                           label: title)
        }
        func know(_ topic: String, url: String? = nil, note: String? = nil) -> IntentInstance {
            IntentInstance(intentType: .knowledge,
                           payload: .init(topic: topic, url: url, note: note),
                           label: topic)
        }
        func memo(_ title: String, note: String? = nil) -> IntentInstance {
            IntentInstance(intentType: .memo,
                           payload: .init(title: title, note: note),
                           label: title)
        }

        func item(
            id: Int,
            channel: IngestChannel,
            url: URL? = nil,
            text: String? = nil,
            summary: String,
            instances: [IntentInstance],
            capturedAt: Date
        ) -> MochiItem {
            let sourceID = demoMochiID(id)
            let source = IngestSource(
                id: sourceID,
                channel: channel,
                url: url,
                text: text,
                capturedAt: capturedAt
            )
            let analysis = MochiItemAnalysis(
                summary: summary,
                instances: instances,
                entities: [],
                actionCandidates: [],
                tags: [],
                importance: .medium,
                modelVersion: "design-demo-v1",
                analyzedAt: capturedAt.addingTimeInterval(60)
            )
            return MochiItem(
                source: source,
                analysis: analysis,
                lifecycleState: .analyzed,
                syncState: .uploaded(serverID: sourceID, at: capturedAt.addingTimeInterval(30)),
                createdAt: capturedAt,
                updatedAt: capturedAt.addingTimeInterval(60)
            )
        }

        return [
            // id 1 — schedule, kakao
            item(
                id: 1,
                channel: .kakaoTalk,
                text: "엄마: 다음주 화요일 정형외과 같이 가줄래?",
                summary: "카톡에서 받은 일정 메모예요. 다음주 화요일 병원 동행 약속으로 정리했어요.",
                instances: [sched("엄마 병원 동행", date: "6월 10일 (화)", time: "오전 10:00", person: "엄마")],
                capturedAt: at(daysAgo: 14, hour: 19, minute: 12)
            ),

            // id 2 — todo, memo
            item(
                id: 2,
                channel: .appDirectInput,
                text: "병원 가기 전 챙길 것 — 진료기록 사본, 약 목록, 실손 영수증",
                summary: "다음 방문 전에 필요한 서류와 진료기록을 챙기기로 남겨둔 메모예요.",
                instances: [todo("병원 진료기록 챙기기", deadline: "6월 10일 오전까지")],
                capturedAt: at(daysAgo: 16, hour: 22, minute: 5)
            ),

            // id 3 — todo, link  ("방금" — 가장 최근)
            item(
                id: 3,
                channel: .safari,
                url: URL(string: "https://example.com/ai-eng"),
                text: "Chip Huyen 의 AI Engineering 신간 — LLM 평가 + 데이터 파이프라인",
                summary: "실무 LLM 적용과 평가 지표를 정리한 링크예요.",
                instances: [todo("AI 엔지니어링 책 읽기", deadline: "이번 주말", note: "example.com/ai-eng")],
                capturedAt: now.addingTimeInterval(-180)   // 3분 전
            ),

            // id 4 — knowledge, screenshot
            item(
                id: 4,
                channel: .screenshot,
                text: "좋은 프롬프트는 맥락·예시·형식 세 가지를 분명히 한다",
                summary: "AI에게 좋은 답을 끌어내는 프롬프트 작성법을 정리한 스크린샷이에요.",
                instances: [know("AI 프롬프트 작성 노하우", note: "맥락·예시·형식")],
                capturedAt: at(daysAgo: 7, hour: 10, minute: 30)
            ),

            // id 5 — memo (명세 record), memo
            item(
                id: 5,
                channel: .appDirectInput,
                text: "팀플 최종 — 발표 자료 + 보고서 6/12 자정 마감",
                summary: "이번 학기 팀플 과제 제출 마감을 한곳에 기록해 뒀어요.",
                instances: [memo("과제 마감일 정리", note: "팀플 최종 제출 6월 12일 (목) 23:59")],
                capturedAt: at(daysAgo: 8, hour: 18, minute: 0)
            ),

            // id 6 — schedule, calendar
            item(
                id: 6,
                channel: .appShareSheet,
                text: "치과 정기검진 — 6월 13일 (금) 오후 3시 미소치과",
                summary: "다음 검진 예약을 6월 둘째 주로 잡아 둔 일정이에요.",
                instances: [sched("치과 정기검진", date: "6월 13일 (금)", time: "오후 3:00")],
                capturedAt: at(daysAgo: 10, hour: 11, minute: 45)
            ),

            // id 7 — knowledge, link
            item(
                id: 7,
                channel: .safari,
                url: URL(string: "https://example.com/fx-tip"),
                text: "환율 우대 + 인터넷 환전으로 수수료 절약",
                summary: "해외 송금 수수료를 아끼는 방법을 정리해 둔 링크예요.",
                instances: [know("환율 우대 받는 법", url: "https://example.com/fx-tip")],
                capturedAt: at(daysAgo: 22, hour: 14, minute: 20)
            ),
        ]
    }

    /// 시작 화면의 "최근 정리된 모찌" 2건 — 명세 `RECENT_MEMORY_IDS = [3, 1]`.
    static func designDemoRecent(now: Date = .init()) -> [MochiItem] {
        let all = designDemo(now: now)
        return [3, 1].compactMap { n in
            let id = demoMochiID(n)
            return all.first { $0.id == id }
        }
    }

    /// `Memory.id` (1..7) → 안정 UUID. mochiAnswer 의 refs(Int) 와 시드를 매핑.
    static func demoMochiID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "0BADA000-0000-0000-0000-%012d", n))!
    }
}
