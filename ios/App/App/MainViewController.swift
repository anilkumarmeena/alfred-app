import Capacitor
import AlfredAudioPlugin
import UIKit

// Points Capacitor at the Alfred address saved in the app (first-run page or Settings → Alfred), not only the
// one baked into capacitor.config.json at build time.
class MainViewController: CAPBridgeViewController {
    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        ServerSettings.apply(to: descriptor)
        return descriptor
    }
}
