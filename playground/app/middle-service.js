// Middle service — the target of "the-middle-request" in the playground.
//
// the-middleman POSTs to this service before proxying. We return a static
// identity JSON; the-middleman injects each key into the upstream request
// headers (tenantId -> x-tenant-id, role -> x-role, accountId -> x-account-id).
//
// Runs on Deno (Deno.serve). No external dependencies.

const port = Number(Deno.env.get("PORT") ?? "3000");

Deno.serve({ port, hostname: "0.0.0.0" }, async (req) => {
  // Log the forwarded request body (headers/path/etc.) for debugging.
  const requestBody = await req.text();
  if (requestBody) {
    console.log(requestBody);
  }

  const body = JSON.stringify({
    tenantId: "123",
    role: "admin",
    accountId: "112233",
  });

  // X-Auth-Source is a sample RESPONSE header; the /feat-respheader route copies
  // it onto the upstream request via config.forward_response_headers.
  return new Response(body, {
    headers: {
      "Content-Type": "application/json",
      "X-Auth-Source": "middle-service",
    },
  });
});

console.log(`middle-service running on port ${port}`);
