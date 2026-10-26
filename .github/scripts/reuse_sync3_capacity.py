"""Reuse only the immutable, already-passing Script fixture's identical inputs."""
import json
import os
from pathlib import Path
import subprocess

BASELINE = 'e08ce5b51901f268384ff50d76c642caa1fa4fe9'
RUN = '40308971934'
INPUTS = ['functions', 'school-backend', '.github/scripts/build_managed_script.py']

def unchanged(repo, baseline, head):
    for ref in (baseline, head):
        subprocess.run(['git', 'cat-file', '-e', ref + '^{commit}'], cwd=repo, check=True, capture_output=True)
    changed = subprocess.run(['git', 'diff', '--name-only', baseline, head, '--', *INPUTS],
                             cwd=repo, check=True, capture_output=True, text=True)
    return not changed.stdout.strip()

def main():
    head = os.environ['CAPACITY_SOURCE_SHA']
    reuse = unchanged('.', BASELINE, head)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write('reuse=' + str(reuse).lower() + '\n')
    if reuse:
        report = {'status': 'REUSED_EXISTING_PROOF', 'syntheticExecutedThisRun': False,
                  'sourceSha': head, 'verifiedBaselineSha': BASELINE, 'verifiedRunId': RUN,
                  'unchangedInputs': INPUTS, 'providerCapacityCertified': False}
        path = Path('build/sync3-capacity/reused-proof.json')
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2))
        with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as summary:
            summary.write('400-school synthetic fixture was **not rerun**. Its Script/backend/test inputs equal verified source `'
                          + BASELINE + '`. Existing proof: https://github.com/cscticket01-hash/Saarthi_Ai/actions/runs/'
                          + RUN + '. This is reused correctness evidence, not new provider-capacity evidence.\n')
    print('Unchanged verified fixture inputs; reuse prior evidence.' if reuse else 'Fixture inputs changed; execute capacity test.')

if __name__ == '__main__':
    main()
