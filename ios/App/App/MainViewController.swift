import Capacitor
import JarvisAudioPlugin
import UIKit

// Points Capacitor at the JARVIS address saved in the app (first-run page or Settings → JARVIS), not only the
// one baked into capacitor.config.json at build time.
class MainViewController: CAPBridgeViewController {
    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        ServerSettings.apply(to: descriptor)
        return descriptor
    }
}
