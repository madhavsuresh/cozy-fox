import ChicagoTheme
import SwiftUI
import WidgetKit

@main
struct CozyFoxWidgetBundle: WidgetBundle {
    init() {
        ChicagoTheme.bootstrap()
    }

    var body: some Widget {
        DashboardWidget()
        LockScreenInlineWidget()
        LockScreenRectangularWidget()
        LockScreenCircularWidget()
        RefreshControlWidget()
    }
}
