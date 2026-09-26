package com.httpanimations.moat

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : FlutterFragmentActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onStart() {
        super.onStart()
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
            as? WifiManager
        multicastLock = wifi
            ?.createMulticastLock("moat-sync")
            ?.apply { setReferenceCounted(true); acquire() }
    }

    override fun onStop() {
        multicastLock?.takeIf { it.isHeld }?.release()
        multicastLock = null
        super.onStop()
    }
}
