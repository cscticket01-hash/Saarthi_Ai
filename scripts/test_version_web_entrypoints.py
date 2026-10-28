import importlib.util,tempfile,unittest,json
from pathlib import Path
spec=importlib.util.spec_from_file_location('entry',Path(__file__).with_name('version-web-entrypoints.py'))
entry=importlib.util.module_from_spec(spec);spec.loader.exec_module(entry)
class VersionTests(unittest.TestCase):
 def fixture(self,root,code):
  (root/'main.dart.js').write_text(code)
  (root/'flutter_bootstrap.js').write_text('_flutter.buildConfig={"builds":[{"mainJsPath":"main.dart.js"}]};_flutter.loader.load();')
  (root/'index.html').write_text('<body><script src="flutter_bootstrap.js" async></script></body>')
 def test_changed_app_always_changes_html_and_both_script_urls(self):
  with tempfile.TemporaryDirectory() as d:
   r=Path(d);self.fixture(r,'old layout');old=entry.version(r);old_html=(r/'index.html').read_text()
   self.fixture(r,'compact theme layout');new=entry.version(r)
   self.assertNotEqual(old[0],new[0]);self.assertNotEqual(old[1],new[1]);self.assertNotEqual(old_html,(r/'index.html').read_text())
   self.assertIn(new[1],(r/'index.html').read_text());self.assertIn(new[0],(r/new[1]).read_text());self.assertEqual((r/new[0]).read_text(),'compact theme layout')
 def test_unknown_bootstrap_is_not_silently_deployed(self):
  with tempfile.TemporaryDirectory() as d:
   r=Path(d);self.fixture(r,'app');(r/'flutter_bootstrap.js').write_text('unsupported bootstrap')
   with self.assertRaises(ValueError):entry.version(r)
 def test_entrypoint_cache_headers_require_revalidation(self):
  c=json.loads((Path(__file__).parents[1]/'firebase.json').read_text())
  for name in ['/','/index.html','/main.dart.js','/flutter_bootstrap.js']:
   h=next(x for x in c['hosting']['headers'] if x['source']==name)
   self.assertIn('no-store',next(x['value'] for x in h['headers'] if x['key']=='Cache-Control'))
if __name__=='__main__':unittest.main()
