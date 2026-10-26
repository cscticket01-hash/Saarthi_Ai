"""Add an immediate, local-only shell before Flutter's first frame."""
from pathlib import Path

index = Path('web/index.html')
html = index.read_text()
marker = '<!-- VIDYA_SAARTHI_STARTUP -->'
if marker not in html:
    shell = '''<!-- VIDYA_SAARTHI_STARTUP -->
<style>
html,body{margin:0;background:#0b141a;color:#e8f5ef}
#startup{position:fixed;inset:0;display:grid;place-content:center;text-align:center;font:16px system-ui,sans-serif;background:#0b141a;z-index:9999}
#startup h1{font-size:28px;margin:0 0 12px;color:#63e6be}
#startup p{margin:0;color:#b7c9c2}
#startup progress{width:180px;margin:24px auto;accent-color:#63e6be}
</style>
<div id="startup" role="status" aria-live="polite"><h1>Vidya Saarthi</h1><p id="startup-message">Preparing your workspace…</p><progress aria-label="Loading website"></progress><noscript>Please enable JavaScript to open Vidya Saarthi.</noscript></div>
<script>
window.addEventListener('flutter-first-frame', function () {
  document.getElementById('startup')?.remove();
}, {once:true});
setTimeout(function () {
  const message=document.getElementById('startup-message');
  if(message) message.textContent='Still loading. Please check your connection if this continues.';
}, 20000);
</script>
'''
    html = html.replace('<body>', '<body>\n' + shell, 1)
    index.write_text(html)
