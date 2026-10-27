# Unified Windows appearance

A global, developer-authorised RGB seed generates accessible dark/light Material colour schemes. Schools choose only dark or light. Theme configuration is stored outside school operational records. Only authenticated developer routes can change it, with RGB validation and revision compare-and-set. Managed login supplies a snapshot; background heartbeat does not apply colour changes mid-session. App-lock unlock rechecks with a four-second presentation-only timeout. Offline unlock retains the cached seed and local mode.

Windows UI colours are mapped to shared surface, text and accent roles. Screen-specific dark overrides are removed. Status/error meanings remain distinct. Routes and unsaved form state are retained when mode changes. Document pixels and PDF print colours are excluded.

The shared staff payslip renderer uses opaque white paper, black ink, earning/deduction rows and exact paise payment totals. Templates and staff salary share the renderer. Viewing or printing does not record a payment.

Validation must include developer authorization/CAS, session-delayed colour delivery, extreme RGB contrast, both-mode screen captures, all route/dialog/form regressions and rendered payslip checks. Physical device coverage and any unreviewed screen must be reported explicitly; automated contrast checks are not a claim that every pixel has been certified.
