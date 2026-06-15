import Foundation

/// 관련 링크 중복 제거용 정규화 키.
///
/// 백엔드 ``repository._canonical_link_key`` 와 **같은 규칙**을 유지한다(단일 기준 — 한쪽이 못 거른
/// 중복을 다른 쪽이 잡는 안전망 관계). youtu.be · watch?v= · shorts/ · embed/ · /v/ 는 같은 영상으로
/// 환원하고(youtu.be `?si=` 공유 파라미터·watch `&list=`/`&t=` 무시), 그 외는 host(www./m. 제거)+
/// path(소문자)+원본 query 로 묶는다. query 값은 토큰·ID 식별이라 대소문자를 구분(소문자화하지 않음).
///
/// ⓪ 계약이 아닌 ③(주석) 단일기준이라 백엔드와 정상 URL(http/https, 비-percent-encoded path)에 한해
/// 동등하다 — percent-encoded path 는 Swift `URL.path` 가 디코드해 백엔드(인코딩 유지)와 갈릴 수 있으나
/// dedup 은 백엔드(주)+이 표시단(안전망) 2중이라 무해.
public enum URLCanonical {
    public static func key(_ url: URL) -> String {
        guard var host = url.host?.lowercased() else {
            return url.absoluteString.lowercased()
        }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        var path = url.path
        if path.hasSuffix("/") { path.removeLast() }

        if host == "youtu.be" {
            let vid = path.split(separator: "/").first.map(String.init) ?? ""
            if !vid.isEmpty { return "youtube:\(vid)" }
        } else if host == "youtube.com" {
            if path == "/watch" {
                let vid = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "v" }?.value ?? ""
                if !vid.isEmpty { return "youtube:\(vid)" }
            } else if path.hasPrefix("/shorts/") || path.hasPrefix("/embed/") || path.hasPrefix("/v/") {
                let segs = path.split(separator: "/")
                if segs.count >= 2 { return "youtube:\(segs[1])" }
            }
        }

        let key = host + path.lowercased()
        let query = url.query ?? ""
        return query.isEmpty ? key : "\(key)?\(query)"
    }
}
