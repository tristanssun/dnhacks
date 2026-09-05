import http from "node:http";
import os from "node:os";

const PORT = Number.parseInt(process.env.PORT ?? "8787", 10);
const tokens = new Map();

function json(res, status, body) {
	res.writeHead(status, {
		"Content-Type": "application/json",
		"Access-Control-Allow-Origin": "*",
		"Access-Control-Allow-Methods": "GET, POST, OPTIONS",
		"Access-Control-Allow-Headers": "Content-Type",
	});
	res.end(JSON.stringify(body));
}

function readBody(req) {
	return new Promise((resolve, reject) => {
		const chunks = [];
		req.on("data", (chunk) => chunks.push(chunk));
		req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
		req.on("error", reject);
	});
}

function randomId() {
	return 1000 + Math.floor(Math.random() * 9000);
}

function allocateId() {
	for (let attempt = 0; attempt < 16; attempt += 1) {
		const id = randomId();
		if (!tokens.has(id)) {
			return id;
		}
	}
	throw new Error("Could not allocate a unique code");
}

function lanAddresses() {
	const addresses = [];
	for (const addrs of Object.values(os.networkInterfaces())) {
		for (const addr of addrs ?? []) {
			if (addr.family === "IPv4" && !addr.internal) {
				addresses.push(addr.address);
			}
		}
	}
	return addresses;
}

const server = http.createServer(async (req, res) => {
	if (req.method === "OPTIONS") {
		res.writeHead(204, {
			"Access-Control-Allow-Origin": "*",
			"Access-Control-Allow-Methods": "GET, POST, OPTIONS",
			"Access-Control-Allow-Headers": "Content-Type",
		});
		res.end();
		return;
	}

	const url = new URL(req.url ?? "/", `http://${req.headers.host ?? "localhost"}`);

	try {
		if (req.method === "POST" && (url.pathname === "/" || url.pathname === "")) {
			const raw = await readBody(req);
			const requestBody = raw ? JSON.parse(raw) : null;
			if (!requestBody?.token || typeof requestBody.token !== "string") {
				json(res, 400, { id: -1, token: "", success: false });
				return;
			}

			const id = allocateId();
			tokens.set(id, requestBody.token);
			json(res, 200, { id, token: requestBody.token, success: true });
			return;
		}

		if (req.method === "GET") {
			const id = Number.parseInt(url.pathname.slice(1), 10);
			if (!Number.isInteger(id)) {
				json(res, 200, { ok: true, stored: tokens.size });
				return;
			}

			const token = tokens.get(id);
			if (!token) {
				json(res, 200, { id, token: "", success: false });
				return;
			}

			json(res, 200, { id, token, success: true });
			return;
		}

		res.writeHead(405, { "Content-Type": "text/plain" });
		res.end("Method Not Allowed");
	} catch (error) {
		json(res, 500, { id: -1, token: "", success: false, error: String(error) });
	}
});

server.listen(PORT, "0.0.0.0", () => {
	console.log(`Token server listening on http://127.0.0.1:${PORT}`);
	for (const ip of lanAddresses()) {
		console.log(`On-device URL:     http://${ip}:${PORT}`);
	}
});
