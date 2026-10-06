"""Decode final printed QR pixels, independently of Dart's QR renderer."""
from pathlib import Path
import cv2
import fitz
import numpy as np

samples = [(Path(f'build/windows-id-previews/student_reference_{i}.pdf'), '"personId":"Class 8_Roll_24"') for i in range(4)]
samples += [(Path(f'build/reference-document-previews/teacherId_{i}.pdf'), 'VIDYA_SAARTHI_TEST_TEACHER') for i in range(4)]
samples += [(Path(f'build/reference-document-previews/manifest_{role.replace(" ", "_")}.pdf'), 'verified-test-id') for role in ('Student', 'Teacher', 'Other Staff')]
samples += [(Path(f'build/reference-document-previews/manifest_auth_{role}.pdf'), '"schoolId":"vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"') for role in ('student', 'teacher')]
for path, expected in samples:
    with fitz.open(path) as pdf:
        assert len(pdf) == 1, f'{path}: front and back must share one page'
        pixels = pdf[0].get_pixmap(dpi=300, alpha=False)
        image = np.frombuffer(pixels.samples, dtype=np.uint8).reshape(pixels.height, pixels.width, 3)
        detector = cv2.QRCodeDetector()
        detected, values, _, _ = detector.detectAndDecodeMulti(image)
        assert detected and any(expected in value for value in values), f'{path}: final 300 DPI QR cannot be decoded: {values}'
    print(f'PASS: final printed QR decodes at 300 DPI: {path.name}')
print(f'{len(samples)} ID QR scan assertions passed.')
