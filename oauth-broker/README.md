# Staging OAuth token exchange service

The installed app uses a system browser and random loopback state/PKCE. Some Google
Desktop clients still demand `client_secret` on code exchange. That secret must
remain on a trusted server, not in the executable. This isolated Node service
uses the EXISTING client ID/secret from runtime environment and proxies only
one-use authorization-code exchange to Google's fixed token endpoint.

The OAuth routes do not create school Firebase projects or use Firebase admin credentials.
The native Drive flow may receive an offline refresh token; the broker handles it
only in memory, forwards refresh requests to the fixed Google endpoint and never
logs it. Google passwords and school file contents do not pass through these routes.
Codes/verifiers/access tokens pass through memory over HTTPS. Do not configure
request-body logging, token response logging, response caching or HTTP redirects.
Deploy behind managed HTTPS, restrict instances/concurrency, apply host-level rate
limits and keep health/request metrics free of credential-bearing bodies.

`npm test` runs security/HTTP tests. `docker build -t saarthi-oauth-broker-review .`
builds without secrets. At runtime supply only:

- `SAARTHI_GOOGLE_DESKTOP_CLIENT_ID` (same public repository variable)
- `SAARTHI_GOOGLE_DESKTOP_CLIENT_SECRET` (existing GitHub secret, transferred by a
  trusted deployment job to host secret storage; never print it or bake it into an image)
- `PORT` if required by the host (default 8080)

The public endpoint is `https://<developer-controlled-staging-host>/oauth/token`.
`/healthz` returns only service/version and a public client-ID fingerprint.
The server fixes client/upstream, requires a valid PKCE verifier and an exact
127.0.0.1 high-port callback, rejects arbitrary client/secret fields, browser
Origins and oversized requests, limits requests per instance, and never follows
upstream redirects. Google still validates the one-use code and PKCE binding.
A native public OAuth client needs no additional shared application password.

The authorized free Render staging service is
`https://saarthi-oauth-staging.onrender.com/oauth/token`, on the development branch
with auto-deploy disabled. Runtime credentials came from the existing GitHub
variable/secret through a one-time RSA-OAEP encrypted transfer. The transfer key
and workflow steps are removed after configuration. No secrets belong in source,
Windows artifacts or images.

Platform review CI defaults to that public staging endpoint and verifies the
client fingerprint plus an intentionally invalid code through Google. Production
builds still use the repository variable `SAARTHI_GOOGLE_OAUTH_BROKER_URL` and do
not default to staging. Windows warms and validates the service before browser
sign-in because a free Render instance can sleep. Live Windows school consent
and provisioning remain acceptance tests; no production release is published.

## Optional central API on the existing free Render service

The full Git-backed service can additionally serve `/school-cloud` and
`/school-cloud/healthz` using `staging-school-cloud/server.cjs`. This is separate
from the standalone OAuth-only Docker image. `npm --prefix oauth-broker install
--ignore-scripts` installs the modular Firebase Admin SDK needed by that adapter.
The Firebase project remains `saarthi-ai-df12b` on Spark; no Cloud Functions,
project creation, billing activation or school-managed credentials are needed.

The adapter is disabled until explicitly configured with
`SAARTHI_SCHOOL_CLOUD_ENABLED=true` and `SAARTHI_FIREBASE_ADMIN_JSON` in Render's
server-only environment. It uses the existing public Desktop OAuth client ID
for audience validation; optional additional approved IDs can be supplied via
`SAARTHI_GOOGLE_OAUTH_CLIENT_IDS`. Browser origins require the explicit
`SAARTHI_SCHOOL_WEB_ORIGINS` allowlist. Never compile the admin JSON into Windows.
The central health check performs read-only Firestore/Auth checks and caches its
result for 30 seconds; it never creates records or returns credentials.

At the 2026-10-03 staging checkpoint OAuth and central health return 200. The
reviewed default database isolation rules and server credential configuration
were explicitly approved and completed. The one-time encrypted artifact was
deleted and temporary workflow/transfer scripts removed. The Windows review
build compiles the staging endpoint and verifies both public OAuth and central
configuration. Real Google Sign-in + Drive consent/file checks still require
Windows acceptance with two permitted OAuth test accounts.
