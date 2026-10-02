import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/platform/github_updates.dart';

void main(){
  Map<String,dynamic> update()=>{'versionCode':473,'versionName':'1.0.473',
    'apkUrl':'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.473/Vidya-Saarthi-v1.0.473.apk',
    'sha256':List.filled(64,'a').join()};
  test('only this repository and the matching signed-APK release filename are accepted',(){
    validateAndroidUpdate(update());
    for(final changed in [
      {'apkUrl':'https://github.com/other/repo/releases/download/android-v1.0.473/Vidya-Saarthi-v1.0.473.apk'},
      {'versionCode':474},{'versionName':'windows-v2.1.80'},{'sha256':'invalid'},
      {'apkUrl':'https://github.com/cscticket01-hash/Saarthi_Ai/releases/download/android-v1.0.473/another.apk'},
    ]){expect(()=>validateAndroidUpdate({...update(),...changed}),throwsStateError);}
  });
}
