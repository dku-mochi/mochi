import WidgetKit
import SwiftUI

/// Widget extension 의 entry point. 현재 Live Activity 하나만 등록.
///
/// production 에선 home-screen widget / lock-screen widget 등이 추가될 수 있다.
@main
struct MochiWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MochiLiveActivity()
    }
}
