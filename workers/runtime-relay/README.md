# Orca Runtime Relay Worker

This is the desktop/runtime adapter deployment of the Worker relay.

Use it for:

```text
orca-relay-bridge -> wss://<runtime-worker-domain>/ws
orca-relay-proxy  -> wss://<runtime-worker-domain>/ws
```

The server bridge and proxy must send:

```text
Authorization: Bearer <ORCA_RELAY_TOKEN>
```

with the same token stored as the Worker secret `ORCA_RELAY_TOKEN`.

Each runtime needs a unique stable `serverId`, for example:

```text
p600-orca
wx-71-orca
```

The Worker uses one Durable Object per `serverId`, so multiple runtimes can
connect concurrently without sharing sockets. Reusing a `serverId` replaces
the existing bridge for that runtime and is not a valid multi-server setup.

The mobile-direct deployment remains separate:

```text
wss://<mobile-worker-domain>/mobile/ws?serverId=<server-id>
```

This Worker does not implement Orca's native director/cell Anywhere Relay
protocol; it implements the existing adapter relay used by
`orca-relay-bridge` and `orca-relay-proxy`.
