import Foundation

/// SSE 라인 프로토콜 파서 — `bytes.lines` 를 (event, data) 단위로 접는다.
///
/// `LiveAgentStreamClient`(분석 진행)와 `LiveChatStreamClient`(채팅 run)가 공유.
/// 규약: 빈 줄 = 이벤트 경계, `:` 시작 = 코멘트, `data:` 다중 행은 `\n` 으로 잇는다.
struct SSEEventParser {
    private var event: String?
    private var data = ""

    /// 라인 1개 소비. 이벤트 경계(빈 줄)에서 완성된 이벤트를 반환하고 리셋한다.
    mutating func consume(line: String) -> (event: String, data: String)? {
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil }  // 코멘트(": stream-open")
        if let value = Self.fieldValue(line, prefix: "event:") {
            event = value
        } else if let value = Self.fieldValue(line, prefix: "data:") {
            data += data.isEmpty ? value : "\n" + value
        }
        return nil
    }

    /// 스트림이 경계 없이 끝났을 때 잔여 이벤트 — 없으면 nil.
    mutating func flush() -> (event: String, data: String)? {
        defer {
            event = nil
            data = ""
        }
        guard let event, !data.isEmpty else { return nil }
        return (event, data)
    }

    /// `"data: {...}"` → `"{...}"`. 콜론 뒤 선행 공백 1개만 제거(SSE 규약).
    static func fieldValue(_ line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        var rest = Substring(line.dropFirst(prefix.count))
        if rest.first == " " { rest = rest.dropFirst() }
        return String(rest)
    }
}
