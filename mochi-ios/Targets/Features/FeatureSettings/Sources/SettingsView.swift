import SwiftUI
import ComposableArchitecture

public struct SettingsView: View {
    @Bindable public var store: StoreOf<SettingsFeature>

    public init(store: StoreOf<SettingsFeature>) { self.store = store }

    public var body: some View {
        Form {
            Section("백엔드") {
                TextField("Server Endpoint", text: $store.serverEndpoint)
            }
            Section("자동 동기화") {
                Toggle("캘린더 동기화", isOn: $store.calendarSyncEnabled)
                Toggle("미리알림 동기화", isOn: $store.reminderSyncEnabled)
            }
            Section {
                Button {
                    store.send(.syncAllTapped)
                } label: {
                    if store.isSyncing {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("동기화 중…")
                        }
                    } else {
                        Label("전체 동기화", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(store.isSyncing)
            } footer: {
                Text("다른 기기에 저장했거나 앱을 다시 설치한 경우, 서버에 보관된 기록을 이 기기로 불러옵니다.")
            }

            Section("도움말") {
                Button {
                    store.send(.onboardingButtonTapped)
                } label: {
                    Label("온보딩 다시 보기", systemImage: "play.circle")
                }
            }
            Section {
                Button("로그아웃", role: .destructive) {
                    store.send(.logoutButtonTapped)
                }
            }
        }
        .navigationTitle("설정")
    }
}
