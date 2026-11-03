import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import '../lib/id_card_layout.dart';

void main() {
  test('repeated print artwork shares PDF bytes without changing source or geometry', () async {
    final random = Random(85);
    final source = img.Image(width: 256, height: 256);
    for (final pixel in source) {
      pixel.r = random.nextInt(256);
      pixel.g = random.nextInt(256);
      pixel.b = random.nextInt(256);
    }
    final bytes = Uint8List.fromList(img.encodePng(source));
    final original = Uint8List.fromList(bytes);
    final providers = <String, pw.MemoryImage>{};
    Future<Uint8List> render(bool reuse) async {
      final pdf = pw.Document();
      pdf.addPage(pw.Page(build: (_) => pw.Wrap(children: [
        for (var index = 0; index < 12; index++)
          pw.SizedBox(width: 50, height: 50,
            child: IdCardLayout.image(bytes, imageCache: reuse ? providers : null)),
      ])));
      return pdf.save();
    }
    final separate = await render(false);
    final shared = await render(true);
    expect(providers.length, 1);
    expect(shared.length, lessThan(separate.length));
    expect(bytes, original);
    expect(String.fromCharCodes(shared.take(4)), '%PDF');
  });
}
