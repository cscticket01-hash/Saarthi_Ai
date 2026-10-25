# Release trust and download warnings

Reviewed source: main at bb27e8b9f4aa92356c9f9a73378dc14810a72f54 (25 October 2026).

## Findings

- The Windows publisher workflow previously built and published both the application and Inno Setup installer without Authenticode signing. This can explain publisher/reputation warnings, but does not prove the cause of a Defender malware detection.
- Android production already restores the permanent release keystore, checks its SHA-1 identity, and signs with it. Do not regenerate this key or change `com.example.saarthi_ai`: existing installations depend on that identity. A Play Protect scan prompt is not proof of malware.
- Website download selection accepts published GitHub HTTPS release assets. Rehosting downloads does not establish publisher reputation or clear a malware verdict.

## Implemented release gates

When trusted signing is configured, Windows signs application EXEs before ZIP/installer packaging, signs the final installer and verifies the pinned publisher and timestamp. With no credentials it permits an explicitly labelled unsigned free build; partial credentials or an invalid configured signature fail. Set WINDOWS_REQUIRE_TRUSTED_SIGNING=true to enforce signed-only publication. Active Defender scan failures block publication; inactive hosted Defender is recorded as UNVERIFIED unless WINDOWS_REQUIRE_DEFENDER_SCAN=true requires it. No protection is disabled or bypassed. SHA256SUMS.txt accompanies the released installer and ZIP. Scan failures block publication instead of recommending antivirus exclusions.

Android publication verifies the actual final APK with Android SDK apksigner and compares its signer to the existing permanent certificate before copying or publishing it. Invalid signatures, debug signers and unexpected signers fail the build.

## Certificate configuration still required

An authorized owner must obtain a CA-issued code signing identity (or configure a supported managed signing provider). A self-signed certificate is not a substitute. Never send private keys or certificate passwords in chat.

For an exportable certificate supported by this implementation, configure in GitHub Actions:

- Secret `WINDOWS_SIGNING_PFX_BASE64`: base64 of the private PFX.
- Secret `WINDOWS_SIGNING_PASSWORD`: PFX password.
- Variable `WINDOWS_SIGNING_THUMBPRINT`: pinned SHA-1 thumbprint of the code signing certificate, not the Android certificate.

Hardware-backed or managed certificates require their provider's signing integration; do not attempt to export a nonexportable key. Public Windows releases stop for absent credentials only when WINDOWS_REQUIRE_TRUSTED_SIGNING=true; otherwise they explicitly report unsigned output. Current public assets are unchanged. A trusted timestamp/signature does not guarantee immediate SmartScreen reputation.

## External verification still required

Reproduce the exact alert on the actual installed/downloaded release; record the release URL, SHA-256, alert wording and Defender detection name. No actual alert or binary malware verdict was available during this source review. A hosted clean scan cannot prove absence of malware or reproduce every client verdict.

If a clean file is incorrectly detected, submit that exact final signed artifact to Microsoft Security Intelligence as a software developer: https://www.microsoft.com/en-us/wdsi/filesubmission . For Chrome malware/unwanted-software warnings, follow https://support.google.com/chrome/answer/6261569 and the publisher review guidance linked there. Do not claim a review was submitted without an actual submission receipt.

Android Play Store publication requires the owner's verified Play Console account, policies, privacy/data-safety declarations, signing setup and an accepted release. Keep the existing signing identity compatible across channels. Direct APK distribution may still receive browser download warnings and Play Protect scans. Existing self-update installation permissions require policy review for a future Play channel; this change does not silently remove updates or publish to Play.

## Validation scope

Local Android verifier tests cover the permanent signer, wrong signer, debug signer, missing signer and multiple signers. PR CI validates workflow structure, Windows PowerShell parsing and missing-credential refusal in the signer itself. Actual CA signing needs configured credentials, and a Defender result needs an active scan-capable runner. Actual public Android SDK binary verification passed in the audit. No live release, certificate purchase, false-positive submission or Play publication is performed by this PR.

## Free-only follow-up

No certificate purchase or paid service is authorized. Unnecessary process-level PowerShell execution-policy bypass flags were removed from the update cleanup helper and Windows image/document pickers; the scripts and existing quoting are preserved. This cleanup is not evidence that those flags caused a malware alert.

A separate free ClamAV workflow scans the exact SHA-256-pinned public Windows v2.1.171 installer and the same-release portable ZIP/application files without executing or deleting it. Scanner definitions, logs and hash evidence are retained. Its result must never be described as a Defender/SmartScreen/Chrome verdict. Extraction, update or scan failure is not a clean result.

Microsoft software-developer file review and Google security review are external steps requiring the exact detection/warning and, when required, an authenticated vendor account/site ownership. No vendor submission or successful review is claimed without a receipt.

Free SignPath Foundation signing requires a qualifying open-source license. This repository has no root LICENSE; its public visibility alone does not grant that license. Do not relicense the commercial school app or claim eligibility without the owner's separate decision and provider acceptance.

## Latest independent verification

All five platform build/security jobs passed at run 40169640950, along with release trust and sync/document review workflows for commit 313fcd8. Free ClamAV scan run 40169637439 scanned 39 files and 91.72 MiB with 0 infected files. This is not a Microsoft/Google verdict.

The owner-provided Chrome screenshots show a malware scan in progress followed by Scan is done and a completed download. They do not show a final malware block. Signed-in Google Search Console for https://vidyasaarthi.web.app/ reports No issues detected; there is no security review request available in that report. This does not guarantee that all downloaded binaries are trusted by Chrome or Windows. Microsoft sign-in approval timed out; no submission receipt exists.
