# Cloudflare Worker deployment guide

This repository contains two Worker deployments that share the same
Durable-Object relay implementation:

- **mobile-direct**: raw mobile runtime WebSocket at `/mobile/ws`
- **runtime-relay**: adapter protocol at `/ws` for `orca-relay-bridge` and
  `orca-relay-proxy`

Actual Worker domains, Cloudflare account IDs, API tokens, relay tokens,
pairing codes, device tokens, and public keys are deployment secrets. Do not
commit them or paste them into agent logs.

## Deploy mobile-direct

```sh
cd workers/mobile-direct
export CLOUDFLARE_API_TOKEN='<cloudflare-deploy-token>'
export CLOUDFLARE_ACCOUNT_ID='<account-id>'
export MOBILE_WORKER_DOMAIN='<mobile-worker-domain>'

npx wrangler deploy --domains "$MOBILE_WORKER_DOMAIN"
printf '%s' '<relay-token-from-protected-secret>' \
  | npx wrangler secret put ORCA_RELAY_TOKEN
```

Mobile endpoint:

```text
wss://<mobile-worker-domain>/mobile/ws?serverId=<server-id>
```

## Deploy runtime-relay

```sh
cd workers/runtime-relay
export CLOUDFLARE_API_TOKEN='<cloudflare-deploy-token>'
export CLOUDFLARE_ACCOUNT_ID='<account-id>'
export RUNTIME_WORKER_DOMAIN='<runtime-worker-domain>'

npx wrangler deploy --config wrangler.jsonc \
  --domains "$RUNTIME_WORKER_DOMAIN"
printf '%s' '<relay-token-from-protected-secret>' \
  | npx wrangler secret put ORCA_RELAY_TOKEN --config wrangler.jsonc
```

Bridge and proxy endpoint:

```text
wss://<runtime-worker-domain>/ws
```

## Server bridge configuration

Every runtime must use a unique stable `ORCA_RELAY_SERVER_ID`:

```dotenv
ORCA_RELAY_URL=wss://<runtime-worker-domain>/ws
ORCA_RELAY_SERVER_ID=<server-id>
ORCA_RUNTIME_WS_URL=ws://127.0.0.1:<runtime-port>/
ORCA_RELAY_TOKEN=<relay-token-from-protected-secret>
```

Never pass the token as a command-line argument.

## Desktop/CLI proxy configuration

Desktop/CLI must connect to a local proxy, not directly to the adapter Worker:

```dotenv
ORCA_RELAY_URL=wss://<runtime-worker-domain>/ws
ORCA_RELAY_SERVER_ID=<server-id>
ORCA_RELAY_CLIENT_ID=<unique-client-id>
ORCA_RELAY_BIND=127.0.0.1:17777
ORCA_RELAY_TOKEN=<relay-token-from-protected-secret>
```

The Desktop/CLI pairing endpoint is:

```text
ws://127.0.0.1:17777/ws
```

## Agent acceptance checklist

Agents should report only:

1. Worker health result;
2. non-secret Worker URL;
3. unique server ID;
4. confirmed local runtime WebSocket URL;
5. bridge/proxy service state;
6. a pairing code only when the operator explicitly requests it.

Never report relay tokens, Cloudflare API tokens, device tokens, public keys,
or pairing codes in routine logs. Pairing codes are credentials and should be
delivered only through a private operator-controlled channel.
