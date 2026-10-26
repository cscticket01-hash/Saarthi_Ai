"""Run: python scripts/create_firebase_link.py firebase-config.json"""
import base64
import json
import re
import sys
from pathlib import Path

def make_link(config):
    if not isinstance(config, dict):
        raise ValueError('Config must be a JSON object')
    if any(k in config for k in ('private_key', 'password', 'client_email')):
        raise ValueError('Use Firebase app config, never a service account or password')
    required = ('apiKey', 'appId', 'messagingSenderId', 'projectId')
    allowed = required + ('authDomain', 'storageBucket')
    for key in required:
        if not isinstance(config.get(key), str) or not config[key].strip():
            raise ValueError('Missing/invalid ' + key)
    if not re.fullmatch(r'[a-z][a-z0-9-]{4,28}[a-z0-9]', config['projectId']):
        raise ValueError('Invalid projectId')
    cleaned = {k: config[k].strip() for k in allowed if isinstance(config.get(k), str) and config[k].strip()}
    encoded = base64.urlsafe_b64encode(json.dumps(cleaned, separators=(',', ':')).encode()).decode().rstrip('=')
    return 'vidyasaarthi://firebase?config=' + encoded

if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python scripts/create_firebase_link.py firebase-config.json')
    try:
        link = make_link(json.loads(Path(sys.argv[1]).read_text(encoding='utf-8-sig')))
        Path('firebase-connection-link.txt').write_text(link, encoding='utf-8')
        print('Created firebase-connection-link.txt — paste its full contents into the Windows app.')
    except (ValueError, OSError) as error:
        raise SystemExit(str(error))
