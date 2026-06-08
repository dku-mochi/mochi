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
                Button("로그아웃", role: .destructive) {
                    store.send(.logoutButtonTapped)
                }
            }
        }
        .navigationTitle("설정")
    }
}
