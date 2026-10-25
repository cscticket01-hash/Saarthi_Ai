# Release trust and download warnings

Reviewed source: main at bb27e8b9f4aa92356c9f9a73378dc14810a72f54 (25 October 2026).

## Findings

- The Windows publisher workflow previously built and published both the application and Inno Setup installer without Authenticode signing. This can explain publisher/reputation warnings, but does not prove the cause of a Defender malware detection.
- Android production already restores the permanent release keystore, checks its SHA-1 identity, and signs with it. Do not regenerate this key or change `com.example.saarthi_ai`: existing installations depend on that identity. A Play Protect scan prompt is not proof of malware.
- Website download selection accepts published GitHub HTTPS release assets. Rehosting downloads does not establish publisher reputation or clear a malware verdict.

## Implemented release gates

Windows publication requires a trusted publisher certificate, signs application EXEs before ZIP/installer packaging, signs the final installer, verifies the pinned publisher and timestamp, and requires a successful Microsoft Defender scan with protection enabled. SHA256SUMS.txt accompanies the released installer and ZIP. Scan failures block publication instead of recommending antivirus exclusions.

Android publication verifies the actual final APK with Android SDK apksigner and compares its signer to the existing permanent certificate before copying or publishing it. Invalid signatures, debug signers and unexpected signers fail the build.

## Certificate configuration still required

An authorized owner must obtain a CA-issued code signing identity (or configure a supported managed signing provider). A self-signed certificate is not a substitute. Never send private keys or certificate passwords in chat.

For an exportable certificate supported by this implementation, configure in GitHub Actions:

- Secret `WINDOWS_SIGNING_PFX_BASE64`: base64 of the private PFX.
- Secret `WINDOWS_SIGNING_PASSWORD`: PFX password.
- Variable `WINDOWS_SIGNING_THUMBPRINT`: pinned SHA-1 thumbprint of the code signing certificate, not the Android certificate.

Hardware-backed or managed certificates require their provider's signing integration; do not attempt to export a nonexportable key. Public Windows releases intentionally stop before building when this configuration is absent. Current public assets are unchanged. A trusted timestamp/signature does not guarantee immediate SmartScreen reputation.

## External verification still required

Reproduce the exact alert on the actual installed/downloaded release; record the release URL, SHA-256, alert wording and Defender detection name. No actual alert or binary malware verdict was available during this source review. A hosted clean scan cannot prove absence of malware or reproduce every client verdict.

If a clean file is incorrectly detected, submit that exact final signed artifact to Microsoft Security Intelligence as a software developer: https://www.microsoft.com/en-us/wdsi/filesubmission . For Chrome malware/unwanted-software warnings, follow https://support.google.com/chrome/answer/6261569 and the publisher review guidance linked there. Do not claim a review was submitted without an actual submission receipt.

Android Play Store publication requires the owner's verified Play Console account, policies, privacy/data-safety declarations, signing setup and an accepted release. Keep the existing signing identity compatible across channels. Direct APK distribution may still receive browser download warnings and Play Protect scans. Existing self-update installation permissions require policy review for a future Play channel; this change does not silently remove updates or publish to Play.

## Validation scope

Local Android verifier tests cover the permanent signer, wrong signer, debug signer, missing signer and multiple signers. PR CI validates workflow structure and Windows PowerShell parsing plus missing-credential blocking. Actual CA signing, Defender scanning and Android SDK binary verification run on the relevant hosted release runner once credentials/builds are available. No live release, certificate purchase, false-positive submission or Play publication is performed by this PR.
