package APP_NAMESPACE

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import com.google.firebase.FirebaseApp
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        MethodChannel(engine.dartExecutor.binaryMessenger, "vidyasaarthi/school_messaging")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "prepare" -> {
                        val data = call.arguments as? Map<*, *>
                        val project = data?.get("projectId") as? String
                        val sender = data?.get("messagingSenderId") as? String
                        val appId = data?.get("appId") as? String
                        val apiKey = data?.get("apiKey") as? String
                        if (project == null || sender == null || appId == null || apiKey == null ||
                            !project.matches(Regex("^[a-z][a-z0-9-]{4,61}[a-z0-9]$")) ||
                            !sender.matches(Regex("^[0-9]+$")) || !appId.startsWith("1:$sender:android:") ||
                            !apiKey.startsWith("AIza")) {
                            result.error("SCHOOL_CONFIG", "Invalid school Firebase configuration", null)
                        } else {
                            val current = FirebaseApp.getApps(applicationContext)
                                .firstOrNull { it.name == FirebaseApp.DEFAULT_APP_NAME }?.options
                            val saved = getSharedPreferences("saarthi_school_firebase", Context.MODE_PRIVATE)
                                .edit().putString("projectId", project).putString("appId", appId)
                                .putString("messagingSenderId", sender).putString("apiKey", apiKey).commit()
                            if (!saved) result.error("SCHOOL_CONFIG", "Could not save school configuration", null)
                            else result.success(current != null &&
                                (current.projectId != project || current.applicationId != appId || current.apiKey != apiKey))
                        }
                    }
                    "restart" -> {
                        result.success(null)
                        Handler(Looper.getMainLooper()).postDelayed({
                            startActivity(Intent(this, com.vidyasaarthi.runtime.SchoolRestartActivity::class.java)
                                .putExtra("previousPid", Process.myPid()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        }, 250)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
