import Foundation

/// 채팅 텍스트 delta 의 타자기 스무딩 — 서버는 토큰/문장 블록 단위로 보내므로 그대로
/// 그리면 텍스트가 "띡 띡" 튄다 (2026-06-10 피드백). 블록을 글자 단위로 쪼개 일정한
/// 속도로 다시 방출해 자연스러운 타이핑 감각을 만든다.
///
/// - 비-텍스트 이벤트(tool/citation/proposal/done)는 **순서를 보존한 채** 그대로 통과 —
///   직전 텍스트가 모두 풀린 뒤에야 방출되므로 본문↔카드 정합이 유지된다.
/// - 백로그가 길수록 글자당 지연을 줄여(최소 지연까지) 긴 답변이 뒤로 갈수록 굼뜨게
///   끌리는 것을 막는다.
enum ChatStreamSmoothing {
    /// 기본 글자당 지연(ms) — 한국어 읽기 속도보다 약간 빠른 타이핑 감각.
    static let baseDelayMilliseconds = 14.0
    /// 큰 블록이 밀렸을 때의 하한(ms) — 이보다 느려지지 않게 가속.
    static let minDelayMilliseconds = 4.0
    /// 이 길이를 넘는 잔여 블록부터 가속 시작.
    static let backlogThreshold = 60

    static func smoothed(
        _ upstream: AsyncThrowingStream<ChatStreamEvent, Error>
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        guard case let .messageDelta(block) = event else {
                            continuation.yield(event)
                            continue
                        }
                        var remaining = block.count
                        for character in block {
                            continuation.yield(.messageDelta(String(character)))
                            remaining -= 1
                            try await Task.sleep(for: delay(backlog: remaining))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 잔여 글자 수에 비례해 base→min 으로 선형 가속.
    static func delay(backlog: Int) -> Duration {
        guard backlog > backlogThreshold else { return .milliseconds(baseDelayMilliseconds) }
        let over = Double(min(backlog - backlogThreshold, 200))
        let milliseconds =
            baseDelayMilliseconds - (baseDelayMilliseconds - minDelayMilliseconds) * over / 200.0
        return .milliseconds(milliseconds)
    }
}
