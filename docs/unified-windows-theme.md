# Unified Windows appearance

A global developer-authorised RGB seed generates dark/light Material colour schemes. Schools choose only Dark or Light. Authenticated developer routes validate integer RGB channels and compare the saved revision before updating the configuration. Theme configuration lives outside school operational records and outboxes.

Managed login supplies only the school’s activated brand snapshot. Developer saves remain pending per school until every registered active PC has confirmed App Lock. A separate authenticated theme-state endpoint verifies device credentials, records lock transitions and transactionally activates the newest colour only at the all-locked barrier. Unlock records the PC as open before returning the activated snapshot. Lock confirmations expire after 65 seconds and are renewed every 30 seconds while locked; unknown/stale PCs block activation. Unlocked PCs report transitions and retry failures but do not poll once acknowledged. Offline unlock retains the cached seed; no background response changes the colour of an already open session. A four-second UI wait does not cancel the serialized request queue. This presentation control uses no operational sync, outbox, Apps Script or school-record writes. Existing PCs must install the update to report locks. Hosted tests do not prove simultaneous physical/offline lock state; server decisions use the latest authenticated confirmations.

Native Windows widgets share foreground, surface, border, shadow and action roles. Generated brand colours remain brand colours when legacy status colours are mapped. Document pixels and print colours are independent of the UI mode.

Staff Salary and Templates share an opaque white-paper payslip renderer with earnings, deductions, exact paise totals and payment summary. Viewing and printing do not record a payment.

Validation covers developer authorisation and revision conflicts, delayed login delivery, extreme RGB contrast, persisted preferences, open form/dialog continuity, and 16 Windows routes in both modes at two desktop sizes. Loaded salary and fee forms and the enabled Add Student/bulk salary actions have explicit assertions. Template thumbnails are injected at the native raster boundary for route layout captures; independent generated PDF checks verify document contents. Synthetic offline error states are intentional, not live-school verification.

Hosted builds and automated screenshots do not certify every physical device, printer or unvisited dialog. Physical-school acceptance remains distinct from these automated regressions.

Compact desktop fee collection uses full-width stacked panels with bounded heights and expanded selectors; wider desktops retain the two-column workbench.
