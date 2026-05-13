import ChicagoTheme
import SwiftUI
import WidgetKit

@main
struct CozyFoxLiveActivityBundle: WidgetBundle {
    init() {
        ChicagoTheme.bootstrap()
    }

    var body: some Widget {
        CommuteLiveActivity()
    }
}
