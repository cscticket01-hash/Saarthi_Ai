# Windows school portal fixes

This update preserves existing Windows school data and the completed Android release and developer website.

- All routes display a red five-day trial/expiry header with reserved layout space. Licensed schools do not see a trial warning.
- Dashboard and Admin Analytics share a 320-pixel sidebar, the same ten sections, and a separate bottom logout action.
- Each analytics chart has its own month selector. Month summaries show recorded values; April sessions include the following January–March. Monthly attendance uses deduplicated student check-ins, school closure dates and elapsed school days.
- Exam definitions, subjects and marks remain accessible offline. With Local Data enabled they persist on the configured disk; with Local Data disabled they are session-only. Pending exam changes stay within their original school profile and replay with stable IDs when that same school is online.
- Publishing a notice requires verified school services, valid student QR identities and registered student-app users. A local write does not produce a sent status. Successful online publication and accepted mobile notification delivery are reported separately; FCM acceptance is not proof every phone displayed a notification.
- English, Hindi, Bengali and Assamese change live across portal labels, forms and dialogs. Language persists as a device UI preference, independent of school data. Entered form values and current routes survive language changes. Names, ID values and announcement bodies are not translated.
- Advanced Settings offers a password-confirmed reset of language, academic-year preference, document layouts and force-promotion preference. It preserves school records, offline edits, passwords, school connections, storage mode/location and original licence/trial identity and dates. It does not delete a database or reset the five-day trial.

## Read-only connection findings

A personal Google/Firebase account is not inherently invalid. The photographed Firebase project `saarthi-ai-df12b` is the developer monitoring project and is intentionally refused as a school operational backend. Each school must use its own correctly configured Firebase, authenticated administrator, Firestore rules and Google Script. This update does not change those connection or import guards.

A saved/healthy Google Script link alone does not load school student records: the existing sync engine requires the verified matching Firebase/Script pair. Local Data OFF also disables the persisted school cache. The script contents, old data schema and actual school permissions were not authenticated or migrated in this work.

## Verification

The platform review workflow runs Windows regression tests, Flutter analysis and a native Windows release build. The tests cover header layout, both sidebar modes, all four languages and preserved form state, offline exam records, school boundaries, notice recipient requirements, monthly controls and data-preserving reset.
