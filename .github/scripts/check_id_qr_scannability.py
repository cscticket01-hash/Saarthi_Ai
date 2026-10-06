"""Decode final printed QR pixels, independently of Dart's QR renderer."""
from pathlib import Path
import zxingcpp
import fitz
import numpy as np

samples = [(Path(f'build/windows-id-previews/student_reference_{i}.pdf'), '"personId":"Class 8_Roll_24"') for i in range(4)]
samples += [(Path(f'build/reference-document-previews/teacherId_{i}.pdf'), 'VIDYA_SAARTHI_TEST_TEACHER') for i in range(4)]
samples += [(Path(f'build/reference-document-previews/manifest_{role.replace(" ", "_")}.pdf'), 'verified-test-id') for role in ('Student', 'Teacher', 'Other Staff')]
samples += [(Path(f'build/reference-document-previews/manifest_auth_{role}.pdf'), 'VS3|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa|') for role in ('student', 'teacher')]
for path, expected in samples:
    with fitz.open(path) as pdf:
        assert len(pdf) == 1, f'{path}: front and back must share one page'
        pixels = pdf[0].get_pixmap(dpi=300, alpha=False)
        image = np.frombuffer(pixels.samples, dtype=np.uint8).reshape(pixels.height, pixels.width, 3)
        png=Path('build/id-final-rasters') / (path.stem+'.png')
        png.parent.mkdir(parents=True,exist_ok=True)
        pixels.save(str(png))
        values = [code.text for code in zxingcpp.read_barcodes(image) if code.format == zxingcpp.BarcodeFormat.QRCode]
        assert any(expected in value for value in values), f'{path}: final 300 DPI QR cannot be decoded: {values}'
    print(f'PASS: final printed QR decodes at 300 DPI: {path.name}')
print(f'{len(samples)} ID QR scan assertions passed.')
