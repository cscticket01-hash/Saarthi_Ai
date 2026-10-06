# Windows 2.1.98 TEST build — not a production release

The exact source commit is in TEST-COMMIT.txt. Extract the entire ZIP before running saarthi_ai.exe; keep DLLs and data beside it. Preserve your current school backup and installation.

## Real Windows acceptance check

1. Open Student Records → a student → Student All Documents → Add/Upload Document.
2. Enter Document Name and confirm. The Windows native picker must open immediately, without a second Select file click.
3. Select a JPG/JPEG/PNG/PDF. Wait for processing; inspect the preview. Only explicit Save may create the document.
4. Repeat with picker Cancel. No empty document should appear. Try a corrupt/truncated file: show a failure, preserve existing records, allow retry.
5. Save while offline. Verify original file and processed preview remain after restart, then reconnect and check pending sync to the configured school storage.
6. Preview/export Student, Teacher and Other Staff IDs with long names, portrait/landscape photos, logos and signatures. Verify fit, physical size and QR scan on the exported PDF.
7. Verify School A cannot view School B documents/configuration; check app lock and licence behaviour without modifying production records.

CI verifies production callbacks with an injected native picker adapter, processing, durable queue, IDs, actual PDF QR decoding, native compilation/plugin registration and executable startup. Automated CI does not certify the final OS dialog interaction, real account login, or real Google Drive backup. Report those results before any production release.
