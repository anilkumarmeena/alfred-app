import SwiftUI
import WidgetKit

/// The app's widget extension: only the session's Live Activity for now.
@main
struct JarvisWidgetBundle: WidgetBundle {
    var body: some Widget {
        JarvisLiveActivity()
    }
}
