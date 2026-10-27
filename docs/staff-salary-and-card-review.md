# Salary and ID-card review changes

Payslips use the existing PDF generator and in-app fitted PDF preview. Printing is an explicit native printing action. Viewing a payslip does not launch the browser or record a payment. The former bulk Generate Payslips action is removed.

Payment History is a read-only school-scoped page across all salary months. The row menu opens the same page filtered to the selected staff member. It displays separate payment-date and payment-time columns in local 12-hour time. New payment intents preserve the selected time when changing the date and store recording time without changing idempotency comparisons. Legacy unitemized paid balances are explicitly labelled; missing dates/times are not invented.

A signed, school- and owner-verified published ID with different local generation inputs is recovered automatically. The engine migrates prior local review entries on its next cycle and verifies school, owner, document and cloud revision before retaining the authoritative published card. Failed verification stays durable for automatic retry. No manual ID-card review page or Settings action remains. Changed local inputs or cloud revisions are re-evaluated. No cloud ACK, upload, queue reset or card overwrite is manufactured by this repair.

Teacher cards show name, father name, date of birth, subject and address across all four designs. Number-bearing text/barcodes are removed; the secure QR and internal stable keys remain for authenticated mobile login and payroll. Teacher add/edit persists fatherName. Managed Apps Script retires only its verified generated number columns, leaving canonical records and owner columns intact; this projection change requires the new script bundle to be deployed in each school Apps Script project. Windows-only app updates cannot modify an independently deployed old script.

The global header update overlay is removed. Settings retains the live download state and background download continues across navigation.
