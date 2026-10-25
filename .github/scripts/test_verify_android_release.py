import unittest
from verify_android_release import verify_report, EXPECTED_SHA1


class FinalApkIdentityTest(unittest.TestCase):
    def test_permanent_signer(self):
        verify_report('Signer #1 certificate SHA-1 digest: ' + EXPECTED_SHA1.lower() + '\n')

    def test_reject_other_key_debug_missing_and_multiple_signers(self):
        for report in ['', 'Signer #1 certificate SHA-1 digest: ' + '00' * 20,
                       'Signer #1 certificate DN: CN=Android Debug, O=Android\nSigner #1 certificate SHA-1 digest: ' + EXPECTED_SHA1,
                       'Signer #1 certificate SHA-1 digest: ' + EXPECTED_SHA1 + '\nSigner #2 certificate SHA-1 digest: ' + EXPECTED_SHA1]:
            with self.subTest(report=report), self.assertRaises(ValueError):
                verify_report(report)


if __name__ == '__main__':
    unittest.main()
