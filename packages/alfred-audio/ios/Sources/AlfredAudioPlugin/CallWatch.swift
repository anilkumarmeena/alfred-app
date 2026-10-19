import CallKit
import Foundation

/// Reports whether any CallKit call (phone, FaceTime, WhatsApp…) is ringing, dialling or on. CXCallObserver needs
/// no permission.
@MainActor
final class CallWatch: NSObject, CXCallObserverDelegate {
    var onChange: ((Bool) -> Void)?
    private(set) var onCall = false
    private let observer = CXCallObserver()

    override init() {
        super.init()
        onCall = observer.calls.contains { !$0.hasEnded }  // one already on when the app launched
        observer.setDelegate(self, queue: .main)
    }

    nonisolated func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        let on = callObserver.calls.contains { !$0.hasEnded }
        MainActor.assumeIsolated {  // the delegate queue is .main
            guard on != onCall else { return }
            onCall = on
            onChange?(on)
        }
    }
}
