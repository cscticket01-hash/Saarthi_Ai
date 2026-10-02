package com.vidyasaarthi.runtime

import android.app.Application
import android.os.Build
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging

/** Initialise the DEFAULT Messaging app from this device's selected school,
 * before Flutter or a background messaging isolate starts. */
class SchoolApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 28 && getProcessName().endsWith(":school_restart")) return
        val prefs = getSharedPreferences("saarthi_school_firebase", MODE_PRIVATE)
        val project = prefs.getString("projectId", null) ?: return
        val appId = prefs.getString("appId", null) ?: return
        val sender = prefs.getString("messagingSenderId", null) ?: return
        val key = prefs.getString("apiKey", null) ?: return
        if (!appId.startsWith("1:$sender:android:")) return
        val options = FirebaseOptions.Builder().setProjectId(project).setApplicationId(appId)
            .setGcmSenderId(sender).setApiKey(key).build()
        FirebaseApp.initializeApp(this, options)
        FirebaseMessaging.getInstance().isAutoInitEnabled = false
    }
}
