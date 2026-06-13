import Foundation
import CoreDomain
import CoreNetworking

/// 즐겨찾기 토글의 서버 push 공용 use case — 검색 카드·기록 상세가 같은 경로를 쓴다.
///
/// 호출자가 **낙관적 로컬 전이를 먼저 수행**한 뒤 부른다. 서버 push 실패 시 로컬을 이전 값으로
/// 롤백하고 보고용 메시지를 돌려준다. 즐겨찾기는 item 레벨 set-state 라 instance id 치유 같은
/// 레거시 처리가 없다(완료 토글과 다른 점). 미업로드(로컬 전용) 항목은 서버 push 없이 성공 취급.
public enum FavoriteSync {
    /// 성공 시 nil. 실패 시 로컬은 이미 이전 값으로 롤백된 상태이며 사용자 보고용 메시지를 반환한다.
    /// - Parameters:
    ///   - item: 토글 대상 item (serverID 추출용 — 미업로드면 로컬만 유지하고 성공 취급).
    ///   - isFavorite: 전이 목표 값. 실패 시 `!isFavorite` 로 롤백한다.
    public static func pushToggle(
        item: MochiItem,
        isFavorite: Bool,
        repository: any MochiItemRepository,
        apiClient: any MochiAPIClient
    ) async -> String? {
        guard case let .uploaded(serverID, _) = item.syncState else { return nil }
        do {
            _ = try await apiClient.setFavorite(mochiServerID: serverID, isFavorite: isFavorite)
            return nil
        } catch {
            try? await repository.setFavorite(mochiItemID: item.id, isFavorite: !isFavorite)
            return String(describing: error)
        }
    }
}
