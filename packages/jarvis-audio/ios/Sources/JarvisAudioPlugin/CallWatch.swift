import CallKit
import Foundation

/// Phone calls on the iPhone, and other apps' CallKit calls (FaceTime, WhatsApp…), for VoiceSession: `onChange` says
/// whether any call is ringing, dialling or on, each time that changes. CXCallObserver needs no permission.
@MainActor
final class CallWatch: NSObject, CXCallObserverDelegate {
    var onChange: ((Bool) -> Void)?
    private(set) var onCall = false
    private let observer = CXCallObserver()

    override init() {
        super.init()
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
