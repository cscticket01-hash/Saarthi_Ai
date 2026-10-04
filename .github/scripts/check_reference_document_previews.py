"""Check rendered PDF data independently of the Dart implementation."""
import re
from pathlib import Path
from pypdf import PdfReader
root = Path('build/reference-document-previews')
def document(name):
    reader = PdfReader(root / name)
    text = ''.join(page.extract_text() or '' for page in reader.pages)
    normalized = re.sub(r'\s+', '', text).lower()
    assert 'officetemplates' not in normalized
    assert 'michael' not in normalized
    assert 'jessica' not in normalized
    return reader, normalized
for index in range(4):
    reader, text = document(f'teacherId_{index}.pdf')
    assert len(reader.pages) == 2
    assert 'ananyasharma' in text and 't-001' in text
    assert 'principalsignature' in text
    if index == 2:
        assert 'expiration' in text, 'Cyan card must not clip its last detail row'
    reader, text = document(f'reportCard_{index}.pdf')
    assert len(reader.pages) == 1
    assert tuple(float(v) for v in reader.pages[0].mediabox[2:]) == (612, 792)
    for subject in ['English', 'Mathematics', 'Science', 'Social Studies', 'Bengali', 'Hindi']:
        assert re.sub(r'\s+', '', subject).lower() in text
    assert 'arupdas' in text
    if index == 3:
        assert 'behavior:-' in text, 'Burgundy report must include all four behavior fields'
reader, text = document('receipt_0.pdf')
for field in ['totalpaid:500', 'totaldue:700', 'amountpaid:500', 'subtotal:1200']:
    assert field in text, f'Incorrect installment receipt: {field}'
for kind, prefix in [('reportCard', 'subject'), ('receipt', 'fee')]:
    reader, text = document(f'{kind}_continuation.pdf')
    assert len(reader.pages) > 1
    for index in range(1, 26):
        assert f'{prefix}{index}' in text, f'Missing {prefix} {index} on continuation pages'
print('Reference PDF fields, installment amounts and continuation pages verified.')
