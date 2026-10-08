package com.vidyasaarthi.runtime

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.os.Process

/** Separate process: switching the default Firebase app cannot retain an old
 * project's Messaging singleton, installations token or background isolate. */
class SchoolRestartActivity : Activity() {
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val previous = intent.getIntExtra("previousPid", -1)
        if (previous > 0 && previous != Process.myPid()) Process.killProcess(previous)
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch != null) startActivity(launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        finish()
        Process.killProcess(Process.myPid())
    }
}
