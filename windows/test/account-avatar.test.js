import assert from "node:assert/strict";
import test from "node:test";
import accountAvatar from "../account-avatar.cjs";

const {
  ACCOUNT_AVATAR_HOSTS,
  MAX_ACCOUNT_AVATAR_BYTES,
  MAX_ACCOUNT_AVATAR_URL_LENGTH,
  MAX_ACCOUNT_AVATAR_PIXELS,
  MAX_ACCOUNT_AVATAR_REDIRECTS,
  allowedAccountAvatarURL,
  fetchAccountAvatar,
  isPrivateHost,
  isSafeAccountAvatarDataURL,
  isWithinAccountAvatarPixelBounds,
} = accountAvatar;

const SAFE_DATA_URL = "data:image/png;base64,AA==";

function imageResponse(body = Buffer.from("avatar"), headers = {}) {
  return new Response(body, {
    status: 200,
    headers: { "content-type": "image/png", ...headers },
  });
}

test("allows only public HTTPS Clerk avatar hosts without URL credentials or unsafe ports", () => {
  assert.deepEqual(ACCOUNT_AVATAR_HOSTS, ["images.clerk.dev", "img.clerk.com"]);
  assert.equal(allowedAccountAvatarURL("https://images.clerk.dev/avatar.jpg?size=64").hostname, "images.clerk.dev");
  assert.equal(allowedAccountAvatarURL("https://img.clerk.com:8443/avatar.webp"), null);
  for (const unsafe of [
    "http://images.clerk.dev/avatar.jpg",
    "https://user:pass@images.clerk.dev/avatar.jpg",
    "https://@images.clerk.dev/avatar.jpg",
    "https://images.clerk.dev:8443/avatar.jpg",
    "https://images.clerk.dev/avatar.jpg#fragment",
    "https://images.clerk.dev/avatar.jpg#",
    "https://images.clerk.dev.evil.example/avatar.jpg",
    "https://cdn.example/avatar.jpg",
    "https://localhost/avatar.jpg",
    "https://127.0.0.1/avatar.jpg",
    `https://images.clerk.dev/${"x".repeat(MAX_ACCOUNT_AVATAR_URL_LENGTH)}`,
    "https://[::1]/avatar.jpg",
  ]) assert.equal(allowedAccountAvatarURL(unsafe), null, unsafe);
  for (const privateHost of ["localhost", "printer.local", "10.0.0.1", "172.16.0.2", "[::1]"]) {
    assert.equal(isPrivateHost(privateHost), true, privateHost);
  }
});

test("manually follows only allowlisted redirects and sends no credentials", async () => {
  const calls = [];
  const fetchImpl = async (input, options) => {
    calls.push({ input: new URL(input).href, options });
    if (calls.length === 1) return new Response("redirect", {
      status: 302,
      headers: { location: "https://img.clerk.com/avatar.png?size=64" },
    });
    return imageResponse();
  };
  const result = await fetchAccountAvatar("https://images.clerk.dev/avatar.png", {
    fetchImpl,
    decodeImage: async (bytes, metadata) => {
      assert.equal(bytes.toString(), "avatar");
      assert.equal(metadata.contentType, "image/png");
      return { width: 64, height: 64, dataURL: SAFE_DATA_URL };
    },
  });
  assert.equal(result, SAFE_DATA_URL);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].options.redirect, "manual");
  assert.equal(calls[0].options.credentials, "omit");
  assert.equal(calls[0].options.headers.Authorization, undefined);
  assert.equal(calls[1].options.redirect, "manual");
});

test("rejects an untrusted redirect before issuing a request to it", async () => {
  const calls = [];
  const result = await fetchAccountAvatar("https://images.clerk.dev/avatar.png", {
    fetchImpl: async (input) => {
      calls.push(new URL(input).href);
      return new Response("redirect", {
        status: 302,
        headers: { location: "https://attacker.example/avatar.png" },
      });
    },
    decodeImage: async () => ({ width: 1, height: 1, dataURL: SAFE_DATA_URL }),
  });
  assert.equal(result, null);
  assert.deepEqual(calls, ["https://images.clerk.dev/avatar.png"]);
});

test("bounds redirect hops and rejects oversized encoded responses", async () => {
  let redirectCalls = 0;
  const redirectResult = await fetchAccountAvatar("https://images.clerk.dev/avatar.png", {
    fetchImpl: async () => {
      redirectCalls += 1;
      return new Response("redirect", {
        status: 302,
        headers: { location: "https://images.clerk.dev/avatar.png" },
      });
    },
    decodeImage: async () => ({ width: 1, height: 1, dataURL: SAFE_DATA_URL }),
  });
  assert.equal(redirectResult, null);
  assert.equal(redirectCalls, MAX_ACCOUNT_AVATAR_REDIRECTS + 1);

  let decoded = false;
  const oversizedResult = await fetchAccountAvatar("https://images.clerk.dev/avatar.png", {
    fetchImpl: async () => imageResponse(Buffer.from("small"), {
      "content-length": String(MAX_ACCOUNT_AVATAR_BYTES + 1),
    }),
    decodeImage: async () => {
      decoded = true;
      return { width: 1, height: 1, dataURL: SAFE_DATA_URL };
    },
  });
  assert.equal(oversizedResult, null);
  assert.equal(decoded, false);
});

test("rejects unsafe decoded dimensions and renderer-injection data URLs", async () => {
  assert.equal(isWithinAccountAvatarPixelBounds(4096, 4096), true);
  assert.equal(isWithinAccountAvatarPixelBounds(4097, 1), false);
  assert.equal(isWithinAccountAvatarPixelBounds(4096, 4097), false);
  assert.equal(isWithinAccountAvatarPixelBounds(4096, 4096 + 1), false);
  assert.equal(isWithinAccountAvatarPixelBounds(1, MAX_ACCOUNT_AVATAR_PIXELS + 1), false);
  assert.equal(isSafeAccountAvatarDataURL(SAFE_DATA_URL), SAFE_DATA_URL);
  assert.equal(isSafeAccountAvatarDataURL("data:image/png;base64,AA==\")\nbackground-image:url(https://evil.example)"), null);

  const result = await fetchAccountAvatar("https://images.clerk.dev/avatar.png", {
    fetchImpl: async () => imageResponse(),
    decodeImage: async () => ({ width: 4097, height: 1, dataURL: SAFE_DATA_URL }),
  });
  assert.equal(result, null);
});
