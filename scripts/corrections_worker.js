/**
 * Table Read — Parser Corrections Cloudflare Worker
 *
 * Receives anonymised correction payloads from the macOS app (users who opted in)
 * and stores them in a Cloudflare KV namespace for later analysis.
 *
 * SETUP STEPS (one-time, ~5 minutes):
 * ─────────────────────────────────────────────────────────────────────────────
 * 1. Go to https://dash.cloudflare.com → Workers & Pages → Create application →
 *    Create Worker. Name it "table-read-corrections".
 *
 * 2. Create a KV namespace:
 *    Workers & Pages → KV → Create namespace → name it "CORRECTIONS_KV".
 *
 * 3. Bind the KV to the worker:
 *    Open the worker → Settings → Variables → KV Namespace Bindings →
 *    Add binding: Variable name = "CORRECTIONS_KV", KV namespace = CORRECTIONS_KV.
 *
 * 4. Paste this entire file into the worker's code editor and click Deploy.
 *
 * 5. Copy the worker's URL (e.g. https://table-read-corrections.YOUR-SUBDOMAIN.workers.dev)
 *    and paste it into AppState.swift as the value of `correctionUploadEndpoint`.
 *
 * 6. Redeploy the app.  That's it.
 *
 * READING SUBMISSIONS:
 * ─────────────────────────────────────────────────────────────────────────────
 * In the Cloudflare dashboard → Workers & Pages → KV → CORRECTIONS_KV
 * you can browse and export all submitted batches.
 * Each key is a timestamp-UUID; the value is the JSON payload from the app.
 *
 * Or use the Cloudflare API to bulk-export:
 *   wrangler kv:key list --namespace-id=YOUR_NAMESPACE_ID
 *   wrangler kv:bulk export --namespace-id=YOUR_NAMESPACE_ID corrections.json
 */

export default {
  async fetch(request, env) {
    // CORS pre-flight
    if (request.method === "OPTIONS") {
      return corsResponse(new Response(null, { status: 204 }));
    }

    if (request.method !== "POST") {
      return corsResponse(new Response("Method not allowed", { status: 405 }));
    }

    // Basic content-type gate
    const ct = request.headers.get("Content-Type") || "";
    if (!ct.includes("application/json")) {
      return corsResponse(new Response("Expected JSON", { status: 415 }));
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return corsResponse(new Response("Invalid JSON", { status: 400 }));
    }

    // Validate minimal shape
    if (!Array.isArray(body?.corrections) || body.corrections.length === 0) {
      return corsResponse(
        new Response(JSON.stringify({ ok: false, error: "No corrections supplied" }), {
          status: 400,
          headers: { "Content-Type": "application/json" },
        })
      );
    }

    // Cap batch size to prevent abuse
    const MAX_BATCH = 500;
    if (body.corrections.length > MAX_BATCH) {
      return corsResponse(
        new Response(JSON.stringify({ ok: false, error: "Batch too large" }), {
          status: 413,
          headers: { "Content-Type": "application/json" },
        })
      );
    }

    // Store in KV — key is timestamp + random suffix for uniqueness
    const key = `${Date.now()}-${crypto.randomUUID()}`;
    const value = JSON.stringify({
      receivedAt: new Date().toISOString(),
      corrections: body.corrections,
    });

    try {
      // TTL: keep entries for 2 years (in seconds).  Adjust or remove as needed.
      await env.CORRECTIONS_KV.put(key, value, { expirationTtl: 63_072_000 });
    } catch (err) {
      console.error("KV write failed:", err);
      return corsResponse(
        new Response(JSON.stringify({ ok: false, error: "Storage error" }), {
          status: 500,
          headers: { "Content-Type": "application/json" },
        })
      );
    }

    return corsResponse(
      new Response(JSON.stringify({ ok: true, stored: body.corrections.length }), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      })
    );
  },
};

function corsResponse(response) {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", "*");
  headers.set("Access-Control-Allow-Methods", "POST, OPTIONS");
  headers.set("Access-Control-Allow-Headers", "Content-Type");
  return new Response(response.body, {
    status: response.status,
    headers,
  });
}
