# Orca Mobile-Direct Worker Relay

This is a Cloudflare Worker + Durable Object implementation of the **mobile-direct**
path:

```text
Orca phone -> Worker /mobile/ws -> RuntimeRelayDO -> orca-relay-bridge -> runtime
```

It also implements the existing adapter endpoint for `orca-relay-bridge` and
`orca-relay-proxy`:

```text
GET /ws?role=server&serverId=<id>&v=1
GET /ws?role=client&serverId=<id>&clientId=<id>&v=1
```

Both adapter roles require `Authorization: Bearer $ORCA_RELAY_TOKEN`. The
mobile-direct endpoint deliberately does not: Orca phone pairing supplies its
runtime credential and E2EE handshake after the WebSocket opens, matching the
trust boundary of a public raw-runtime proxy. Deploy this endpoint only behind
the pairing flow, and add abuse controls before broad exposure.

## Scope boundary

This project is **not** an implementation of Orca's native mobile "Anywhere"
relay protocol. That protocol uses a different `scope=mobile` relay offer with
director/cell origins, short-lived invite/resume credentials, assignment
epochs, and mobile E2EE v2. It needs a distinct Director + Cell implementation.

## Local checks

```sh
npm install
npm test
npx wrangler deploy --dry-run
```

## Required Cloudflare deployment configuration

1. A Durable Object-capable Workers account.
2. Worker secret `ORCA_RELAY_TOKEN`, set with:

   ```sh
   npx wrangler secret put ORCA_RELAY_TOKEN
   ```

3. A Worker custom domain supplied at deployment time, such as:

   ```text
   <mobile-worker-domain>
   ```

4. A mobile pairing endpoint of:

   ```text
   wss://<mobile-worker-domain>/mobile/ws?serverId=<server-id>
   ```

The server-side `orca-relay-bridge` points to:

```text
wss://<mobile-worker-domain>/ws
```

with its existing `ORCA_RELAY_SERVER_ID` and `ORCA_RELAY_TOKEN`.
