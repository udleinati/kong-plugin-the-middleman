// Middle service — the target of "the-middle-request" in the playground.
//
// the-middleman POSTs to this service before proxying. What we answer depends on
// the request PATH (which is `config.path` of each route), so a single service
// can demonstrate every middle-service outcome the plugin handles:
//
//   config.path = /deny      -> 403  (forward-auth deny; replayed to the client)
//   config.path = /redirect  -> 302  (redirect; replayed with Location)
//   config.path = / (default)-> 200  identity JSON, injected as x-* headers
//
// For the 200 case the identity is mostly static (tenantId/role/accountId), but
// `tenantId` can be OFFLOADED from a forwarded `x-tenant` header — that is the
// README's host-offloading use case made real. When the route forwards the path
// or query (forward_path / forward_query), we echo them back so the playground
// can assert they round-tripped.
//
// Runs on Deno (Deno.serve). No external dependencies.

const port = Number(Deno.env.get("PORT") ?? "3000");

const json = (obj, status = 200, extra = {}) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json", ...extra },
  });

Deno.serve({ port, hostname: "0.0.0.0" }, async (req) => {
  // The forwarded request (headers/path/query/body) arrives as the JSON body.
  const raw = await req.text();
  if (raw) console.log(raw);

  let forwarded = {};
  try {
    forwarded = raw ? JSON.parse(raw) : {};
  } catch {
    /* not JSON — fall through with an empty object */
  }
  const fwdHeaders = forwarded.headers ?? {};

  // The middle-service decides based on the path it was called on (config.path).
  const route = new URL(req.url).pathname;

  // Deny: reject the request. the-middleman replays this status/body to the
  // client (>= 400 gate) and never reaches the upstream.
  if (route === "/deny") {
    return json({ error: "forbidden", reason: "demo deny" }, 403);
  }

  // Redirect: send the caller somewhere else (e.g. a login page). the-middleman
  // replays the 3xx + Location to the client instead of proxying upstream.
  if (route === "/redirect") {
    return new Response("", { status: 302, headers: { Location: "/login" } });
  }

  // Identity (200). tenantId is offloaded from a forwarded `x-tenant` header when
  // present (host-offloading), otherwise it falls back to the static demo value.
  const identity = {
    tenantId: fwdHeaders["x-tenant"] ?? "123",
    role: "admin",
    accountId: "112233",
  };

  // Echo the forwarded path/query back so forward_path / forward_query can be
  // asserted end-to-end (only present when the route enables those forwards).
  if (forwarded.path) {
    identity.fwdPath = forwarded.path;
  }
  if (forwarded.query && Object.keys(forwarded.query).length > 0) {
    identity.fwdQuery = JSON.stringify(forwarded.query);
  }

  // X-Auth-Source is a sample RESPONSE header; the /feat-respheader route copies
  // it onto the upstream request via config.forward_response_headers.
  return json(identity, 200, { "X-Auth-Source": "middle-service" });
});

console.log(`middle-service running on port ${port}`);
