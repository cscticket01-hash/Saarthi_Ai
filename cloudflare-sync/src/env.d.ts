export {};
// Secret bindings are provisioned separately and are not emitted by wrangler
// types from wrangler.jsonc. This declares their type, never their value.
declare global {
  interface Env { EDGE_KEY: string; R2_STAGE?: R2Bucket; R2_STAGING_ENABLED?: string; R2_STAGING_SCHOOLS?: string; R2_STAGING_ALL_SCHOOLS_ENABLED?: string; }
}
