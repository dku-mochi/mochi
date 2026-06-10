import Foundation

/// SSE 파서 — `URLSession.AsyncBytes` 를 **바이트 단위**로 받아 (event, data) 로 접는다.
///
/// `bytes.lines`(`AsyncLineSequence`)는 **빈 줄을 방출하지 않아** SSE 의 이벤트 경계
/// (빈 줄)가 통째로 사라진다 (2026-06-10 리뷰 P1 — delta·done 이 한 건도 전달되지 않음).
/// SSE 소비는 반드시 이 파서로 바이트를 직접 먹인다.
///
/// `LiveAgentStreamClient`(분석 진행)와 `LiveChatStreamClient`(채팅 run)가 공유.
/// 규약: 빈 줄 = 이벤트 경계, `:` 시작 = 코멘트, `data:` 다중 행은 `\n` 으로 잇고,
/// CRLF 의 `\r` 은 제거한다.
struct SSEEventParser {
    private var lineBuffer: [UInt8] = []
    private var event: String?
    private var data = ""

    /// 바이트 1개 소비. 라인이 닫히고 그 라인이 이벤트 경계(빈 줄)면 완성된 이벤트 반환.
    mutating func consume(byte: UInt8) -> (event: String, data: String)? {
        guard byte == UInt8(ascii: "\n") else {
            lineBuffer.append(byte)
            return nil
        }
        return consume(line: takeLine())
    }

    /// 라인 1개 소비 (테스트·내부용). 빈 줄이면 완성된 이벤트를 반환하고 리셋한다.
    mutating func consume(line: String) -> (event: String, data: String)? {
        if line.isEmpty {
            return takeEvent()
        }
        if line.hasPrefix(":") { return nil }  // 코멘트(": stream-open")
        if let value = Self.fieldValue(line, prefix: "event:") {
            event = value
        } else if let value = Self.fieldValue(line, prefix: "data:") {
            data += data.isEmpty ? value : "\n" + value
        }
        return nil
    }

    /// 스트림 종료 — 개행 없이 끝난 잔여 라인을 닫고, 경계 없이 끝난 잔여 이벤트를 반환.
    mutating func flush() -> (event: String, data: String)? {
        if !lineBuffer.isEmpty {
            _ = consume(line: takeLine())  // 비어있지 않은 라인은 이벤트를 완성하지 않는다
        }
        return takeEvent()
    }

    // MARK: - 내부

    private mutating func takeLine() -> String {
        var line = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        if line.last == UInt8(ascii: "\r") { line.removeLast() }
        return String(decoding: line, as: UTF8.self)
    }

    private mutating func takeEvent() -> (event: String, data: String)? {
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
