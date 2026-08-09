const assert = require("node:assert/strict");
const test = require("node:test");

const {
  authorizationURL,
  canonicalAuthConfiguration,
  canonicalSession,
  createPKCE,
  publicSession,
} = require("../social-auth.cjs");

const configuration = canonicalAuthConfiguration({
  version: 3,
  issuer: "https://resonance.clerk.accounts.dev",
  publishable_key: "pk_test_cmVzb25hbmNlLmNsZXJrLmFjY291bnRzLmRldiQ=",
  token_template: "resonance",
  authorization_endpoint: "https://resonance.clerk.accounts.dev/oauth/authorize",
  token_endpoint: "https://resonance.clerk.accounts.dev/oauth/token",
  user_endpoint: "https://resonance.clerk.accounts.dev/oauth/userinfo",
  logout_endpoint: "https://music.example/api/v1/auth/logout",
  client_id: "client_resonance",
  scope: "openid profile email",
  redirect_uri: "resonance://auth/callback",
  providers: ["clerk"],
}, "https://music.example");

test("builds Clerk's public-client PKCE authorization request", () => {
  const pkce = createPKCE();
  assert.match(pkce.verifier, /^[A-Za-z0-9_-]{64}$/);
  assert.match(pkce.challenge, /^[A-Za-z0-9_-]{43}$/);
  assert.match(pkce.state, /^[A-Za-z0-9_-]{43}$/);
  const url = authorizationURL(configuration, "clerk", pkce.challenge, pkce.state);
  assert.equal(url.searchParams.get("client_id"), "client_resonance");
  assert.equal(url.searchParams.get("response_type"), "code");
  assert.equal(url.searchParams.get("redirect_uri"), "resonance://auth/callback");
  assert.equal(url.searchParams.get("scope"), "openid profile email");
  assert.equal(url.searchParams.get("code_challenge"), pkce.challenge);
  assert.equal(url.searchParams.get("code_challenge_method"), "S256");
  assert.equal(url.searchParams.get("state"), pkce.state);
});

test("rejects cross-origin Clerk endpoints and hides refresh tokens from the renderer", () => {
  assert.throws(() => canonicalAuthConfiguration({
    version: 2,
    issuer: "https://resonance.clerk.accounts.dev",
    authorization_endpoint: "https://resonance.clerk.accounts.dev/oauth/authorize",
    token_endpoint: "https://evil.example/oauth/token",
    user_endpoint: "https://resonance.clerk.accounts.dev/oauth/userinfo",
    logout_endpoint: "https://music.example/api/v1/auth/logout",
    client_id: "client_resonance",
    scope: "openid profile email",
    redirect_uri: "resonance://auth/callback",
    providers: ["clerk"],
  }, "https://music.example"), /endpoints are invalid/);

  const session = canonicalSession(
    { id_token: "identity", refresh_token: "refresh", expires_in: 3600 },
    { email: "listener@example.com", role: "member" },
    "https://music.example",
  );
  assert.equal(publicSession(session).accessToken, "identity");
  assert.equal(Object.hasOwn(publicSession(session), "refreshToken"), false);
});

test("rejects a native publishable key for a different Clerk instance", () => {
  assert.throws(() => canonicalAuthConfiguration({
    version: 3,
    issuer: "https://resonance.clerk.accounts.dev",
    publishable_key: "pk_test_b3RoZXIuY2xlcmsuYWNjb3VudHMuZGV2JA==",
    token_template: "resonance",
    authorization_endpoint: "https://resonance.clerk.accounts.dev/oauth/authorize",
    token_endpoint: "https://resonance.clerk.accounts.dev/oauth/token",
    user_endpoint: "https://resonance.clerk.accounts.dev/oauth/userinfo",
    logout_endpoint: "https://music.example/api/v1/auth/logout",
    client_id: "client_resonance",
    scope: "openid profile email",
    redirect_uri: "resonance://auth/callback",
    providers: ["clerk", "email", "google", "apple", "discord"],
  }, "https://music.example"), /native sign-in configuration is invalid/);
});
