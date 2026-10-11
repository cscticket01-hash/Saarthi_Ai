"""Package unchanged canonical Apps Script and generic owner configuration guidance."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile

TRUSTED_ENDPOINTS = (
    'https://saarthi-oauth-staging.onrender.com/school-cloud',
    'https://saarthi-sync-v2-test.onrender.com/school-cloud',
)


def package(root, destination, source_commit='local'):
    root, destination = Path(root), Path(destination)
    source = (root / 'school-backend/managed/SaarthiManagedAll.gs').read_bytes()
    text = source.decode('utf-8')
    if text.count("const VS_SETUP_SCHOOL_ID = '';") != 1:
        raise ValueError('Universal source must retain an unbound default School ID')
    if text.count('const VS_SETUP_CREATE_NEW_STORAGE = false;') != 1:
        raise ValueError('Universal source must default to no storage creation')
    versions = set(re.findall(r"scriptBundleVersion:'([^']+)'", text))
    if len(versions) != 1:
        raise ValueError('One canonical bundle version required')
    script_manifest = (root / 'school-backend/managed/appsscript.json').read_bytes()
    if not isinstance(json.loads(script_manifest), dict):
        raise ValueError('Apps Script manifest object required')
    configuration = {
        'version': 1, 'scope': 'Owner-set Script Properties; never request-body configuration',
        'schoolId': {'property': 'VS_SETUP_SCHOOL_ID', 'value': None,
                     'format': '^vs-[a-f0-9]{32}$', 'requiredFor': 'first explicit setup only'},
        'createNewStorage': {'property': 'VS_SETUP_CREATE_NEW_STORAGE', 'default': False,
                             'explicitConsentRequired': True, 'upgradeValue': False},
        'centralEndpoint': {'property': 'VS_MANAGED_CENTRAL_ENDPOINT',
                            'default': TRUSTED_ENDPOINTS[0], 'allowed': list(TRUSTED_ENDPOINTS),
                            'testEndpointRequiresIsolatedSchool': True},
        'upgrade': {'runSetup': False, 'preserveScriptProperties': True,
                    'preserveDeploymentIdentity': True, 'rebindSchool': False},
    }
    # Configuration guidance alone cannot prove canonical property support.
    property_support = all(f"getProperty('{key}')" in text for key in (
        'VS_SETUP_SCHOOL_ID', 'VS_SETUP_CREATE_NEW_STORAGE', 'VS_MANAGED_CENTRAL_ENDPOINT'))
    provenance = {
        'status': 'PACKAGED_ONLY_NOT_DEPLOYED', 'sourceCommit': source_commit,
        'scriptBundleVersion': next(iter(versions)),
        'sourceSha256': hashlib.sha256(source).hexdigest(),
        'appsscriptManifestSha256': hashlib.sha256(script_manifest).hexdigest(),
        'canonicalSourceCopiedUnchanged': True, 'schoolIdentityBoundByPackage': False,
        'configurationPropertyMarkersPresent': property_support,
        'configurationContractAcceptance': 'UNVERIFIED',
        'setupExecuted': False, 'recordsChanged': False,
    }
    readme = (
        'UNIVERSAL PACKAGE — identical unchanged source for every school.\n'
        'This package runs no setup, API call, migration or deployment.\n'
        'For a NEW school, an owner sets Script Properties using configuration.json,\n'
        'verifies the assigned School ID and trusted central endpoint, then explicitly\n'
        'authorizes first storage setup. Creation remains disabled by default.\n'
        'For an EXISTING project, preserve school/root/secret properties and existing\n'
        'deployment identity; replace source only. Do not run setup, rebind or create storage.\n'
        'Never paste a private signing key, Firebase token, password or school connection secret\n'
        'into source, this configuration file or the package.\n'
        'Property marker presence is not security or deployed-provider acceptance.\n'
        'Require independent canonical allowlist/identity/redirect tests before configuring,\n'
        'then signed current-bundle health and real school isolation acceptance.\n'
    )
    if not property_support:
        readme += 'BLOCKED: canonical source lacks required property markers; owner must implement/review support first.\n'
    files = {'Code.gs': source, 'appsscript.json': script_manifest,
             'configuration.json': json.dumps(configuration, indent=2).encode(),
             'provenance.json': json.dumps(provenance, indent=2).encode(),
             'README.txt': readme.encode()}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = 0o600 << 16
            archive.writestr(entry, data)
    return provenance


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path('.'))
    parser.add_argument('--output', type=Path, default=Path('build/universal-script/Vidya_Saarthi_Universal_AppsScript.zip'))
    parser.add_argument('--source-commit', default='local')
    args = parser.parse_args()
    print(json.dumps(package(args.root, args.output, args.source_commit)))


if __name__ == '__main__':
    main()
