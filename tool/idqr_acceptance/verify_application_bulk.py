"""Independent every-declared-card verification of actual draft renderer PDFs."""
import json
from pathlib import Path
from verify_pdf import verify

directory = Path('build/idcard-bulk-core')
reports = []
for count in (50, 100, 500):
    manifest = json.loads((directory / f'application-{count}-verification.json').read_text())
    if len(manifest['cards']) != count:
        raise ValueError('Incomplete application fixture inventory')
    result = verify(directory / f'application-{count}.pdf', manifest)
    if len(result['checks']) != count * 3:
        raise ValueError('Incomplete original-raster resolution coverage')
    reports.append({'studentCount': count, **result})
(directory / 'independent-final-qr-reports.json').write_text(json.dumps(reports))
print(json.dumps([{'studentCount': r['studentCount'], 'verdict': r['verdict'],
                   'decodeCount': len(r['checks']), 'pdfSha256': r['pdfSha256']} for r in reports]))
