import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

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
