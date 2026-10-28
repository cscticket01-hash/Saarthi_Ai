"""Build actual Windows widgets as a separate demo, without changing production sources.
The generated tree has RAM-only data/credentials, no sync scheduler or network API.
"""
import argparse, pathlib, shutil, subprocess, tempfile, tarfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
def prepare(target):
    target=pathlib.Path(target).resolve()
    if target==ROOT or ROOT.is_relative_to(target) or target.is_relative_to(ROOT): raise ValueError('Unsafe preview build directory')
    target.mkdir(parents=True,exist_ok=True)
    for name in ['lib','assets','web']:
        if (ROOT/name).exists():shutil.copytree(ROOT/name,target/name,dirs_exist_ok=True)
    manifest=(ROOT/'pubspec.yaml').read_text()
    for family in ['Segoe UI','Roboto']:
        manifest+=f'\n    - family: "{family}"\n      fonts:\n        - asset: assets/id_card_regular.ttf\n        - asset: assets/id_card_bold.ttf\n          weight: 700\n'
    (target/'pubspec.yaml').write_text(manifest)
    for name in ['windows_sqlite_store','windows_secure_storage','windows_disk_storage','windows_clean_install_recovery']:
        relative=('storage/' if name=='windows_sqlite_store' else '')+name+'.dart'
        shutil.copy2(ROOT/f'.github/preview/{name}_stub.dart',target/'lib'/relative)
    def replace(file,old,new):
        path=target/'lib'/file;text=path.read_text();assert old in text,(file,old);path.write_text(text.replace(old,new,1))
    replace('windows_local_firestore.dart','Future<bool> localPersistenceEnabled() async {','Future<bool> localPersistenceEnabled() async { return false; /* PREVIEW ONLY */')
    replace('windows_sync_engine.dart','Future<void> initialize() async {','Future<void> initialize() async { return; /* PREVIEW ONLY */')
    replace('windows_html_shim.dart','void _load() {','void _load() { return; /* PREVIEW ONLY */')
    replace('windows_html_shim.dart','void _save() {','void _save() { return; /* PREVIEW ONLY */')
    replace('windows_appearance.dart','mode.value = value;','mode.value = value; return Future<void>.value(); /* PREVIEW ONLY */')
    # Connection panels may inspect credentials, but the preview has none.
    # Block API calls at the common transport boundary as well as hosting CSP.
    path=target/'lib/windows_connect/central_school_cloud.dart';text=path.read_text()
    marker='  Future<Map<String, dynamic>> send('
    start=text.index(marker);body=text.index(') async {',start)
    text=text[:body]+text[body:].replace(') async {',") async { throw StateError('Cloud is unavailable in theme preview');",1);path.write_text(text)
    replace('windows_admin_setup.dart','static Future<Map<String, dynamic>> read() async {',"static Future<Map<String, dynamic>> read() async { return {'schoolName':'Demo Public School','principalName':'Demo Principal'}; /* PREVIEW ONLY */")
    replace('windows_platform_client.dart','Future<void> initialize() async {','Future<void> initialize() async { return; /* PREVIEW ONLY */')
    replace('windows_platform_client.dart','Future<void> refresh() async {','Future<void> refresh() async { return; /* PREVIEW ONLY */')
    replace('main_dashboard_screen_windows.dart','void _startPortalInactivityTimer() {','void _startPortalInactivityTimer() { return; /* PREVIEW ONLY */')
    replace('windows_local_firestore.dart','Future<void> ensureDurableSchoolRecords() async {','Future<void> ensureDurableSchoolRecords() async { return; /* PREVIEW ONLY */')
    replace('windows_local_storage.dart','static Future<String> currentPath() async => (await dataDirectory()).path;',"static Future<String> currentPath() async => '/Demo preview (RAM only)';")
    # Preserve the native hash math using BigInt where JS cannot represent 64-bit literals.
    replace('main_dashboard_screen_windows.dart','var hash = 0xcbf29ce484222325;',"var hash = BigInt.parse('cbf29ce484222325',radix:16).toSigned(64);")
    replace('main_dashboard_screen_windows.dart','hash ^= unit;','hash ^= BigInt.from(unit);')
    replace('main_dashboard_screen_windows.dart','hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;',"hash = (hash * BigInt.from(0x100000001b3)) & BigInt.parse('7fffffffffffffff',radix:16);")
    return target
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--prepare-only');parser.add_argument('--flutter',default='flutter');args=parser.parse_args()
    if args.prepare_only: print(prepare(args.prepare_only))
    else:
        with tempfile.TemporaryDirectory(prefix='vidya-theme-preview-') as work:
            target=prepare(work)
            subprocess.run([args.flutter,'create','--platforms=web','--project-name=saarthi_ai','.'],cwd=target,check=True)
            subprocess.run([args.flutter,'pub','get'],cwd=target,check=True)
            # Printing's documented override keeps document raster previews local.
            archive=subprocess.run(['npm','pack','--ignore-scripts','pdfjs-dist@3.2.146'],cwd=target,check=True,text=True,stdout=subprocess.PIPE).stdout.strip().splitlines()[-1]
            pdfjs=target/'web/pdfjs';pdfjs.mkdir(exist_ok=True)
            with tarfile.open(target/pathlib.Path(archive).name) as bundle:
                for name in ['pdf.min.js','pdf.worker.min.js']:
                    (pdfjs/name).write_bytes(bundle.extractfile('package/build/'+name).read())
            index=target/'web/index.html';html=index.read_text();index.write_text(html.replace('</head>','<script>window.dartPdfJsBaseUrl="/windows-preview/pdfjs/";</script></head>'))
            subprocess.run([args.flutter,'build','web','--release','--no-web-resources-cdn','--base-href=/windows-preview/','--dart-define=SAARTHI_THEME_PREVIEW=true','-t','lib/windows_theme_preview_main.dart'],cwd=target,check=True)
            dest=ROOT/'build/web/windows-preview';shutil.rmtree(dest,ignore_errors=True);shutil.copytree(target/'build/web',dest)
