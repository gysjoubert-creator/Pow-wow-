package com.gys.powwow

import android.os.Bundle
import com.hiennv.flutter_callkit_incoming.CallkitEventCallback
import com.hiennv.flutter_callkit_incoming.FlutterCallkitIncomingPlugin
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {

    private val callkitEventCallback = object : CallkitEventCallback {
        override fun onCallEvent(event: CallkitEventCallback.CallEvent, callData: Bundle) {}
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        FlutterCallkitIncomingPlugin.registerEventCallback(callkitEventCallback)
    }

    override fun onDestroy() {
        // 1. super.onDestroy() triggers FlutterActivity → delegate.onDestroy()
        //    → plugin's onDetachedFromActivity() → FlutterCallkitIncomingPlugin.context = null
        super.onDestroy()

        FlutterCallkitIncomingPlugin.unregisterEventCallback(callkitEventCallback)

        // 2. Restore applicationContext so that the background FCM handler
        //    (running inside the live foreground-service process after the Activity
        //    is gone) can still call showCallkitIncoming().
        //
        //    Root cause: FlutterCallkitIncomingPlugin.onDetachedFromActivity() sets
        //    its private `context` field to null.  When firebase_messaging delivers
        //    a background message it creates a new Flutter engine in the same
        //    process; initSharedInstance() finds the existing singleton and skips
        //    updating `context`, so sendBroadcast() is called on a null reference
        //    and the incoming-call notification is never shown.
        restoreCallkitContext()
    }

    private fun restoreCallkitContext() {
        try {
            val plugin = FlutterCallkitIncomingPlugin.getInstance() ?: return
            val field = plugin.javaClass.getDeclaredField("context")
            field.isAccessible = true
            if (field.get(plugin) == null) {
                field.set(plugin, applicationContext)
            }
        } catch (_: Exception) {}
    }
}
