"""Build the three copy/paste installation files without duplicating source."""
from pathlib import Path
import shutil

source=Path('school-backend')
target=Path('build/school-backend')
target.mkdir(parents=True,exist_ok=True)
files=['SaarthiSchool.gs','SaarthiMobile.gs','SaarthiStorage.gs','SaarthiPlatform.gs']
text='\n\n'.join((source/name).read_text() for name in files)
(target/'Code.gs').write_text(text)
for name in ['appsscript.json','firestore.school.rules']:
    shutil.copyfile(source/name,target/name)
print('School Code.gs, appsscript.json and Firebase rules bundled')

managed=target/'managed'
managed.mkdir(exist_ok=True)
shutil.copyfile(source/'managed'/'SaarthiManagedAll.gs',managed/'Code.gs')
shutil.copyfile(source/'managed'/'appsscript.json',managed/'appsscript.json')
shutil.copyfile(Path('docs/managed-school-control-review.md'),managed/'README.md')
print('Managed school-owned Drive/mobile bundle included; existing school identity and root must be retained.')
