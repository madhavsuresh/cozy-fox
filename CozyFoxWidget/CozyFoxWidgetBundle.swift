import WidgetKit
import SwiftUI

@main
struct CozyFoxWidgetBundle: WidgetBundle {
    var body: some Widget {
        DashboardWidget()
        LockScreenInlineWidget()
        LockScreenRectangularWidget()
        LockScreenCircularWidget()
        RefreshControlWidget()
    }
}
