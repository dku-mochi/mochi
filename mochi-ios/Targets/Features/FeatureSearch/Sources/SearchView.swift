import SwiftUI
import ComposableArchitecture
import CoreNetworking
import DesignSystem

public struct SearchView: View {
    @Bindable public var store: StoreOf<SearchFeature>

    public init(store: StoreOf<SearchFeature>) { self.store = store }

    public var body: some View {
        VStack(spacing: MochiTheme.Spacing.m) {
            TextField("자연어로 질문…", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.send(.submit) }

            Picker("범위", selection: $store.selectedScope) {
                ForEach(SearchScope.allCases, id: \.self) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            if store.isSearching { ProgressView() }
            if let response = store.response {
                ScrollView {
                    Text(response.answer)
                        .font(MochiTheme.Typography.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
            if let error = store.lastError {
                Text(error).font(MochiTheme.Typography.caption).foregroundStyle(.red)
            }
        }
        .padding()
        .navigationTitle("검색")
    }
}
