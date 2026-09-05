# Server

This server exchanges Nearby Interaction discovery tokens.

## Local (recommended)

```
npm start
```

That starts `src/standalone.mjs` on port 8787 and prints simulator and on-device URLs. No Cloudflare account is required.

## Cloudflare Workers

`src/index.ts` is the Workers version of the same API. It uses an in-memory store unless you bind a D1 database.

1. Create a D1 database if you want tokens to survive across isolates: see https://developers.cloudflare.com/d1/get-started/
2. Uncomment the `[[d1_databases]]` block in `wrangler.toml` and apply `schema.sql`.
3. Deploy with `npm run deploy` after `wrangler login`, or `npm run deploy:preview` for a 60-minute temporary URL.
