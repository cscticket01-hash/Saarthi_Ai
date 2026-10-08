# School cloud quota diagnosis and onboarding architecture

The generic quota message in the f4b799a Windows preview does not identify the failing API, operation, quota metric, quota limit or consumer project. Screenshot 201 cannot prove that the exhausted quota is project creation. Do not instruct schools to delete projects or purchase billing based on that message.

The diagnostic change retains only bounded structured Google ErrorInfo metadata: reason, consumer project number, quota metric, quota limit and limit value. API and operation are shown for direct requests and terminal asynchronous operation errors. Unknown HTTP 429 remains unknown; it is not classified as project-count capacity. A rate-limit reason is distinguished from the documented projects_count metric. Google may omit structured identifiers, in which case further operator investigation is required. No raw Google response, OAuth token, password or school data is logged.

Retry the same encrypted setup checkpoint and project ID. Quota errors do not justify resetting setup, creating replacement projects, deleting projects or upgrading billing. A project deleted in Google Cloud still counts toward quota until fully deleted (normally 30 days).

## Limits of the current architecture

Each school creates its own Google Cloud/Firebase project with its own Google account. Project-count limits apply to the relevant account/organization, not a single global five-to-ten-school limit for the application. Firebase documents a small project-creation quota, usually around 5–10 for Spark accounts; actual account limits vary. API request rate limits are a separate constraint and may apply to the consuming project. The structured consumer identifier is needed before attributing a failure to the developer OAuth project or the school's project.

This design can support many different accounts, but cannot guarantee console-free onboarding for every school. Firebase terms must be accepted once per Google account through Firebase Console; OAuth Allow does not accept those terms and REST cannot accept them. Account project capacity, organization policy, API quotas, Auth initialization requirements and Apps Script authorization/settings are independent constraints. Increasing retries cannot remove them.

## Recommended architecture if the three-step experience is mandatory

Use provider-managed backend infrastructure with Google identity and server-enforced school tenancy. Provision a school tenant, not a new Firebase project in the school account, during onboarding. Keep Drive files in the school's account through the official Drive API with appropriate OAuth permissions. This removes school-managed Cloud project quotas and Firebase terms from the school onboarding path; the operator handles infrastructure quotas, billing and Firebase terms centrally.

Required before implementation: explicit agreement that Firebase infrastructure is provider-owned rather than school-owned; tenant identity derived from verified authentication and membership; cross-school denial tests; backups, export/deletion and ownership policy; secret storage and refresh-token encryption on the server; least-privilege Drive scopes; verified production OAuth consent and approval where required. Cloud cost and quota management remain operator responsibilities. Never place service-account keys in Windows. Do not create one Firebase app per school in a shared project.

An alternative is centrally managed, isolated per-school projects in an operator organization, with centralized project quota and billing management. It preserves project boundaries but still requires operator capacity planning and changes resource ownership. Neither alternative is silently enabled by this diagnostic patch. Existing school projects, installations and data remain unchanged.

## Next verification

Install the diagnostic Windows review artifact, reconnect the SAME Google account and continue the saved setup. Capture the new error including API, operation, metric, limit and consumer (if provided). A projects_count failure requires capacity management; a rate failure requires bounded waiting/retry and possibly operator quota adjustment. If Google omits the exact identifier, report it as unconfirmed rather than guessing. Real authorization and provisioning are not verified until the school test succeeds.

Official references:
- https://firebase.google.com/support/faq/ (terms, account project quotas, deletion)
- https://docs.cloud.google.com/resource-manager/docs/limits (API request quotas)
- https://docs.cloud.google.com/resource-manager/docs/creating-managing-projects (project capacity)
