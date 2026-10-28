"""Content-address the Flutter app and bootstrap so cached entrypoints cannot mix releases."""
from pathlib import Path
import hashlib,re,sys

def version(root):
    root=Path(root)
    main=root/'main.dart.js'; bootstrap=root/'flutter_bootstrap.js'; index=root/'index.html'
    main_name='main.'+hashlib.sha256(main.read_bytes()).hexdigest()[:16]+'.dart.js'
    (root/main_name).write_bytes(main.read_bytes())
    source=bootstrap.read_text()
    source,count=re.subn(r'([\"\']mainJsPath[\"\']\s*:\s*[\"\'])main\.dart\.js([\"\'])',lambda m:m[1]+main_name+m[2],source)
    if count!=1:raise ValueError('Expected one Flutter mainJsPath; refusing an unversioned deployment')
    boot_name='flutter_bootstrap.'+hashlib.sha256(source.encode()).hexdigest()[:16]+'.js'
    (root/boot_name).write_text(source)
    # Keep legacy URLs working while browsers transition from an older HTML document.
    bootstrap.write_text(source)
    html=index.read_text()
    html,count=re.subn(r'(src=[\"\'])flutter_bootstrap\.js([\"\'])',lambda m:m[1]+boot_name+m[2],html)
    if count!=1:raise ValueError('Expected one Flutter bootstrap script')
    index.write_text(html)
    return main_name,boot_name
if __name__=='__main__':
    print(*version(sys.argv[1] if len(sys.argv)>1 else 'build/web'),sep='\n')
