"""Build a deterministic source-guard catalog, never executable repair recipes.

Each case is an actual constant throw operand scoped to its owning source file.
Repeated messages in different owners are distinct contexts, not new root causes.
No raw/interpolated user, path, credential or server content is indexed.
"""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / 'lib/health/knowledge/catalog.v1.json'
KINDS = {'StateError', 'FormatException', 'Exception', 'ArgumentError',
         'SchoolQrException', 'Error', 'UnsupportedError', 'TimeoutException',
         'HttpException', 'FileSystemException'}
# Strings/comments are atomic so text inside them cannot invent a throw site.
TOKENS = re.compile(r'''//[^\n]*|/\*[\s\S]*?\*/|`(?:\\.|[^`\\])*`|r?(?:\"\"\"[\s\S]*?\"\"\"|\x27\x27\x27[\s\S]*?\x27\x27\x27)|r?(?:"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|[A-Za-z_$][\w$]*|[^\s]''')


def source_cases(root=ROOT):
    cases = {}
    for folder in ('lib', 'functions', 'oauth-broker', 'school-backend'):
        for path in sorted((root / folder).rglob('*')):
            if path.suffix not in {'.dart', '.js', '.cjs', '.gs'} or any(
                    part in {'test', 'node_modules', 'knowledge'} for part in path.parts):
                continue
            text = path.read_text()
            tokens = [(m.group(), m.start()) for m in TOKENS.finditer(text)
                      if not m.group().startswith(('//', '/*'))]
            for i, (token, start) in enumerate(tokens):
                if token != 'throw': continue
                j = i + 1
                if j < len(tokens) and tokens[j][0] in {'const', 'new'}: j += 1
                if j + 2 >= len(tokens): continue
                kind, opening, operand = [tokens[n][0] for n in range(j, j + 3)]
                if kind not in KINDS or opening != '(' or operand[:1] not in {'"', "'"}: continue
                if operand.startswith(('"""', "'''")): continue
                literal = operand[1:-1]
                if not 3 <= len(literal) <= 180 or any(c in literal for c in '$\\\n'): continue
                # Must be the complete first operand, not concatenated/interpolated.
                if j + 3 >= len(tokens) or tokens[j + 3][0] not in {')', ','}: continue
                relative = path.relative_to(root).as_posix()
                key = (relative, kind, literal)
                cases.setdefault(key, {'path': relative, 'kind': kind, 'literal': literal,
                                       'line': text.count('\n', 0, start) + 1})
    # Ambiguity is assessed against ALL real source contexts, including cases
    # outside the selected 1,000-rule library. A subset cannot prove uniqueness.
    origins = {}
    for case in cases.values():
        key = (case['kind'], case['literal'])
        origins[key] = origins.get(key, 0) + 1
    for case in cases.values():
        case['origins'] = origins[(case['kind'], case['literal'])]
    return list(cases.values())


def component(path):
    name = Path(path).name.lower()
    if any(v in name for v in ('id_card', 'card_', 'card-', 'card.')): return 'id-card'
    if 'qr' in name or 'school_link' in name: return 'qr'
    if 'attendance' in name: return 'attendance'
    if 'notice' in name or 'fcm' in name: return 'notices'
    if any(v in name for v in ('backup', 'restore', 'disaster', 'recycle')): return 'backup'
    if any(v in name for v in ('fee', 'payroll', 'expense', 'financial', 'exam', 'promotion')): return 'finance'
    if 'inventory' in name: return 'inventory'
    if any(v in name for v in ('document', 'pdf', 'save_pdf')): return 'documents'
    if any(v in name for v in ('sync', 'firestore', 'firebase_sync', 'managedadapter', 'student-import', 'school-cloud', 'managed-schools', 'backend_bridge')): return 'smart-sync'
    if any(v in name for v in ('sqlite', 'storage', 'disk', 'migration', 'local_firestore')): return 'database'
    if any(v in name for v in ('license', 'auth', 'password', 'session', 'gate', 'credential', 'authorization', 'exchange')): return 'authentication'
    if any(v in name for v in ('download', 'update', 'release')): return 'updates'
    if any(v in name for v in ('image', 'media', 'cipher')): return 'media'
    if any(v in name for v in ('transport', 'central_school_cloud', 'server.', 'connect', 'platform_client')): return 'networking'
    if name in {'main.dart', 'main_windows.dart', 'main_android.dart'}: return 'startup'
    if '/health/' in path: return 'monitor-worker'
    return 'administration'


def guidance(case):
    text = case['literal'].lower()
    if any(s in text for s in ('school changed', 'foreign', 'another school', 'identity', 'school mismatch', 'profile changed', 'school scope')):
        return ('C', 'Retain both scopes and stop cross-school admission. Reopen the intended authenticated school/profile; the owner must revalidate identity before further work.', 'Fresh owner school/profile evidence matches the admitted operation; no cross-school reads or writes occur.')
    if any(s in text for s in ('checksum', 'integrity', 'corrupt', 'hash', 'digest', 'signature', 'tampered', 'decrypt')):
        return ('C', 'Preserve the original and quarantine this result. Have the owner compare expected and measured integrity/signature evidence against the trusted manifest; never replace it with an empty file.', 'Owner independently verifies trusted manifest, bytes and identity; a generated replacement or attempted decode is not integrity proof.')
    if any(s in text for s in ('password', 'token', 'permission', 'license', 'licence', 'sign-in', 'login', 'unauthor', 'access denied', 'revok', 'credential')):
        return ('C', 'Use the existing authenticated account/licence interface to review validity and permissions. Preserve credentials and school binding; never grant privileges or bypass the guard automatically.', 'Authenticated owner verifies account, licence and permissions without exposing credentials in diagnostics.')
    if any(s in text for s in ('ack', 'receipt', 'readback', 'revision', 'conflict', 'overwrite', 'newer', 'checkpoint', 'durable', 'operation id')):
        return ('B', 'Keep the durable operation ID, queue and both revisions. Smart Sync alone reads the owner receipt/revision and admits retries or conflict review; do not infer success from transport completion.', 'Smart Sync verifies same-school operation receipt plus expected revision/readback before ACK; unchanged pending work is retained until that proof.')
    if any(s in text for s in ('timeout', 'timed out', 'deadline', 'unavailable', 'quota', 'rate limit', 'network')):
        return ('B', 'Locate the measured owner stage and respect its retry/backoff deadline. Keep in-flight work and originals; only the owner may admit a retry after checking settlement and operation identity.', 'Fresh stage/latency evidence identifies resolution; Smart Sync separately verifies business ACK and no duplicate operation is admitted.')
    if any(s in text for s in ('missing', 'not found', 'unreadable', 'file', 'directory', 'folder', 'disk', 'volume', 'storage')):
        return ('B', 'Review original availability, free space and access in the owning storage/file interface. Restore access to the original input; never reset storage, substitute a file or clear pending records.', 'Owner can read the original and verifies identity/content before resuming; no file replacement or queue reset is used as proof.')
    if case['kind'] == 'FormatException' or any(s in text for s in ('invalid', 'required', 'empty', 'blank', 'unsupported', 'format', 'parse', 'decode', 'must', 'malformed')):
        return ('B', 'Inspect the rejected input and its owner contract. Correct supported format/required fields through that owner while retaining the original; do not upload partial or blank replacements.', 'Fresh owner validation accepts the corrected input under the same school/profile; business persistence still requires the owner receipt.')
    return ('C', 'Preserve inputs and in-flight work. Inspect the exact source guard and bounded owner evidence; this message alone does not establish the underlying cause or authorize an automatic repair.', 'Fresh owner diagnostics establish resolution. An attempted restart, transport response or catalog match alone is not verified recovery.')


def make_rule(case, template):
    import copy
    rule = copy.deepcopy(template)
    canonical = json.dumps([case['path'], case['kind'], case['literal']], separators=(',', ':'))
    code = 'sh-src-' + hashlib.sha256(canonical.encode()).hexdigest()[:20]
    owner = component(case['path'])
    failure = {'FormatException': 'decoding', 'TimeoutException': 'timeout'}.get(case['kind'], 'unknown')
    level, solution, verification = guidance(case)
    rule.update(id=code, component=owner, name=case['literal'],
        signature={'component': owner, 'failure': failure, 'ownerCategory': '', 'diagnosticCode': code},
        symptoms=[case['literal']], evidence=[f"Constant {case['kind']} throw operand in {case['path']}:{case['line']}",
            'Exact source-guard context only; no production incident or root cause is asserted'],
        possibleCauses=['The owning source guard rejected this operation; inspect its condition and owner evidence'],
        diagnostic=f"Inspect {case['path']}:{case['line']} and its enclosing guard. Match exact kind/literal/source; reject ambiguous or interpolated messages.",
        solution=solution, level=level, playbook='', dependencies=[],
        preconditions=['Current school/profile matches', 'Owner authorization remains valid',
            'No conflicting in-flight action', 'Guidance only; no guardian execution capability'],
        timeoutSeconds=0, cooldownSeconds=0, attemptLimit=0, verification=verification,
        source=[case['path']], testEvidence=['test/health_knowledge_test.dart', 'tool/test_health_knowledge.py'],
        reviewedSource='5a3937f source guard inventory; contextual diagnosis only',
        evidenceType='source-backed exact guard; synthetic matching', sourceCase=case)
    return rule


def extend():
    data = json.loads(CATALOG.read_text())
    base = [r for r in data['rules'] if not r['id'].startswith('sh-src-')]
    cases = source_cases()
    required = 1000 - len(base)
    unique = {c['literal'] for c in cases}
    if len(unique) < required: raise ValueError(f'Only {len(unique)} distinct constant source messages; {required} required')
    # Stable source/path ordering; prioritize real owners over guardian guard errors.
    cases.sort(key=lambda c: ('/health/' in c['path'], c['path'], c['line'], c['literal']))
    # Round-robin actual files so a large early file cannot exclude the managed
    # Script, finance, backup or late Windows owners. No synthetic combinations.
    files = {}
    for case in cases: files.setdefault(case['path'], []).append(case)
    selected = []
    messages = set()
    depth = 0
    while len(selected) < required:
        for group in files.values():
            if depth < len(group) and group[depth]['literal'] not in messages:
                selected.append(group[depth]); messages.add(group[depth]['literal'])
            if len(selected) == required: break
        depth += 1
    data['rules'] = base + [make_rule(c, base[0]) for c in selected]
    CATALOG.write_text(json.dumps(data, ensure_ascii=True, indent=2) + '\n')
    print(json.dumps({'rules': len(data['rules']), 'sourceContextsAvailable': len(cases),
                      'components': sorted(set(r['component'] for r in data['rules']))}))


if __name__ == '__main__': extend()
