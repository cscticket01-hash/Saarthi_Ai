"""Install the universal app's school-specific Android Firebase bootstrap."""
from pathlib import Path
import re
import shutil

app = Path('android/app')
gradle = app / 'build.gradle.kts'
kotlin = gradle.exists()
if not kotlin:
    gradle = app / 'build.gradle'
source = gradle.read_text()
namespace = re.search(r'namespace\s*(?:=\s*)?[\'"]([^\'"]+)', source)
if not namespace:
    raise SystemExit('Android namespace is missing')
namespace = namespace.group(1)
main = app / 'src/main/kotlin' / Path(*namespace.split('.')) / 'MainActivity.kt'
main.parent.mkdir(parents=True, exist_ok=True)
main.write_text(Path('.github/android/MainActivity.kt').read_text().replace('APP_NAMESPACE', namespace))
runtime = app / 'src/main/kotlin/com/vidyasaarthi/runtime'
runtime.mkdir(parents=True, exist_ok=True)
for name in ['SchoolApplication.kt', 'SchoolRestartActivity.kt']:
    shutil.copyfile(Path('.github/android') / name, runtime / name)
if 'firebase-messaging' not in source:
    dependencies = ('implementation(platform("com.google.firebase:firebase-bom:32.8.1"))\n'
                    '    implementation("com.google.firebase:firebase-messaging")' if kotlin else
                    'implementation platform("com.google.firebase:firebase-bom:32.8.1")\n'
                    '    implementation "com.google.firebase:firebase-messaging"')
    gradle.write_text(source + '\ndependencies {\n    ' + dependencies + '\n}\n')
manifest = app / 'src/main/AndroidManifest.xml'
text = manifest.read_text()
if 'xmlns:tools=' not in text:
    text = text.replace('<manifest', '<manifest xmlns:tools="http://schemas.android.com/tools"', 1)
text, n = re.subn(r'(<application\b[^>]*\bandroid:name=)[\'"][^\'"]+[\'"]',
                  r'\1"com.vidyasaarthi.runtime.SchoolApplication"', text, count=1)
if n != 1:
    raise SystemExit('Android application class could not be configured')
if 'com.google.firebase.provider.FirebaseInitProvider' not in text:
    text = text.replace('</application>', '''
        <provider android:name="com.google.firebase.provider.FirebaseInitProvider"
            android:authorities="${applicationId}.firebaseinitprovider" tools:node="remove" />
        <meta-data android:name="firebase_messaging_auto_init_enabled" android:value="false" />
        <meta-data android:name="firebase_analytics_collection_enabled" android:value="false" />
        <activity android:name="com.vidyasaarthi.runtime.SchoolRestartActivity"
            android:exported="false" android:process=":school_restart"
            android:theme="@android:style/Theme.Translucent.NoTitleBar" />
    </application>''')
manifest.write_text(text)
print('Universal school Firebase bootstrap configured')
