package com.anil.jarvis;

import android.content.Intent;
import android.os.Bundle;
import com.anil.alfred.audio.ServerSettings;
import com.getcapacitor.BridgeActivity;

// Loads the page from the saved address (ServerSettings) rather than only capacitor.config.json's, and handles
// the "Change server" launcher shortcut.
public class MainActivity extends BridgeActivity {

    static final String ACTION_SETUP = "com.anil.jarvis.SETUP"; // res/xml/shortcuts.xml

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        takeSetupRequest(getIntent());
        config = ServerSettings.config(this);
        super.onCreate(savedInstanceState);
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (takeSetupRequest(intent)) recreate();
    }

    private boolean takeSetupRequest(Intent intent) {
        if (intent == null || !ACTION_SETUP.equals(intent.getAction())) return false;
        ServerSettings.requestSetup(this);
        intent.setAction(Intent.ACTION_MAIN); // recreating the activity mustn't ask again
        return true;
    }
}
