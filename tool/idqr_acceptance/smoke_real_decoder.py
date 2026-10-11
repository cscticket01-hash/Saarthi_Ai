"""Synthetic real-decoder PDF smoke; never substitutes for application export QA."""
import copy
import json
from pathlib import Path
import shutil
import subprocess

import fitz
import tempfile

from reportlab.graphics import renderPDF
from reportlab.graphics.barcode import code128, qr
from reportlab.graphics.shapes import Drawing
from reportlab.pdfgen import canvas

from verify_pdf import AcceptanceError, verify


PAGE_SIZE = (595.276, 841.89)


def synthetic_manifest(cards):
    return {'version': 1, 'schoolId': 'SYNTHETIC-A', 'pageSizesPt': [list(PAGE_SIZE)], 'cards': cards}


def card(index, box, payload):
    return {'schoolId': 'SYNTHETIC-A', 'studentId': f'synthetic-{index}', 'cardIssueId': f'issue-{index}',
            'side': 'front', 'page': 0, 'qrBoxPt': box, 'modules': 21, 'quietZoneModules': 4, 'qrPayload': payload}


def create_fixtures(directory):
    """Produce only synthetic identities; QR crop rectangles include quiet zones."""
    directory = Path(directory)
    qr_pdf = directory / 'synthetic-two-qr.pdf'
    pdf = canvas.Canvas(str(qr_pdf), pagesize=PAGE_SIZE, invariant=1)
    cards = []
    for index in range(2):
        payload = f'SYNTHETIC-{index}'
        left, top, side = 30 + index * 130, 40, 90
        symbol = qr.QrCodeWidget(payload, barLevel='L', barBorder=4, qrVersion=1)
        x0, y0, x1, y1 = symbol.getBounds()
        drawing = Drawing(side, side, transform=[side / (x1 - x0), 0, 0, side / (y1 - y0), 0, 0])
        drawing.add(symbol)
        renderPDF.draw(drawing, pdf, left, PAGE_SIZE[1] - top - side)
        cards.append(card(index, [left, top, left + side, top + side], payload))
    pdf.showPage()
    pdf.save()

    barcode_pdf = directory / 'synthetic-non-qr.pdf'
    pdf = canvas.Canvas(str(barcode_pdf), pagesize=PAGE_SIZE, invariant=1)
    payload = 'SYNTHETIC-0'
    left, top, side = 30, 40, 180
    barcode = code128.Code128(payload, barWidth=0.7, barHeight=50, quiet=True)
    barcode.drawOn(pdf, left + (side - barcode.width) / 2, PAGE_SIZE[1] - top - side / 2 - 25)
    pdf.showPage()
    pdf.save()
    negative = synthetic_manifest([card(0, [left, top, left + side, top + side], payload)])
    return qr_pdf, synthetic_manifest(cards), barcode_pdf, negative


def run_smoke(directory, decoder='zbarimg'):
    qr_pdf, manifest, barcode_pdf, negative = create_fixtures(directory)
    positive = verify(qr_pdf, manifest, decoder=decoder)
    if len(positive['checks']) != 6:
        raise AssertionError('Expected two actual QR symbols at three resolutions')
    # Prove the negative fixture really contains a decodable non-QR payload.
    barcode_png = Path(directory) / 'non-qr-control.png'
    with fitz.open(barcode_pdf) as document:
        document[0].get_pixmap(clip=fitz.Rect(negative['cards'][0]['qrBoxPt']), dpi=300, alpha=False).save(barcode_png)
    control = subprocess.run([decoder, '--quiet', '--raw', str(barcode_png)], capture_output=True, timeout=15, check=False)
    if control.returncode != 0 or control.stdout.decode('utf-8').splitlines() != [negative['cards'][0]['qrPayload']]:
        raise AssertionError('Non-QR negative fixture is not independently decodable')
    for label, path, expected in [
        ('matching-payload non-QR barcode', barcode_pdf, negative),
        ('last-card wrong identity', qr_pdf, copy.deepcopy(manifest)),
    ]:
        if label == 'last-card wrong identity':
            expected['cards'][-1]['qrPayload'] = 'WRONG-IDENTITY'
        try:
            verify(path, expected, decoder=decoder)
        except AcceptanceError:
            continue
        raise AssertionError(f'Invalid export accepted: {label}')
    return {'verdict': 'PASS', 'fixture': 'synthetic PDF only', 'realDecoder': decoder,
            'actualQrCount': 2, 'resolutionChecks': 6,
            'negativeChecks': ['non-QR fixture independently decoded by unrestricted control', 'matching-payload non-QR rejected', 'last-card identity mismatch rejected'],
            'applicationExportAcceptance': 'UNVERIFIED', 'physicalPrintAcceptance': 'UNVERIFIED'}


def main():
    if shutil.which('zbarimg') is None:
        print(json.dumps({'verdict': 'UNVERIFIED', 'reason': 'Real zbarimg decoder is unavailable'}))
        return 2
    try:
        with tempfile.TemporaryDirectory(prefix='idqr-real-decoder-') as directory:
            result = run_smoke(directory)
    except (AcceptanceError, AssertionError, OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({'verdict': 'FAIL', 'reason': str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
