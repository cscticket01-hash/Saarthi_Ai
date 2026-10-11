"""Bounded synthetic PDF/QR tool benchmark; no application acceptance claim."""
import argparse
import cProfile
import json
from pathlib import Path
import resource
import shutil
import tempfile
import time

from reportlab.graphics import renderPDF
from reportlab.graphics.barcode import qr
from reportlab.graphics.shapes import Drawing
from reportlab.pdfgen import canvas

from verify_pdf import AcceptanceError, decode_png, verify


MM = 72 / 25.4
PAGE = (210 * MM, 297 * MM)


def create_bulk_fixture(path, count):
    if type(count) is not int or not 1 <= count <= 500:
        raise ValueError('Synthetic student count must be1..500')
    pdf = canvas.Canvas(str(path), pagesize=PAGE, invariant=1)
    cards = []
    pages = []
    for index in range(count):
        if index % 9 == 0:
            if index:
                pdf.showPage()
            pages.append(list(PAGE))
        slot = index % 9
        row, column = divmod(slot, 3)
        left = (21 + column * 57) * MM
        top = (17.1 + row * 88.6) * MM
        card_width, card_height = 54 * MM, 85.6 * MM
        pdf.rect(left, PAGE[1] - top - card_height, card_width, card_height)
        student = f'S{index:04d}'
        payload = f'TEST-A-C1-{student}'
        pdf.setFont('Helvetica', 8)
        pdf.drawString(left + 4 * MM, PAGE[1] - top - 10 * MM, f'Synthetic Class1 / {student}')
        side = 28 * MM
        qr_left, qr_top = left + 13 * MM, top + 35 * MM
        symbol = qr.QrCodeWidget(payload, barLevel='L', barBorder=4, qrVersion=1)
        x0, y0, x1, y1 = symbol.getBounds()
        drawing = Drawing(side, side, transform=[side / (x1 - x0), 0, 0, side / (y1 - y0), 0, 0])
        drawing.add(symbol)
        renderPDF.draw(drawing, pdf, qr_left, PAGE[1] - qr_top - side)
        cards.append({'schoolId': 'SYNTHETIC-A', 'classId': 'SYNTHETIC-CLASS-1', 'studentId': student,
                      'cardIssueId': f'issue-{student}', 'side': 'front', 'page': len(pages) - 1,
                      'qrBoxPt': [qr_left, qr_top, qr_left + side, qr_top + side],
                      'modules': 21, 'quietZoneModules': 4, 'qrPayload': payload})
    pdf.showPage()
    pdf.save()
    return {'version': 1, 'schoolId': 'SYNTHETIC-A', 'pageSizesPt': pages, 'cards': cards}


def profile_seconds(profile, names):
    # cProfile reports actual measured cumulative time for matching Python APIs.
    import pstats
    return sum(stat[3] for key, stat in pstats.Stats(profile).stats.items() if key[2] in names)


def benchmark(directory, count, *, decode=decode_png, clock=time.perf_counter, budget_seconds=360):
    start = clock()
    pdf = Path(directory) / f'synthetic-{count}.pdf'
    manifest = create_bulk_fixture(pdf, count)
    generated = clock()
    decode_seconds = 0.0
    decode_calls = 0

    def measured_decode(path, decoder):
        nonlocal decode_seconds, decode_calls
        if clock() - start >= budget_seconds:
            raise AcceptanceError('Synthetic benchmark wall-time budget exceeded')
        before = clock()
        decoded = decode(path, decoder)
        decode_seconds += clock() - before
        decode_calls += 1
        return decoded

    profile = cProfile.Profile()
    result = profile.runcall(verify, pdf, manifest, decode=measured_decode)
    finished = clock()
    if finished - start > budget_seconds:
        raise AcceptanceError('Synthetic benchmark wall-time budget exceeded')
    if result['cardCount'] != count or len(result['checks']) != count * 3 or decode_calls != count * 3:
        raise AssertionError('Incomplete synthetic class coverage')
    return {'verdict': 'PASS', 'scope': 'Synthetic single-front PDF and verifier only; not application bulk export',
            'studentCount': count, 'classId': 'SYNTHETIC-CLASS-1', 'pageCount': len(manifest['pageSizesPt']),
            'cardCount': result['cardCount'], 'resolutionDpi': [150, 300, 600], 'decodeCount': decode_calls,
            'pdfBytes': pdf.stat().st_size, 'pdfSha256': result['pdfSha256'],
            'generationWallSeconds': generated - start, 'verificationWallSeconds': finished - generated,
            'totalWallSeconds': finished - start, 'decoderWallSeconds': decode_seconds,
            'profileGetPixmapSeconds': profile_seconds(profile, {'get_pixmap'}),
            'profilePngSaveSeconds': profile_seconds(profile, {'save'}),
            'parentPeakRssKiB': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            'childPeakRssKiB': resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss,
            'memoryScope': 'Linux process-lifetime parent and maximum child high-water RSS; not simultaneous summed memory',
            'timingScope': 'cProfile API attribution includes profiler overhead; verify wall includes validation, raster, PNG, decode and IO',
            'applicationExportAcceptance': 'UNVERIFIED', 'physicalPrintAcceptance': 'UNVERIFIED'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--count', type=int, choices=(50, 100, 500), required=True)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if shutil.which('zbarimg') is None:
        report, code = {'verdict': 'UNVERIFIED', 'reason': 'Real zbarimg decoder is unavailable'}, 2
    else:
        try:
            with tempfile.TemporaryDirectory(prefix='idqr-synthetic-bulk-') as directory:
                report = benchmark(directory, args.count)
            code = 0
        except (AcceptanceError, AssertionError, OSError, RuntimeError, ValueError) as error:
            report, code = {'verdict': 'FAIL', 'scope': 'Synthetic PDF/verifier only', 'reason': str(error)}, 1
    rendered = json.dumps(report)
    if args.report:
        args.report.write_text(rendered + '\n')
    print(rendered)
    return code


if __name__ == '__main__':
    raise SystemExit(main())
