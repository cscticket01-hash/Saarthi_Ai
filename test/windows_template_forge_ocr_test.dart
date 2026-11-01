import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_template_forge_ocr.dart';

void main(){
  test('Windows release contains offline English and Indic OCR models',() async {
    const bundle=String.fromEnvironment('TEMPLATEFORGE_BUNDLE_DIR');
    expect(bundle,isNotEmpty,
      reason:'CI must point this test at the actual packaged OCR runtime.');
    final languages=await TemplateForgeOfflineOcr.installedLanguages();
    expect(languages,containsAll(['eng','hin','ben','asm']));
    expect(await TemplateForgeOfflineOcr.hasOrientationModel(),isTrue);
  });
}
