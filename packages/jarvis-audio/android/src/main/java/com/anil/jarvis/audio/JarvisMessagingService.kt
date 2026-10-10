package com.anil.jarvis.audio

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * Firebase Cloud Messaging's way into the app: JARVIS's pushes, which come as data messages so the app shows them
 * itself (its channel, its tag, its tap), with the app on screen, in the background or not running; and a new
 * registration token, which goes to the Mac. The rest is [PushNotifications].
 */
class JarvisMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data.toMutableMap()
        // A notification message (from the Firebase console, say) while the app is on screen: Android shows those
        // itself only when it isn't.
        message.notification?.let { n ->
            n.title?.let { data.putIfAbsent("title", it) }
            n.body?.let { data.putIfAbsent("body", it) }
        }
        if (data["title"] == null && data["body"] == null) return
        PushNotifications.show(this, data)
    }

    override fun onNewToken(token: String) {
        PushNotifications.tokenChanged(token)
    }
}
