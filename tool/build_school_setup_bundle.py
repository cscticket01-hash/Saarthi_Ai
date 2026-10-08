"""Generate the Windows easy-connect payload from the canonical school backend.

Run with --check in CI; never hand-edit the generated asset.
"""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
backend = root / 'school-backend'
files = [dict(name=p.stem, type='SERVER_JS', source=p.read_text(encoding='utf-8'))
         for p in sorted(backend.glob('*.gs'))]
files.append(dict(name='appsscript', type='JSON',
                  source=(backend / 'appsscript.json').read_text(encoding='utf-8')))
content = json.dumps(dict(files=files, rules=(backend / 'firestore.school.rules').read_text(encoding='utf-8')),
                     ensure_ascii=False, indent=2) + '\n'
target = root / 'assets/school_setup_bundle.json'
if '--check' in sys.argv:
    if not target.exists() or target.read_text(encoding='utf-8') != content:
        raise SystemExit('School setup bundle is stale. Run python tool/build_school_setup_bundle.py')
    print('School setup bundle matches canonical backend and rules.')
else:
    target.write_text(content, encoding='utf-8')
