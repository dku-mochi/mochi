import Foundation
import CoreDomain
import CoreNetworking

/// todo 완료↔미완료 토글의 서버 push 공용 use case — 캘린더 탭·기록 상세가 같은 경로를 쓴다.
///
/// 호출자가 **낙관적 로컬 전이를 먼저 수행**한 뒤 부른다(캘린더는 observeChanges, 상세는 reload 로
/// 화면 반영). 서버 push 실패 시 로컬을 `instance` 의 이전 상태로 롤백하고 보고용 메시지를 돌려준다.
/// `intent_instance.not_found` 는 레거시 데이터 치유(로컬 instance id ↔ 서버 id 불일치)를 시도한다.
public enum TodoLifecycleSync {
    /// 성공 시 nil. 실패 시 로컬은 이미 롤백된 상태이며 사용자 보고용 메시지를 반환한다.
    /// - Parameters:
    ///   - item: 토글 대상 instance 가 속한 item (serverID 추출용 — 미업로드면 로컬만 유지하고 성공 취급).
    ///   - instance: **전이 전** 스냅샷 — 롤백 상태와 레거시 치유의 label 매칭에 쓴다.
    ///   - target: 전이 목표 (`.archived(reason: .todoCompleted)` 또는 `.active`).
    public static func pushToggle(
        item: MochiItem,
        instance: IntentInstance,
        target: InstanceLifecycle,
        repository: any MochiItemRepository,
        apiClient: any MochiAPIClient
    ) async -> String? {
        guard case let .uploaded(serverID, _) = item.syncState else { return nil }
        do {
            _ = try await apiClient.updateInstanceLifecycle(
                mochiServerID: serverID, instanceID: instance.id, to: target
            )
            return nil
        } catch let error as APIErrorEnvelope where error.code == "intent_instance.not_found" {
            return await healLegacyTodoInstance(
                repository: repository, apiClient: apiClient,
                itemID: item.id, serverID: serverID, staleInstance: instance, target: target
            )
        } catch {
            try? await repository.updateInstanceLifecycle(
                mochiItemID: item.id, instanceID: instance.id, to: instance.lifecycle
            )
            return String(describing: error)
        }
    }

    /// 기존 데이터(변경 전 분석분) 완료 토글의 404 치유 — 로컬 instance id 가 서버 id 와 불일치할 때.
    /// 서버 최신(`getMochiItem`)에서 진짜 todo instance id 를 얻어 재시도하고, 응답으로 로컬 analysis 를
    /// 교체해 instance id 를 서버값으로 영구 일치시킨다(다음 토글부터 정상). 실패 시 낙관적 로컬을 롤백.
    private static func healLegacyTodoInstance(
        repository: any MochiItemRepository,
        apiClient: any MochiAPIClient,
        itemID: UUID,
        serverID: UUID,
        staleInstance: IntentInstance,
        target: InstanceLifecycle
    ) async -> String? {
        let todos = (try? await apiClient.getMochiItem(id: serverID))?
            .intentInstances.filter { $0.intentType == .todo } ?? []
        // 여러 todo 중 같은 label 우선(정확한 대상 지목), 없으면 첫 todo.
        guard let freshTodo = todos.first(where: { $0.label == staleInstance.label }) ?? todos.first else {
            try? await repository.updateInstanceLifecycle(
                mochiItemID: itemID, instanceID: staleInstance.id, to: staleInstance.lifecycle
            )
            return "intent_instance.not_found; heal failed"
        }
        do {
            let updated = try await apiClient.updateInstanceLifecycle(
                mochiServerID: serverID, instanceID: freshTodo.id, to: target
            )
            // 서버 응답(서버 instance id + 갱신된 상태)으로 로컬 교정 — 다음 토글부터 id 일치.
            if var domain = try? await repository.find(id: itemID) {
                domain.analysis = updated.toMochiItemAnalysis()
                try? await repository.upsert(domain)
            }
            return nil
        } catch {
            try? await repository.updateInstanceLifecycle(
                mochiItemID: itemID, instanceID: staleInstance.id, to: staleInstance.lifecycle
            )
            return String(describing: error)
        }
    }
}
