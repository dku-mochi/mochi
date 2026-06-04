import Foundation

/// 백탭/공유 단축어가 `text` 채널에 실어 보내는 "캡처 컨텍스트" sentinel.
///
/// 단축어는 출처앱 같은 **자동 신호**를 평문 `[출처앱: X]` 대신 sentinel JSON 으로 전달한다.
/// `ShareExtensionPrincipal` 이 이를 받아 (a) UI 엔 칩으로 보여주고, (b) 백엔드 `text` 엔
/// 정규화 1줄로 합쳐 보낸다. 사용자가 직접 입력한 메모는 이 채널과 분리된 `user_memo` 로
/// 끝까지 격리된다 (자동신호 ↔ 사용자의도 2채널 경계, `IngestSource.hasUserIntentSignal`).
///
/// **포맷**: `{"__mochi_ctx__":{"sourceApp":"<앱>"}}`
/// 키 추가만으로 확장 가능(focus·시간 등). 단 `sourceApp` 1급화·jsonb 승격은 보류 —
/// 현재는 `text` 정규화 1줄로 흡수한다(백엔드/DB/openapi 무변경).
///
/// ⚠️ sentinel 은 단축어가 만드는 것이라 **신뢰 경계가 아니다** — 컨텍스트 보너스일 뿐이다.
public enum CaptureContextSentinel {
    /// sentinel 최상위 래퍼 키. 일반 텍스트와 충돌하지 않도록 고유하게 둔다.
    public static let marker = "__mochi_ctx__"

    /// 분해된 캡처 컨텍스트. 현재는 출처앱만 — 키 추가로 확장한다.
    public struct Context: Equatable, Sendable {
        public let sourceApp: String?
        public init(sourceApp: String?) { self.sourceApp = sourceApp }
    }

    /// `raw` 가 sentinel JSON 이면 컨텍스트로 분해, 아니면 nil(= 일반 텍스트로 취급).
    public static func decode(_ raw: String) -> Context? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.contains(marker),
              let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ctx = root[marker] as? [String: Any]
        else { return nil }
        return Context(sourceApp: normalizedValue(ctx["sourceApp"] as? String))
    }

    /// sentinel 은 신뢰 경계가 아니므로(단축어가 임의 조작 가능) 값을 방어적으로 정규화한다 —
    /// 양끝/내부 공백·개행을 단일 space 로 접어 `[출처앱: X]` 1줄 보장, 빈 값은 nil.
    private static func normalizedValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// 출처앱 → 백엔드 `text` 에 합칠 정규화 1줄 (예: `[출처앱: Safari]`).
    public static func sourceAppMarker(_ sourceApp: String) -> String {
        "[출처앱: \(sourceApp)]"
    }

    /// sentinel 에서 분해한 `sourceApp` 과 기존 `base` 텍스트를 백엔드용 `text` 로 합친다.
    /// sourceApp 이 있으면 정규화 마커를 맨 앞 줄에 둔다. 결과가 비면 nil.
    public static func composeText(sourceApp: String?, base: String?) -> String? {
        let parts = [
            sourceApp.map(sourceAppMarker),
            (base?.isEmpty == false) ? base : nil,
        ].compactMap { $0 }
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
