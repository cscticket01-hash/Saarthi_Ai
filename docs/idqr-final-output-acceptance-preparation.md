# ID/QR final-output acceptance preparation

Baseline: checkpoint `56ad9addb42d0a0588bb642b5e6cf5abcf7d6fa0`, tested application source `d6791507ee2823ae18666a65e0e3eacfc30a1204`. Shared Sync acceptance remains PARTIAL. This preparation changes no application code, identity protocol, active template, database, school configuration or pipeline. It must not be described as ID/QR Engine2.0 implementation or activation.

Previous unintegrated preparation commits `3fa874f` and `8c6d473` were not available in this checkout and are not claimed as recovered.

## Final PDF tool

`tool/idqr_acceptance/verify_pdf.py` inspects an existing PDF read-only. Requires PyMuPDF, Pillow, pinned zxing-cpp and a separately installed `zbarimg` executable. It invokes the decoder without a shell and uses bounded subprocess timeouts and disposable render files. No network or photo processing occurs.

```sh
python tool/idqr_acceptance/verify_pdf.py exported.pdf export-verification-manifest.json
python -m unittest discover -s tool/idqr_acceptance -p 'test_*.py' -v
```

The JSON manifest is an acceptance-side contract, not a replacement for the existing application manifest or approved identity API:

```json
{
  "version": 1,
  "schoolId": "SYNTHETIC-A",
  "pageSizesPt": [[595.276, 841.890]],
  "cards": [{
    "schoolId": "SYNTHETIC-A",
    "studentId": "synthetic-student-001",
    "cardIssueId": "synthetic-issue-001",
    "side": "front",
    "page": 0,
    "qrBoxPt": [28.346, 28.346, 113.386, 113.386],
    "modules": 21,
    "quietZoneModules": 4,
    "qrPayload": "synthetic-existing-payload"
  }]
}
```

Coordinates use PDF points and PyMuPDF top-left page coordinates; `qrBoxPt` is `[left, top, right, bottom]`, inclusive of the quiet zone. Page indices are zero-based. `modules` is the QR matrix width excluding quiet zone, obtained from the actual approved encoding. Payloads must be existing intended identities, never newly issued by this verifier. Keep manifests locally protected; the report exposes indices rather than student IDs or payloads.

Every declared card QR is cropped from the actual PDF and rendered at150,300,600DPI. The zbar decoder disables all symbologies and enables QR only (`--set disable --set qrcode.enable`); a non-QR barcode with matching data cannot qualify. Exactly one decoded QR symbol must match the expected payload at every resolution. The tool checks all PDF pages have card inventory, exact physical page sizes within0.1point, school binding, unique issue/side keys, consistent student for a shared issue, non-overlapping square in-page regions, valid QR module count, declared quiet zone at least4modules and a0.25mm minimum declared module size. Missing/failed decoder, malformed inventory or mismatch gives FAIL and a nonzero exit. It never skips decoding while returning PASS.

Limitations: a supplied inventory can omit an undeclared printed card; compare it to the durable export manifest and selection snapshot before accepting completeness. Quiet-zone metadata is a geometry assertion, not independent measurement of the rendered white border. Text shaping, embedded fonts, contrast analysis, cropped photos, duplex alignment and physical scanning require additional evidence. Synthetic tests inject a decoder seam and prove traversal/render/error behavior; they do **not** prove QR decoding or real application PDF quality.

## Print geometry acceptance vectors

Existing `assets/school_id_manifest_v1.json` specifies portrait PVC54×85.6mm. Existing rendering has physical size handling and pair output, not a proven bulk A4 print engine. The following proposed vectors are isolated acceptance targets, not deployed layouts:

| Preset | Paper mm | Card mm | Rows×columns | Gap mm | Margins mm | Occupied block mm |
|---|---|---|---|---|---|---|
| A4 portrait / portrait cards |210×297|54×85.6|3×3|3|21left/right,17.1top/bottom|162+6=168wide,256.8+6=262.8high|
| A4 landscape / portrait cards |297×210|54×85.6|2×4|3|36left/right,17.9top/bottom|216+9=225wide,171.2+3=174.2high|

A future implementation should derive centering from the occupied block, never add guessed margins. For one portrait card the PDF physical rectangle is153.071×242.646points. Verify preview and export use the same geometry object. Front/back mapping must preserve issue/side and produce the selected duplex flip behavior without reassigning student identity. At50/100/500 students, record actual pages, output bytes, peak memory, elapsed time, missing-data list, cancellation/resume identity and exported-selection reconciliation. Printer acceptance must use100% scaling, a measured calibration sheet and actual front/back QR scans.

## Multilingual evidence gate

| Language | Synthetic specimen | Required evidence |
|---|---|---|
| English |Synthetic School — Alexandra Example|Long-name wrap, minimum readable size, no clipping|
| Bengali |বাংলা বিদ্যালয় — কৃত্রিম শিক্ষার্থী|Correct conjunct shaping, vowel placement and extraction/embedded font evidence|
| Hindi |परीक्षण विद्यालय — कृत्रिम विद्यार्थी|Correct Devanagari conjuncts/matras and line wrapping|
| Assamese |অসমীয়া বিদ্যালয় — কৃত্ৰিম শিক্ষাৰ্থী|Correct ৰ/ৱ and Assamese text shaping|

Render specimens through the actual application exporter, retain original Unicode strings, inspect final PDF text and embedded font resources, then review raster output with a reader of each language. An embedded font alone does not establish shaping. Mixed names and school names need long-name stress cases. Use only rights-cleared fonts. No font or external child-photo asset is introduced here.

Current preparation evidence: synthetic verifier tests only; real all-card decoding, bulk exports, language readability and printer acceptance remain UNVERIFIED. Application integration remains gated on independent shared Sync acceptance.

## Isolated hosted real-decoder smoke

The preparation-only workflow `.github/workflows/idqr-preparation-review.yml` triggers exclusively on pushes to `feature/idqr-acceptance-preparation` affecting this tool, this document or the workflow. It has read-only repository permissions and no credentials, application builds, activation or publication. It installs zbar-tools and pinned Python PDF dependencies, runs the verifier contract tests, then runs `smoke_real_decoder.py`.

The smoke constructs two synthetic vector QR symbols in an actual PDF, decodes both at150/300/600DPI, rejects a wrong final-card identity, and rejects a Code128 barcode carrying the same expected payload. An unrestricted decoder control must first decode that Code128 fixture, so an unreadable negative fixture cannot falsely satisfy the regression. Temporary fixture files are discarded. Missing real decoder exits2 with UNVERIFIED; decode/identity failures exit1 with FAIL. Hosted execution remains UNVERIFIED until the exact preparation commit has an observed passing run. Even a passing run establishes only synthetic PDF decoding, not actual application bulk export or physical printing acceptance.

## Synthetic bulk measurement preparation

`python tool/idqr_acceptance/benchmark_synthetic_bulk.py --count 50` (also supports100and500) builds class-mapped synthetic front-only cards in the proposed A4 portrait9-card geometry:54×85.6mm cards,3mm gaps,21mm horizontal and17.1mm vertical margins. Existing real school identities, photos, application exporters and queues are not accessed. Each student has a distinct fixture payload and existing test verifier checks all150/300/600DPI outputs using QR-only decoding.

The hosted workflow runs50,100,500 in separate Ubuntu jobs and preserves JSON reports as7-day CI artifacts. Each benchmark enforces a360-second measured generation/verification wall budget; the entire job is bounded at10minutes.500cards require1500decoder subprocesses. Budget overruns fail honestly; no smaller batch is substituted. Reports include actual PDF bytes/hash, generation and verification wall time, measured decoder wall time, cProfile-attributed raster/PNG API time, and process-lifetime Linux parent/maximum-child peak RSS. RSS fields are not a sum or application memory figure; timing contains profiling overhead. Reports retain no student photos or credentials.

Local fixtures/contract tests use an injected decoder because local zbar is unavailable. Local real bulk measurements remain UNVERIFIED. A hosted PASS certifies synthetic verifier throughput and coverage only. Actual application50/100/500front/back exports, cancellation/resume, language quality and printer acceptance remain UNVERIFIED until separately exercised after the shared Sync gate.

### Hosted benchmark failure diagnosis

Preparation run38129760040 passed real-decoder smoke and16contract tests, but50/100/500synthetic bulk jobs failed with decoder errors. No bulk PASS or root cause is claimed. Failure reporting now identifies inventory index and DPI without identities/payloads; the synthetic benchmark can preserve the actual failed raster and minimal geometry context in its7-day diagnostic artifact. Verification is not relaxed. The earlier two-QR smoke remains separate from bulk coverage.

Run38130010681 narrowed every bulk failure to the first declared QR at600DPI, zbar exit4;150and300DPI succeeded. This does not yet establish the cause. Additional **diagnostic-only** checks resize that exact failed raster to widths256/384/512with aspect ratio preserved and try QR-only zbar decoding. A second pinned zxing-cpp decoder checks only QR symbols in the original raster. Diagnostics report exact identity matches without exposing payloads. Neither resized nor second-decoder success changes the original FAIL verdict; no resolution is removed from acceptance. At most three extra bounded zbar subprocesses run for the first failure. The independent decoder is used only for synthetic diagnosis here.

### Demonstrated original-raster decoder limitation and strict fallback

Run38130274024 diagnostic artifact11699155560 demonstrated that the unchanged first600DPI raster (662×663pixels) decoded to exactly its intended identity with QR-only ZXing-cpp. QR-only zbar also decoded exact identities after diagnostic resizing to256/384/512pixels. The original zbar scan returned exit4 (no symbol). This establishes a decoder limitation for that original raster, not a malformed synthetic QR. The earlier bulk runs remain FAIL.

Acceptance now permits one strict fallback: **only zbar exit4/no-symbol** invokes pinned QR-only ZXing-cpp on the original unchanged raster. No resizing is used for acceptance. Other transport/process errors fail; a wrong or multiple primary decoded payload is never overridden. Missing fallback dependencies fail closed. Final verification still requires exactly one expected identity at every150/300/600DPI output. Bulk reports record actual original-raster fallback count and measured fallback wall time as a subset of decoder time. Real fixture non-QR and wrong-identity negatives remain mandatory, supplemented by fallback missing/wrong/multiple contract tests. New policy awaits its exact-source hosted result and does not establish actual application export acceptance.
