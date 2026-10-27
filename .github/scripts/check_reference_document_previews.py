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
    assert len(reader.pages) == 1
    width,height=map(float,reader.pages[0].mediabox[2:])
    assert abs(width-(((85.6 if index==2 else 54)*2+8)*72/25.4))<0.02
    assert abs(height-((54 if index==2 else 85.6)*72/25.4))<0.02
    assert 'ananyasharma' in text and 't-001' not in text
    for value in ['ranjitsharma', '12/03/1988', 'mathematics', 'teacherhome,sribhumi']:
        assert value in text, f'Missing teacher identity field: {value}'
    assert 'idnumber' not in text and 'idno.' not in text
    assert 'principalsignature' in text
reader, text = document('reportCard_0.pdf')
assert len(reader.pages) == 1
width,height=map(float,reader.pages[0].mediabox[2:])
assert abs(width-595.2756)<.02 and abs(height-841.8898)<.02
for subject in ['English', 'Mathematics', 'Science', 'Social Studies', 'Bengali', 'Hindi']:
    assert re.sub(r'\s+', '', subject).lower() in text
for value in ['arupdas','fullmarks','passmarks','marksobtained','percentage:85.50%','result:pass','600','198','513']:
    assert value in text, f'Missing actual report data: {value}'
for filename in ['reportCard_term2.pdf','reportCard_quarter2.pdf']:
    _, text=document(filename)
    assert 'english1003384-' in text, 'Selected exam must use Term/Quarter 2 marks'
    assert '84.00%' in text, 'Selected term percentage must reflect its marks'
    assert 'english1003311-' not in text, 'Term 1 marks leaked into Term 2'
reader, text = document('receipt_0.pdf')
for field in ['totalpaid:500', 'totaldue:700', 'amountpaid:500', 'subtotal:1200']:
    assert field in text, f'Incorrect installment receipt: {field}'
for kind, prefix in [('reportCard', 'subject'), ('receipt', 'fee')]:
    reader, text = document(f'{kind}_continuation.pdf')
    assert len(reader.pages) > 1
    for index in range(1, 26):
        assert f'{prefix}{index}' in text, f'Missing {prefix} {index} on continuation pages'
print('Reference PDF fields, installment amounts and continuation pages verified.')
