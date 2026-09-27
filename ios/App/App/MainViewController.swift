import Capacitor
import JarvisAudioPlugin
import UIKit

// The storyboard's bridge: Capacitor's own, pointed at the JARVIS address saved in the app (the first-run
// page or Settings → JARVIS) rather than only the one baked into capacitor.config.json at build time.
class MainViewController: CAPBridgeViewController {
    override func instanceDescriptor() -> InstanceDescriptor {
        let descriptor = super.instanceDescriptor()
        ServerSettings.apply(to: descriptor)
        return descriptor
    }
}
