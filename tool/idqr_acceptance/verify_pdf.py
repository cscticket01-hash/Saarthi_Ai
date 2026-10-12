"""Read-only, fail-closed final-PDF QR acceptance. No application integration."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import fitz


class AcceptanceError(ValueError):
    pass


def _decode_original_qr_inprocess(path):
    try:
        import zxingcpp
        from PIL import Image
    except ImportError as error:
        raise AcceptanceError('Independent QR fallback unavailable') from error
    try:
        with Image.open(path) as image:
            symbols = zxingcpp.read_barcodes(image.convert('RGB'), formats=zxingcpp.BarcodeFormat.QRCode)
        return [symbol.text for symbol in symbols]
    except Exception as error:
        raise AcceptanceError('Independent original-raster QR decoder failed') from error


def decode_original_qr_fallback(path):
    # Native ZXing runs in a disposable process: its timeout can actually stop
    # decoding, unlike a cooperative deadline around an in-process native call.
    try:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve()), '--fallback-worker', str(path)],
            capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AcceptanceError('Independent QR fallback unavailable or timed out') from error
    if result.returncode != 0:
        raise AcceptanceError('Independent original-raster QR decoder failed')
    if len(result.stdout) > 1048576:
        raise AcceptanceError('Independent QR fallback output exceeds safety bound')
    try:
        values = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError) as error:
        raise AcceptanceError('Independent QR fallback returned invalid output') from error
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        raise AcceptanceError('Independent QR fallback returned invalid symbols')
    return values


def positive_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value > 0


def validate_manifest(manifest, document):
    if not isinstance(manifest, dict):
        raise AcceptanceError('Manifest object required')
    if manifest.get('version') != 1:
        raise AcceptanceError('Unsupported manifest version')
    school = manifest.get('schoolId')
    cards = manifest.get('cards')
    sizes = manifest.get('pageSizesPt')
    if not isinstance(school, str) or not school or not isinstance(cards, list) or not cards:
        raise AcceptanceError('School and nonempty card inventory required')
    if not isinstance(sizes, list) or len(sizes) != len(document):
        raise AcceptanceError('Every PDF page requires an expected physical size')
    for index, size in enumerate(sizes):
        if not isinstance(size, list) or len(size) != 2 or not all(positive_number(v) for v in size):
            raise AcceptanceError('Invalid expected page size')
        page = document[index]
        if page.rotation != 0 or any(abs(actual - expected) > 0.1 for actual, expected in zip((page.rect.width, page.rect.height), size)):
            raise AcceptanceError('Page geometry differs from manifest')
    keys = set()
    issues = {}
    boxes = {}
    for card in cards:
        if not isinstance(card, dict) or card.get('schoolId') != school:
            raise AcceptanceError('Foreign or malformed card')
        for field in ('studentId', 'cardIssueId', 'qrPayload'):
            if not isinstance(card.get(field), str) or not card[field]:
                raise AcceptanceError('Missing card identity/payload')
        if card.get('side') not in ('front', 'back'):
            raise AcceptanceError('Explicit front/back side required')
        issue_student = issues.setdefault(card['cardIssueId'], card['studentId'])
        if issue_student != card['studentId']:
            raise AcceptanceError('Card issue maps to multiple students')
        key = (card['cardIssueId'], card['side'])
        if key in keys:
            raise AcceptanceError('Duplicate card issue and side')
        keys.add(key)
        page_index = card.get('page')
        if type(page_index) is not int or not 0 <= page_index < len(document):
            raise AcceptanceError('Invalid zero-based page')
        box = card.get('qrBoxPt')
        if not isinstance(box, list) or len(box) != 4 or any(not isinstance(v, (int, float)) or isinstance(v, bool) or not math.isfinite(v) for v in box):
            raise AcceptanceError('Invalid QR box')
        rect = fitz.Rect(box)
        if rect.is_empty or not document[page_index].rect.contains(rect):
            raise AcceptanceError('QR is outside page or empty')
        for other in boxes.setdefault(page_index, []):
            if not (rect & other).is_empty:
                raise AcceptanceError('Overlapping QR boxes')
        boxes[page_index].append(rect)
        modules = card.get('modules')
        quiet = card.get('quietZoneModules')
        if type(modules) is not int or not 21 <= modules <= 177 or (modules - 21) % 4:
            raise AcceptanceError('Invalid QR matrix dimensions')
        if type(quiet) is not int or quiet < 4:
            raise AcceptanceError('QR quiet zone below four modules')
        if abs(rect.width - rect.height) > 0.1:
            raise AcceptanceError('Non-square QR region')
        module_mm = min(rect.width, rect.height) * 25.4 / 72 / (modules + 2 * quiet)
        if module_mm < 0.25:
            raise AcceptanceError('QR module below 0.25mm geometry floor')
    non_qr = manifest.get('nonQrPages', [])
    if not isinstance(non_qr, list) or any(type(i) is not int or not 0 <= i < len(document) for i in non_qr) or len(set(non_qr)) != len(non_qr) or set(non_qr) & set(boxes):
        raise AcceptanceError('Invalid or overlapping explicit non-QR page inventory')
    if set(boxes) | set(non_qr) != set(range(len(document))):
        raise AcceptanceError('PDF contains pages absent from card inventory')


def decode_png(path, decoder, *, on_fallback=None, allow_fallback=True):
    try:
        result = subprocess.run([decoder, '--quiet', '--raw', '--set', 'disable', '--set', 'qrcode.enable', str(path)], capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AcceptanceError('QR decoder unavailable or timed out') from error
    if result.returncode == 4 and allow_fallback and not result.stdout.strip():
        # zbar's no-symbol result only: never override decoded identities or other errors.
        started = time.perf_counter()
        values = decode_original_qr_fallback(path)
        if on_fallback is not None:
            on_fallback(time.perf_counter() - started)
        return values
    if result.returncode != 0:
        raise AcceptanceError(f'QR decoder failed with exit code {result.returncode}')
    try:
        return result.stdout.decode('utf-8').splitlines()
    except UnicodeDecodeError as error:
        raise AcceptanceError('QR decoder returned invalid UTF-8') from error


def verify(pdf_path, manifest, *, dpis=(150, 300, 600), decoder='zbarimg', decode=decode_png):
    if len(set(dpis)) < 2 or any(type(dpi) is not int or not 72 <= dpi <= 1200 for dpi in dpis):
        raise AcceptanceError('At least two distinct bounded integer resolutions required')
    checks = []
    with fitz.open(pdf_path) as document:
        validate_manifest(manifest, document)
        with tempfile.TemporaryDirectory(prefix='idqr-verification-') as directory:
            for index, card in enumerate(manifest['cards']):
                for dpi in dpis:
                    output = Path(directory) / f'{index}-{dpi}.png'
                    document[card['page']].get_pixmap(clip=fitz.Rect(card['qrBoxPt']), dpi=dpi, alpha=False).save(output)
                    try:
                        decoded = decode(output, decoder)
                    except AcceptanceError as error:
                        raise AcceptanceError(f'Card inventory index {index}, {dpi} DPI: {error}') from error
                    if decoded != [card['qrPayload']]:
                        raise AcceptanceError(f'QR identity mismatch or unreadable card at inventory index {index}, {dpi} DPI')
                    checks.append({'cardIndex': index, 'dpi': dpi, 'status': 'PASS'})
    return {'verdict': 'PASS', 'pdfSha256': hashlib.sha256(Path(pdf_path).read_bytes()).hexdigest(),
            'cardCount': len(manifest['cards']), 'checks': checks,
            'decoderPolicy': 'QR-only zbar; exit4 no-symbol only allows QR-only ZXing on original unchanged raster in a process with a 15-second hard timeout; exactly one expected payload required',
            'declaredNonQrPages': manifest.get('nonQrPages', []),
            'scope': 'Declared non-QR pages are geometry checked, not independently proven free of QR; declared QR regions decoded at every requested resolution; physical printing, complete inventory provenance, text shaping and visual contrast remain UNVERIFIED.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('pdf', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--decoder', default='zbarimg')
    args = parser.parse_args()
    try:
        report = verify(args.pdf, json.loads(args.manifest.read_text()), decoder=args.decoder)
    except (AcceptanceError, ValueError, RuntimeError, OSError) as error:
        print(json.dumps({'verdict': 'FAIL', 'reason': str(error)}))
        return 1
    print(json.dumps(report))
    return 0


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == '--fallback-worker':
        try:
            print(json.dumps(_decode_original_qr_inprocess(Path(sys.argv[2]))))
        except Exception:
            # Parent owns diagnostics; never print raster contents or QR payloads.
            raise SystemExit(1)
    else:
        raise SystemExit(main())
