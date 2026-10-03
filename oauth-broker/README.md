# Staging OAuth token exchange service

The installed app uses a system browser and random loopback state/PKCE. Some Google
Desktop clients still demand `client_secret` on code exchange. That secret must
remain on a trusted server, not in the executable. This isolated Node service
uses the EXISTING client ID/secret from runtime environment and proxies only
one-use authorization-code exchange to Google's fixed token endpoint.

No school Firebase project, service-account key, database, Drive data, Google
password, OAuth refresh token or central school-data credential is used here.
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
