import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_template_forge_ocr.dart';

void main(){
  test('Windows release contains offline English and Indic OCR models',() async {
    final languages=await TemplateForgeOfflineOcr.installedLanguages();
    expect(languages,containsAll(['eng','hin','ben','asm']));
    expect(await TemplateForgeOfflineOcr.hasOrientationModel(),isTrue);
  });
}
