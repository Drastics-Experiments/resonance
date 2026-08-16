const MAX_SERVER_REDIRECTS = 5;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

function httpURL(value, label) {
  let url;
  try {
    url = value instanceof URL ? new URL(value.href) : new URL(String(value));
  } catch {
    throw new Error(`${label} is invalid.`);
  }
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.hash) {
    throw new Error(`${label} is unsafe.`);
  }
  return url;
}

function cancelResponseBody(response) {
  try {
    const result = response?.body?.cancel?.();
    return result && typeof result.then === 'function' ? result.catch(() => undefined) : undefined;
  } catch {
    return undefined;
  }
}

function redirectMethod(status, method, headers) {
  const normalizedMethod = String(method || 'GET').toUpperCase();
  if (![301, 302, 303].includes(status) || ['GET', 'HEAD'].includes(normalizedMethod)) {
    return { method: normalizedMethod, headers };
  }
  const nextHeaders = new Headers(headers);
  nextHeaders.delete('content-length');
  nextHeaders.delete('content-type');
  return { method: 'GET', headers: nextHeaders, body: undefined };
}

/**
 * Fetch an HTTP(S) resource without ever forwarding request credentials to a
 * different origin. Fetch's automatic redirect handling is deliberately
 * disabled; only same-origin redirects are followed, and only a bounded
 * number of times. Callers remain responsible for bounded response reads.
 */
async function fetchSameOrigin(baseURL, requestURL, options = {}, {
  fetchImpl = fetch,
  maxRedirects = MAX_SERVER_REDIRECTS,
} = {}) {
  const base = httpURL(baseURL, 'Trusted server URL');
  let current = httpURL(new URL(String(requestURL), base), 'Server request URL');
  if (current.origin !== base.origin) {
    throw new Error('The server request URL must use the configured server origin.');
  }
  if (!Number.isSafeInteger(maxRedirects) || maxRedirects < 0 || maxRedirects > 20) {
    throw new Error('The server redirect limit is invalid.');
  }

  let method = String(options.method || (options.body === undefined || options.body === null ? 'GET' : 'POST')).toUpperCase();
  let body = options.body;
  let headers = new Headers(options.headers || {});
  const initialHeaders = options.headers;
  for (let redirectCount = 0; ; redirectCount += 1) {
    const requestOptions = {
      ...options,
      method,
      // Preserve the caller's header shape for the first request (some
      // injected transports inspect plain objects), then clone through the
      // normalized Headers instance before following a redirect.
      headers: redirectCount === 0 && initialHeaders !== undefined
        ? initialHeaders
        : new Headers(headers),
      redirect: 'manual',
    };
    if (body === undefined) delete requestOptions.body;
    else requestOptions.body = body;
    const response = await fetchImpl(current, requestOptions);
    if (!REDIRECT_STATUSES.has(response.status)) return response;

    const location = response.headers?.get?.('location');
    if (!location) {
      await cancelResponseBody(response);
      throw new Error('The server returned a redirect without a Location header.');
    }
    if (redirectCount >= maxRedirects) {
      await cancelResponseBody(response);
      throw new Error('The server redirected the request too many times.');
    }

    let next;
    try {
      next = httpURL(new URL(location, current), 'Server redirect URL');
    } catch (error) {
      await cancelResponseBody(response);
      throw new Error(`The server returned an unsafe redirect: ${error.message}`);
    }
    if (next.origin !== base.origin) {
      await cancelResponseBody(response);
      throw new Error('The server returned a cross-origin redirect.');
    }
    await cancelResponseBody(response);
    const redirected = redirectMethod(response.status, method, headers);
    method = redirected.method;
    headers = redirected.headers;
    if (Object.hasOwn(redirected, 'body')) body = redirected.body;
    current = next;
  }
}

module.exports = {
  MAX_SERVER_REDIRECTS,
  fetchSameOrigin,
};
