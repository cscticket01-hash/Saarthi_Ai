"""Verify final APK signature against the existing installed-app identity."""
import argparse
import re
import subprocess

EXPECTED_SHA1 = '76241431E2A821D75664A6122446EB506FCAD01B'


def verify_report(report):
    digests = re.findall(r'^Signer #\d+ certificate SHA-1 digest:\s*([a-fA-F0-9:]+)\s*$', report, re.M)
    if len(digests) != 1 or digests[0].replace(':', '').upper() != EXPECTED_SHA1:
        raise ValueError('Final APK signer differs from permanent release identity')
    if re.search(r'^Signer #\d+ certificate DN:.*(?:CN=Android Debug|O=Android)', report, re.M | re.I):
        raise ValueError('Debug certificate is forbidden for public releases')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('apksigner')
    parser.add_argument('apk')
    args = parser.parse_args()
    result = subprocess.run([args.apksigner, 'verify', '--verbose', '--print-certs', args.apk], check=True, text=True, capture_output=True)
    verify_report(result.stdout)
    print('Final APK cryptographic verification and permanent signer identity: PASS')
