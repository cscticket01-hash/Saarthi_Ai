# Windows student ID cards

Windows replaces its legacy student ID gallery/default with four front/back vector layouts: Blue Chevron and Navy Schoolhouse (portrait), Green Curve and Green & Yellow (landscape). Reference screenshots are not embedded; all graphics are editable PDF artwork. Android/web and the shared document renderer are unchanged.

Templates → Student ID → Preview → Use for school sets the existing school-local template preference. Old/unset/invalid selection values safely resolve to the first design without resetting school records. Teacher IDs, report cards and receipts retain their existing renderer and preferences.

Cards use the saved student record and school profile for school name/logo, student name/photo, father/guardian name, class, roll, contact, address, district, state, PIN and principal signature. Address fields may be on the reverse. Missing signature is explicitly labelled rather than substituted with a sample signature. Existing local image data and school-authorized private Drive images are supported. The secure scanner payload and optional student UID remain on the reverse.

Saving a new student opens the selected front/back preview. Preview, PDF download and printing all call the same renderer. A preview failure does not retry student creation. Actual school records and uploaded files are not changed by rendering.

The red skipped-licence warning shows the saved trial/licence end date when available. Checking/unknown states show that expiry verification is pending. Activation, Skip and licence enforcement remain unchanged.

Windows acceptance: verify the warning date, preview all four layouts, save a student with photo and full address, check school branding/signature, print/download both sides, restart and reopen the existing student, then scan the retained QR. Check a long school/student/parent name and address. No merge/release or billing change.

Local validation: 63 Windows UI/startup/operations/central-cloud/document tests and 57 legacy OAuth/provisioning regression tests passed (the latter with the existing test-only provisioning flag). Changed Windows sources have zero analyzer errors; existing warnings remain. All four PDFs were rasterized and inspected; text extraction confirmed the required sample fields. Native Windows build is pending the approved development-branch push/CI run.
