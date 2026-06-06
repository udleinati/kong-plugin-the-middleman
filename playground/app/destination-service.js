// Destination service — the real upstream behind Kong in the playground.
//
// It echoes back, in the response body, every `x-*` header it received. Those
// headers are the ones the-middleman injected (x-tenant-id, x-role,
// x-account-id) plus x-middleman-cache-status. The test scripts grep this body
// to assert the plugin behaviour.
//
// Runs on Deno (Deno.serve). No external dependencies.

const port = Number(Deno.env.get("PORT") ?? "3000");

Deno.serve({ port, hostname: "0.0.0.0" }, (req) => {
  let body =
    "I'm the destination service. These are the x-headers added by the-middleman that I can see:\n\n";

  // Deno's Headers iterator yields lowercased header names.
  for (const [name, value] of req.headers) {
    if (name.startsWith("x-")) {
      body += `${name}: ${value}\n`;
    }
  }

  body += `\n@timestamp: ${new Date().toISOString()}`;

  return new Response(body, {
    headers: { "Content-Type": "text/plain" },
  });
});

console.log(`destination-service running on port ${port}`);
