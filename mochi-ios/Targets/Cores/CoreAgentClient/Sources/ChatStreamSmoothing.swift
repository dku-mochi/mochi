import Foundation

/// 채팅 텍스트 delta 를 한 덩어리로 합쳐 답변이 *한 번에* 떠오르게 한다 (2026-06-13 피드백).
/// 서버는 토큰/문장 블록 단위로 message_delta 를 보내는데, 그대로 그리면 글자가 "띡 띡"
/// 튀고 타자기처럼 흘러 산만하다. 텍스트 블록을 버퍼에 모았다가 — 비-텍스트 이벤트
/// (tool/citation/proposal/done) 직전 또는 스트림 종료 시 — 단일 messageDelta 로 방출한다.
/// UI 에선 `hasText` 가 false→true 로 한 번만 바뀌어 답변 전체가 부드럽게 페이드인된다.
///
/// - 비-텍스트 이벤트는 버퍼를 먼저 비운 뒤 순서대로 통과 — 본문↔카드(tool/출처/proposal)
///   정합이 유지된다.
/// - 의도적 취소(새 대화 전환 등)에선 버퍼를 버린다 — 버려질 턴에 부분 텍스트를 남기지 않는다.
/// - 에러(워치독 타임아웃 등)에선 모은 텍스트를 마지막에 한 번 방출한다 — 긴 답변이 막판에
///   끊겨도 받은 만큼은 보여준다(실패 안내는 runPhase 가 담당).
enum ChatStreamSmoothing {
    static func smoothed(
        _ upstream: AsyncThrowingStream<ChatStreamEvent, Error>
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var buffer = ""
                func flushText() {
                    guard !buffer.isEmpty else { return }
                    continuation.yield(.messageDelta(buffer))
                    buffer = ""
                }
                do {
                    for try await event in upstream {
                        guard case let .messageDelta(block) = event else {
                            flushText()
                            continuation.yield(event)
                            continue
                        }
                        buffer += block
                    }
                    flushText()
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()   // 버퍼 폐기 — 취소된 턴은 남기지 않는다.
                } catch {
                    flushText()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
