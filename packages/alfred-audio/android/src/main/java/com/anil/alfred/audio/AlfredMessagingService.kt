package com.anil.alfred.audio

import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * FCM entry point. Alfred sends data messages so the app shows them itself (channel, tag, tap) in every app state.
 */
class AlfredMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data.toMutableMap()
        // Android shows notification messages (e.g. from the Firebase console) itself only when the app is in the
        // background, so they're shown here in the foreground.
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
