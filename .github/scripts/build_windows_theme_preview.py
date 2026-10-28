"""Build actual Windows widgets as a separate demo, without changing production sources.
The generated tree has RAM-only data/credentials, no sync scheduler or network API.
"""
import argparse, pathlib, shutil, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[2]
def prepare(target):
    target=pathlib.Path(target).resolve()
    if target==ROOT or ROOT.is_relative_to(target): raise ValueError('Unsafe preview build directory')
    target.mkdir(parents=True,exist_ok=True)
    for name in ['lib','assets','web']:
        if (ROOT/name).exists():shutil.copytree(ROOT/name,target/name,dirs_exist_ok=True)
    shutil.copy2(ROOT/'pubspec.yaml',target/'pubspec.yaml')
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
    return target
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--prepare-only');parser.add_argument('--flutter',default='flutter');args=parser.parse_args()
    if args.prepare_only: print(prepare(args.prepare_only))
    else:
        with tempfile.TemporaryDirectory(prefix='vidya-theme-preview-') as work:
            target=prepare(work)
            subprocess.run([args.flutter,'create','--platforms=web','--project-name=saarthi_ai','.'],cwd=target,check=True)
            subprocess.run([args.flutter,'pub','get'],cwd=target,check=True)
            subprocess.run([args.flutter,'build','web','--release','--no-web-resources-cdn','--base-href=/windows-preview/','--dart-define=SAARTHI_THEME_PREVIEW=true','-t','lib/windows_theme_preview_main.dart'],cwd=target,check=True)
            dest=ROOT/'build/web/windows-preview';shutil.rmtree(dest,ignore_errors=True);shutil.copytree(target/'build/web',dest)
