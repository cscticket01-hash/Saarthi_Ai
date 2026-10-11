import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

import fitz
from verify_pdf import AcceptanceError, decode_png, verify


class FinalPdfAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / 'synthetic.pdf'
        with fitz.open() as pdf:
            page = pdf.new_page(width=595.276, height=841.89)
            page.draw_rect(fitz.Rect(20, 20, 110, 110), color=(0, 0, 0))
            page.draw_rect(fitz.Rect(130, 20, 220, 110), color=(0, 0, 0))
            pdf.save(self.path)
        self.manifest = {'version': 1, 'schoolId': 'SYNTHETIC-A', 'pageSizesPt': [[595.276, 841.89]], 'cards': [
            {'schoolId': 'SYNTHETIC-A', 'studentId': str(i), 'cardIssueId': f'issue-{i}', 'side': 'front', 'page': 0,
             'qrBoxPt': [20 + i * 110, 20, 110 + i * 110, 110], 'modules': 21, 'quietZoneModules': 4,
             'qrPayload': f'synthetic-identity-{i}'} for i in range(2)]}

    def tearDown(self):
        self.temporary.cleanup()

    def test_explicit_non_qr_pages_require_disjoint_exhaustive_geometry_inventory(self):
        extended = self.path.with_name('with-front.pdf')
        with fitz.open(self.path) as document:
            document.new_page(width=595.276, height=841.89)
            document.save(extended)
        manifest = copy.deepcopy(self.manifest)
        manifest['pageSizesPt'].append([595.276, 841.89])
        seam = lambda path, _: [f'synthetic-identity-{path.name.split("-")[0]}']
        with self.assertRaises(AcceptanceError):
            verify(extended, manifest, decode=seam)
        manifest['nonQrPages'] = [1]
        report = verify(extended, manifest, decode=seam)
        self.assertEqual(report['declaredNonQrPages'], [1])
        self.assertEqual(len(report['checks']), 6)
        for invalid in ([0], [1, 1], [True], [2], '1'):
            with self.subTest(invalid=invalid), self.assertRaises(AcceptanceError):
                verify(extended, {**manifest, 'nonQrPages': invalid}, decode=seam)

    def test_every_card_every_resolution_rendered(self):
        captured = []
        def seam(path, decoder):
            image = fitz.Pixmap(path)
            captured.append((path.name, image.width, image.height))
            return [f'synthetic-identity-{path.name.split("-")[0]}']
        report = verify(self.path, self.manifest, decode=seam)
        self.assertEqual(len(report['checks']), 6)
        self.assertEqual(len({width for _, width, _ in captured}), 3)
        self.assertTrue(all(width == height for _, width, height in captured))
        self.assertEqual(len(report['pdfSha256']), 64)

    def test_last_card_wrong_identity_rejected(self):
        with self.assertRaises(AcceptanceError):
            verify(self.path, self.manifest, decode=lambda path, _: ['synthetic-identity-0'])

    def test_multiple_symbols_rejected(self):
        with self.assertRaises(AcceptanceError):
            verify(self.path, self.manifest, decode=lambda path, _: ['synthetic-identity-0', 'foreign'])

    def test_geometry_school_and_inventory_fail_closed(self):
        mutations = [
            lambda m: m['pageSizesPt'][0].__setitem__(0, 600),
            lambda m: m['cards'][1].__setitem__('schoolId', 'OTHER'),
            lambda m: m['cards'][1].__setitem__('qrBoxPt', [20, 20, 110, 110]),
            lambda m: m['cards'][1].__setitem__('qrBoxPt', [-1, 20, 89, 110]),
            lambda m: m['cards'][1].__setitem__('quietZoneModules', 3),
            lambda m: m['cards'][1].__setitem__('modules', 22),
            lambda m: m['cards'][1].__setitem__('qrBoxPt', [130, 20, 135, 25]),
            lambda m: m['cards'][1].__setitem__('page', True),
            lambda m: m.__setitem__('cards', []),
            lambda m: m['cards'].__setitem__(1, copy.deepcopy(m['cards'][0])),
        ]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                manifest = copy.deepcopy(self.manifest)
                mutation(manifest)
                with self.assertRaises(AcceptanceError):
                    verify(self.path, manifest, decode=lambda *_: self.fail('Decode before validation'))

    def test_issue_identity_cannot_change_on_back(self):
        self.manifest['cards'][1]['cardIssueId'] = 'issue-0'
        self.manifest['cards'][1]['side'] = 'back'
        with self.assertRaisesRegex(AcceptanceError, 'multiple students'):
            verify(self.path, self.manifest)

    def test_manifest_root_must_be_object(self):
        with self.assertRaises(AcceptanceError):
            verify(self.path, [])

    def test_synthetic_smoke_fixtures_have_expected_inventory_and_geometry(self):
        from smoke_real_decoder import create_fixtures
        from verify_pdf import validate_manifest
        positive, manifest, negative, negative_manifest = create_fixtures(self.temporary.name)
        self.assertEqual(len(manifest['cards']), 2)
        self.assertEqual(len(negative_manifest['cards']), 1)
        self.assertEqual(manifest['cards'][0]['qrPayload'], negative_manifest['cards'][0]['qrPayload'])
        for path, expected in [(positive, manifest), (negative, negative_manifest)]:
            with fitz.open(path) as document:
                validate_manifest(expected, document)
                self.assertEqual(len(document), 1)

    def test_bulk_fixture_50_class_students_have_valid_a4_geometry(self):
        from benchmark_synthetic_bulk import create_bulk_fixture
        from verify_pdf import validate_manifest
        path = Path(self.temporary.name) / 'bulk.pdf'
        manifest = create_bulk_fixture(path, 50)
        self.assertEqual(len(manifest['cards']), 50)
        self.assertEqual(len(manifest['pageSizesPt']), 6)
        self.assertEqual(len({c['studentId'] for c in manifest['cards']}), 50)
        self.assertEqual({c['classId'] for c in manifest['cards']}, {'SYNTHETIC-CLASS-1'})
        with fitz.open(path) as document:
            validate_manifest(manifest, document)

    def test_synthetic_bulk_benchmark_measures_every_card_and_resolution(self):
        from benchmark_synthetic_bulk import benchmark
        def decode(path, decoder):
            index = int(path.name.split('-')[0])
            return [f'TEST-A-C1-S{index:04d}']
        report = benchmark(self.temporary.name, 10, decode=decode)
        self.assertEqual(report['decodeCount'], 30)
        self.assertEqual(report['pageCount'], 2)
        self.assertGreater(report['pdfBytes'], 0)
        self.assertGreater(report['totalWallSeconds'], 0)
        self.assertGreater(report['profileGetPixmapSeconds'], 0)
        self.assertGreater(report['profilePngSaveSeconds'], 0)
        self.assertEqual(report['applicationExportAcceptance'], 'UNVERIFIED')

    def test_decoder_failure_reports_index_dpi_and_preserves_synthetic_crop(self):
        from benchmark_synthetic_bulk import benchmark
        diagnostic = Path(self.temporary.name) / 'diagnostic'
        def decode(path, decoder):
            if path.name == '1-150.png':
                raise AcceptanceError('injected decoder failure')
            return [f'TEST-A-C1-S{int(path.name.split("-")[0]):04d}']
        with self.assertRaisesRegex(AcceptanceError, 'index 1, 150 DPI'):
            benchmark(self.temporary.name, 2, decode=decode, diagnostic_directory=diagnostic)
        self.assertTrue((diagnostic / 'failed-1-150.png').exists())
        context = json.loads((diagnostic / 'failure-context.json').read_text())
        self.assertEqual(context['inventoryIndex'], 1)
        self.assertEqual(context['dpi'], 150)
        self.assertNotIn('qrPayload', context)

    def test_failed_raster_resizing_is_diagnostic_only_and_exact_identity_checked(self):
        from benchmark_synthetic_bulk import diagnose_failed_raster
        from PIL import Image
        raster = Path(self.temporary.name) / 'failure.png'
        Image.new('RGB', (662, 663), 'white').save(raster)
        report = diagnose_failed_raster(raster, 'EXPECTED', self.temporary.name, decode=lambda *_: ['FOREIGN'])
        self.assertEqual([r['width'] for r in report['resizedZbarChecks']], [256, 384, 512])
        self.assertTrue(all(not r['exactExpectedIdentity'] for r in report['resizedZbarChecks']))
        self.assertIn('stays FAIL', report['scope'])
        self.assertEqual(report['sourcePixels'], [662, 663])

    def test_bulk_benchmark_rejects_expired_wall_budget(self):
        from benchmark_synthetic_bulk import benchmark
        with self.assertRaisesRegex(AcceptanceError, 'budget'):
            benchmark(self.temporary.name, 1, budget_seconds=0, decode=lambda *_: [])

    def test_bulk_benchmark_does_not_accept_wrong_last_student(self):
        from benchmark_synthetic_bulk import benchmark
        def decode(path, decoder):
            index = int(path.name.split('-')[0])
            return [f'TEST-A-C1-S{index:04d}' if index != 9 else 'WRONG']
        with self.assertRaises(AcceptanceError):
            benchmark(self.temporary.name, 10, decode=decode)

    def test_all_pdf_pages_must_be_in_inventory(self):
        with fitz.open(self.path) as pdf:
            pdf.new_page(width=595.276, height=841.89)
            pdf.save(self.path, incremental=True, encryption=fitz.PDF_ENCRYPT_KEEP)
        self.manifest['pageSizesPt'].append([595.276, 841.89])
        with self.assertRaises(AcceptanceError):
            verify(self.path, self.manifest)

    def test_single_or_invalid_resolution_rejected(self):
        for dpis in [(300,), (300, 300), (True, 300), (300, 1201)]:
            with self.subTest(dpis=dpis), self.assertRaises(AcceptanceError):
                verify(self.path, self.manifest, dpis=dpis)

    def test_decoder_enables_only_qr_symbology(self):
        # Matching data in another barcode must never count as QR acceptance.
        completed = subprocess.CompletedProcess([], 0, stdout=b'expected-payload\n', stderr=b'')
        with patch('verify_pdf.subprocess.run', return_value=completed) as run:
            self.assertEqual(decode_png(Path('synthetic.png'), 'zbarimg'), ['expected-payload'])
        run.assert_called_once_with(
            ['zbarimg', '--quiet', '--raw', '--set', 'disable', '--set', 'qrcode.enable', 'synthetic.png'],
            capture_output=True, timeout=15, check=False)

    def test_no_symbol_fallback_uses_original_raster_qr_only(self):
        from PIL import Image
        path = Path(self.temporary.name) / 'original-600.png'
        Image.new('RGB', (662, 663), 'white').save(path)
        captured = []
        def read(image, *, formats):
            captured.append((image.size, formats))
            return [SimpleNamespace(text='EXPECTED')]
        zxing = SimpleNamespace(read_barcodes=read, BarcodeFormat=SimpleNamespace(QRCode='QR_ONLY'))
        no_symbol = subprocess.CompletedProcess([], 4, stdout=b'', stderr=b'')
        measured = []
        with patch('verify_pdf.subprocess.run', return_value=no_symbol), patch('verify_pdf.decode_original_qr_fallback', side_effect=lambda p: __import__('verify_pdf')._decode_original_qr_inprocess(p)), patch.dict('sys.modules', {'zxingcpp': zxing}):
            self.assertEqual(decode_png(path, 'zbarimg', on_fallback=measured.append), ['EXPECTED'])
        self.assertEqual(captured, [((662, 663), 'QR_ONLY')])
        self.assertEqual(len(measured), 1)

    def test_missing_fallback_decoder_fails_closed(self):
        no_symbol = subprocess.CompletedProcess([], 4, stdout=b'', stderr=b'')
        with patch('verify_pdf.subprocess.run', return_value=no_symbol), patch('verify_pdf.decode_original_qr_fallback', side_effect=lambda p: __import__('verify_pdf')._decode_original_qr_inprocess(p)), patch.dict('sys.modules', {'zxingcpp': None}):
            with self.assertRaisesRegex(AcceptanceError, 'fallback unavailable'):
                decode_png(Path('original.png'), 'zbarimg')

    def test_fallback_process_has_hard_deadline_and_sanitizes_timeout(self):
        from verify_pdf import decode_original_qr_fallback
        with patch('verify_pdf.subprocess.run', side_effect=subprocess.TimeoutExpired('private-payload', 15)) as run:
            with self.assertRaisesRegex(AcceptanceError, 'timed out') as failure:
                decode_original_qr_fallback(Path('unchanged.png'))
        self.assertNotIn('private-payload', str(failure.exception))
        self.assertEqual(run.call_args.kwargs['timeout'], 15)
        self.assertEqual(run.call_args.args[0][-2:], ['--fallback-worker', 'unchanged.png'])

    def test_fallback_process_rejects_failure_and_malformed_output(self):
        from verify_pdf import decode_original_qr_fallback
        for code, output in [(1, b'private diagnostic'), (0, b'not json'), (0, b'{"payload":"private"}'), (0, b'[123]'), (0, b'x' * 1048577)]:
            with self.subTest(code=code, outputLength=len(output)), patch('verify_pdf.subprocess.run', return_value=subprocess.CompletedProcess([], code, stdout=output, stderr=b'')):
                with self.assertRaises(AcceptanceError):
                    decode_original_qr_fallback(Path('unchanged.png'))
        with patch('verify_pdf.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stdout=b'["EXPECTED"]', stderr=b'')):
            self.assertEqual(decode_original_qr_fallback(Path('unchanged.png')), ['EXPECTED'])

    def test_exit4_with_output_cannot_override_primary_symbols(self):
        with patch('verify_pdf.subprocess.run', return_value=subprocess.CompletedProcess([], 4, stdout=b'WRONG\n', stderr=b'')), patch('verify_pdf.decode_original_qr_fallback') as fallback:
            with self.assertRaises(AcceptanceError):
                decode_png(Path('original.png'), 'zbarimg')
            fallback.assert_not_called()

    def test_other_decoder_error_never_invokes_fallback(self):
        with patch('verify_pdf.subprocess.run', return_value=subprocess.CompletedProcess([], 2, stdout=b'', stderr=b'')), patch('verify_pdf.decode_original_qr_fallback') as fallback:
            with self.assertRaises(AcceptanceError):
                decode_png(Path('original.png'), 'zbarimg')
            fallback.assert_not_called()

    def test_primary_wrong_identity_and_multiple_symbols_never_get_fallback(self):
        for output in (b'WRONG\n', b'synthetic-identity-0\nSECOND\n'):
            with patch('verify_pdf.subprocess.run', return_value=subprocess.CompletedProcess([], 0, stdout=output, stderr=b'')), patch('verify_pdf.decode_original_qr_fallback') as fallback:
                with self.assertRaises(AcceptanceError):
                    verify(self.path, self.manifest)
                fallback.assert_not_called()

    def test_independent_wrong_identity_multiple_and_nonqr_are_rejected(self):
        no_symbol = subprocess.CompletedProcess([], 4, stdout=b'', stderr=b'')
        for symbols in ([], [SimpleNamespace(text='WRONG')], [SimpleNamespace(text='synthetic-identity-0'), SimpleNamespace(text='SECOND')]):
            # Empty QR-only result represents a non-QR barcode/no QR.
            zxing = SimpleNamespace(read_barcodes=lambda *args, **kwargs: symbols, BarcodeFormat=SimpleNamespace(QRCode='QR_ONLY'))
            with patch('verify_pdf.subprocess.run', return_value=no_symbol), patch('verify_pdf.decode_original_qr_fallback', side_effect=lambda p: __import__('verify_pdf')._decode_original_qr_inprocess(p)), patch.dict('sys.modules', {'zxingcpp': zxing}):
                with self.assertRaises(AcceptanceError):
                    verify(self.path, self.manifest)

    def test_missing_decoder_is_failure_not_skip(self):
        with self.assertRaisesRegex(AcceptanceError, 'unavailable'):
            verify(self.path, self.manifest, decoder='/nonexistent-idqr-decoder')

    def test_cli_failure_is_nonzero_without_payloads(self):
        manifest_path = Path(self.temporary.name) / 'manifest.json'
        manifest_path.write_text(json.dumps(self.manifest))
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('verify_pdf.py')), str(self.path), str(manifest_path), '--decoder', '/nonexistent-idqr-decoder'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)['verdict'], 'FAIL')
        self.assertNotIn('synthetic-identity', result.stdout)


if __name__ == '__main__':
    unittest.main()
