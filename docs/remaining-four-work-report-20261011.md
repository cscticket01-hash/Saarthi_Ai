# Remaining four work items — 11 October 2026

Overall PARTIAL. This report distinguishes prepared source, hosted evidence and remaining live/physical acceptance.

| Item | Current result | Concrete blocker/next requirement |
|---|---|---|
| Apps Script upgrade / import / devices | Canonical2026-10-11.1 source reviewed; existingTESTupgrade package generated;4 helper tests PASS. Deployment BLOCKED. | Cloud Google sign-in shows502 Connection refused. Deployed signed bundle2026-10-10.3. Preserve existing project/properties/root/deployment; upgrade existingversion, verify signedhealth, then separate SchoolA/B import and enforcedfivePC tests with signingpin. |
| Actual PC / mobile / printer | HostedWindows, Chromium, AndroidAPI35 and Android-to-Windows tests PASS. Physical UNVERIFIED. | No native userPC/mobile/printer control exposed. Need installed-device offline/restart/sleep, scanner/camera and actual calibratedfront/backprint evidence. |
| IDCard2 / QR2 integration | Synthetic finalPDF verifier,24tests,50/100/500 benchmark PASS. Applicationintegration BLOCKED. | Original master explicitly requires independent sharedSync baseline acceptance before integration/activation. Live currentbundle/import/fivePC gates stillmissing. Syntheticfixture output cannot satisfy actual applicationexport/physicalprint. |
| RecycleBin realdeadline | Immutablebaseline preserved;5 harnessguardtests PASS; actualpostdeadline WAITING. | Earliest realdeadline12October06:35:19.426IST. Existingautomationupdated for06:36:20IST, samefixture/timestamps, no purge/recreation. Existingworkflowdispatch tool not exposed; executionmustverify supportedinvocation and reportBLOCKED if unavailable. |

## Upgrade package

Generated from reviewed application335a21c with existing-test-upgrade helper. Exactlytwo TESTconfiguration replacements; storagecreationfalse. Contains Code.gs, appsscript.json, provenance.json and instructions. No secrets or ownerexecution. Only existingTEST SyncV2 schoolvs-db8afb01a3be46a983c8284714d06e5d; do not use this boundpackage onanother school or runstorage/setup/rebind/migration. Notdeployed.

## Verified test scope

- Application335a21c: allsixplatformjobs38129113241 PASS.
- Live38129114291: allfivejobs PASS, actualAndroiddashboard/nativeplugins onAPI35 emulator; hostedWindows localstore integrity/newereditprotection. No physicalPCclaim.
- Syntheticprep6eb6244 run38130615671:50/100/500 cards,150/300/1500 exactidentitychecks at150/300/600DPI;4.069/4.773/21.816seconds total. QR-only unchangedrasterfallback onlyZBar emptyno-symbol; actualappexports/printingUNVERIFIED.
- Fresh elapsedhour38126239507 PASS,3602.010229s. Physicalsleep/wake andprocessrestartUNVERIFIED.

Main285b8585af012d3f565446a9d2f9637f3e71ac60 unchanged. No productionchange, release, billing, originalschooldiagnostics, pendingoperationclear or IDQRactivation. UserTESTupgradepermission persists; access, not approval, is blocked.
