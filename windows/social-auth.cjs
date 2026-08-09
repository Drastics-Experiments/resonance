const { createHash, randomBytes } = require("node:crypto");

const SOCIAL_AUTH_PROVIDERS = Object.freeze(["clerk"]);
const CALLBACK_URL = "resonance://auth/callback";
const MAX_AUTH_VALUE_LENGTH = 16 * 1024;

function boundedAuthText(value, label) {
  const text = String(value || "").trim();
  if (!text || text.length > MAX_AUTH_VALUE_LENGTH || /[\u0000-\u001f\u007f]/.test(text)) {
    throw new Error(`The ${label} is invalid.`);
  }
  return text;
}

function httpsOrigin(value, label) {
  const url = new URL(value);
  if (url.protocol !== "https:" || url.username || url.password || url.search || url.hash) {
    throw new Error(`${label} must use a complete HTTPS URL.`);
  }
  return url.origin;
}

function publishableKeyOrigin(value) {
  const key = boundedAuthText(value, "Clerk publishable key");
  const match = /^pk_(?:test|live)_([A-Za-z0-9_-]+={0,2})$/.exec(key);
  if (!match) throw new Error("The Clerk publishable key is invalid.");
  try {
    const host = Buffer.from(match[1], "base64url").toString("utf8").replace(/\$$/, "");
    return httpsOrigin(`https://${host}`, "Clerk publishable key");
  } catch {
    throw new Error("The Clerk publishable key is invalid.");
  }
}

function canonicalAuthConfiguration(value, baseURL) {
  if (!value || ![2, 3].includes(value.version) || !Array.isArray(value.providers)) {
    throw new Error("The server returned an unsupported account sign-in configuration.");
  }
  const endpoints = {
    authorizationEndpoint: new URL(value.authorization_endpoint),
    tokenEndpoint: new URL(value.token_endpoint),
    userEndpoint: new URL(value.user_endpoint),
    logoutEndpoint: new URL(value.logout_endpoint),
  };
  const issuer = httpsOrigin(value.issuer, "Clerk issuer");
  for (const endpoint of [endpoints.authorizationEndpoint, endpoints.tokenEndpoint, endpoints.userEndpoint]) {
    if (endpoint.protocol !== "https:" || endpoint.origin !== issuer || endpoint.username || endpoint.password) {
      throw new Error("The Clerk sign-in endpoints are invalid.");
    }
  }
  if (endpoints.logoutEndpoint.origin !== httpsOrigin(baseURL, "Server URL") ||
      endpoints.logoutEndpoint.pathname !== "/api/v1/auth/logout") {
    throw new Error("The account sign-out endpoint is invalid.");
  }
  if (value.redirect_uri !== CALLBACK_URL || value.scope !== "openid profile email") {
    throw new Error("The server returned an unsupported account callback or scope.");
  }
  const nativeConfiguration = value.version === 3
    ? {
        publishableKey: boundedAuthText(value.publishable_key, "Clerk publishable key"),
        tokenTemplate: boundedAuthText(value.token_template, "Clerk token template"),
      }
    : null;
  if (nativeConfiguration && (
    publishableKeyOrigin(nativeConfiguration.publishableKey) !== issuer ||
    nativeConfiguration.tokenTemplate !== "resonance"
  )) {
    throw new Error("The Clerk native sign-in configuration is invalid.");
  }
  const providers = value.providers.filter((provider) => SOCIAL_AUTH_PROVIDERS.includes(provider));
  if (!providers.length) throw new Error("Clerk sign-in is not enabled by the server.");
  return Object.freeze({
    ...endpoints,
    issuer,
    clientID: boundedAuthText(value.client_id, "Clerk client ID"),
    scope: value.scope,
    redirectURI: CALLBACK_URL,
    providers: Object.freeze([...new Set(providers)]),
    publishableKey: nativeConfiguration?.publishableKey || null,
    tokenTemplate: nativeConfiguration?.tokenTemplate || null,
  });
}

async function fetchAuthConfiguration(baseURL, fetchImpl = fetch) {
  const origin = httpsOrigin(baseURL, "Server URL");
  const response = await fetchImpl(new URL("/api/v1/auth/config", origin), {
    headers: { Accept: "application/json" },
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Account sign-in is unavailable (HTTP ${response.status}).`);
  return canonicalAuthConfiguration(await response.json(), origin);
}

function createPKCE() {
  const verifier = randomBytes(48).toString("base64url");
  const challenge = createHash("sha256").update(verifier, "ascii").digest("base64url");
  const state = randomBytes(32).toString("base64url");
  return Object.freeze({ verifier, challenge, state });
}

function authorizationURL(configuration, provider, challenge, state) {
  if (!configuration.providers.includes(provider)) {
    throw new Error("Clerk sign-in is not enabled by the server.");
  }
  if (!/^[A-Za-z0-9_-]{43}$/.test(challenge) || !/^[A-Za-z0-9_-]{43}$/.test(state)) {
    throw new Error("The sign-in challenge is invalid.");
  }
  const url = new URL(configuration.authorizationEndpoint);
  url.searchParams.set("client_id", configuration.clientID);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("redirect_uri", configuration.redirectURI);
  url.searchParams.set("scope", configuration.scope);
  url.searchParams.set("code_challenge", challenge);
  url.searchParams.set("code_challenge_method", "S256");
  url.searchParams.set("state", state);
  return url;
}

function canonicalSession(value, account, baseURL, fallbackRefreshToken = "") {
  const expiresIn = Number(value?.expires_in);
  if (!Number.isFinite(expiresIn) || expiresIn <= 0 || expiresIn > 7 * 24 * 60 * 60) {
    throw new Error("The authentication server returned an invalid session lifetime.");
  }
  const email = boundedAuthText(account?.email, "account email").toLowerCase();
  const role = account?.role === "admin" ? "admin" : account?.role === "member" ? "member" : null;
  if (!role) throw new Error("The Resonance server returned an invalid account role.");
  return Object.freeze({
    accessToken: boundedAuthText(value?.id_token, "Clerk ID token"),
    refreshToken: boundedAuthText(value?.refresh_token || fallbackRefreshToken, "refresh token"),
    expiresAt: Date.now() + Math.round(expiresIn * 1000),
    email,
    role,
    baseURL: httpsOrigin(baseURL, "Server URL"),
  });
}

async function accountForAccessToken(baseURL, accessToken, fetchImpl = fetch) {
  const response = await fetchImpl(new URL("/api/v1/auth/me", httpsOrigin(baseURL, "Server URL")), {
    headers: { Accept: "application/json", Authorization: `Bearer ${boundedAuthText(accessToken, "access token")}` },
    cache: "no-store",
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(payload?.error || `Account access was rejected (HTTP ${response.status}).`);
  return payload;
}

async function tokenRequest(configuration, fields, fetchImpl) {
  const response = await fetchImpl(configuration.tokenEndpoint, {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(fields),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload?.error_description || payload?.error || "Sign-in could not be completed.");
  }
  return payload;
}

async function exchangeAuthCode(configuration, baseURL, code, verifier, fetchImpl = fetch) {
  const payload = await tokenRequest(configuration, {
    grant_type: "authorization_code",
    client_id: configuration.clientID,
    redirect_uri: configuration.redirectURI,
    code: boundedAuthText(code, "authorization code"),
    code_verifier: boundedAuthText(verifier, "sign-in verifier"),
  }, fetchImpl);
  const account = await accountForAccessToken(baseURL, payload.id_token, fetchImpl);
  return canonicalSession(payload, account, baseURL);
}

async function refreshAuthSession(configuration, session, fetchImpl = fetch) {
  const payload = await tokenRequest(configuration, {
    grant_type: "refresh_token",
    client_id: configuration.clientID,
    refresh_token: boundedAuthText(session.refreshToken, "refresh token"),
  }, fetchImpl);
  const account = await accountForAccessToken(session.baseURL, payload.id_token, fetchImpl);
  return canonicalSession(payload, account, session.baseURL, session.refreshToken);
}

async function revokeAuthSession(configuration, session, fetchImpl = fetch) {
  await fetchImpl(configuration.logoutEndpoint, {
    method: "POST",
    headers: {
      Accept: "application/json",
      Authorization: `Bearer ${boundedAuthText(session.accessToken, "access token")}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ refresh_token: boundedAuthText(session.refreshToken, "refresh token") }),
  }).catch(() => undefined);
}

function publicSession(session) {
  if (!session) return null;
  return Object.freeze({
    accessToken: session.accessToken,
    expiresAt: session.expiresAt,
    email: session.email,
    role: session.role,
    baseURL: session.baseURL,
  });
}

module.exports = {
  CALLBACK_URL,
  SOCIAL_AUTH_PROVIDERS,
  accountForAccessToken,
  authorizationURL,
  canonicalAuthConfiguration,
  canonicalSession,
  createPKCE,
  exchangeAuthCode,
  fetchAuthConfiguration,
  publicSession,
  refreshAuthSession,
  revokeAuthSession,
};
