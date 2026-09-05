interface RequestBody {
	token: string;
}

interface ResponseBody {
	id: number;
	token: string;
	success: boolean;
}

const memoryTokens = new Map<number, string>();

const InsertStatement = `INSERT INTO tokens (id, token, created_at) VALUES (?, ?, ?)`;

const corsHeaders = {
	"Access-Control-Allow-Origin": "*",
	"Access-Control-Allow-Methods": "GET, POST, OPTIONS",
	"Access-Control-Allow-Headers": "Content-Type",
};

function json(body: ResponseBody, status = 200): Response {
	return Response.json(body, { status, headers: corsHeaders });
}

function randomId(): number {
	return 1000 + Math.floor(Math.random() * 9000);
}

async function readRequestBody(request: Request): Promise<RequestBody | null> {
	const contentType = request.headers.get("content-type") ?? "";

	if (!contentType.includes("application/json")) {
		return null;
	}

	try {
		const requestBody = (await request.json()) as RequestBody;
		if (!requestBody?.token || typeof requestBody.token !== "string") {
			return null;
		}
		return requestBody;
	} catch {
		return null;
	}
}

async function storeToken(env: Env, token: string): Promise<{ id: number; success: boolean }> {
	if (env.DB) {
		for (let attempt = 0; attempt < 8; attempt += 1) {
			const id = randomId();
			try {
				const { success } = await env.DB.prepare(InsertStatement)
					.bind(id, token, new Date().toISOString())
					.run();
				if (success) {
					return { id, success: true };
				}
			} catch {
				// Unique id collision — try another code.
			}
		}
	}

	for (let attempt = 0; attempt < 16; attempt += 1) {
		const id = randomId();
		if (!memoryTokens.has(id)) {
			memoryTokens.set(id, token);
			return { id, success: true };
		}
	}

	return { id: -1, success: false };
}

async function loadToken(env: Env, id: number): Promise<string | null> {
	if (env.DB) {
		try {
			const { results } = await env.DB.prepare(`SELECT token FROM tokens WHERE id = ?`)
				.bind(id)
				.all<{ token: string }>();
			if (results.length > 0) {
				return String(results[0].token);
			}
		} catch {
			// Fall through to the in-memory store used by local/unconfigured deploys.
		}
	}

	return memoryTokens.get(id) ?? null;
}

export default {
	async fetch(request, env): Promise<Response> {
		if (request.method === "OPTIONS") {
			return new Response(null, { status: 204, headers: corsHeaders });
		}

		switch (request.method) {
			case "POST": {
				const requestBody = await readRequestBody(request);

				if (!requestBody) {
					return json({ id: -1, token: "", success: false }, 400);
				}

				const { id, success } = await storeToken(env, requestBody.token);
				return json({ id, token: requestBody.token, success });
			}
			case "GET": {
				const { pathname } = new URL(request.url);
				const id = Number.parseInt(pathname.replace(/^\/+/, ""), 10);

				if (!Number.isInteger(id)) {
					return new Response("Nearby Interaction token exchange", {
						headers: { "Content-Type": "text/plain", ...corsHeaders },
					});
				}

				const token = await loadToken(env, id);
				if (!token) {
					return json({ id, token: "", success: false });
				}

				return json({ id, token, success: true });
			}
			default:
				return new Response("Method Not Allowed", { status: 405, headers: corsHeaders });
		}
	},
} satisfies ExportedHandler<Env>;
