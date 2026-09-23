import {
  adapterResponseForMobile,
  decodeAdapterFrame,
  encodeAdapterFrame,
  isValidIdentifier,
  rawCloseToAdapterFrame,
  rawMessageToAdapterFrame,
} from "./protocol.mjs";

const WS_UPGRADE = "websocket";
const MOBILE_DIRECT_PATH = "/mobile/ws";
const ADAPTER_PATH = "/ws";
const HEALTH_PATH = "/health";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === HEALTH_PATH) {
      return json({ status: "ok", version: "mobile-direct-v1" });
    }

    if (![MOBILE_DIRECT_PATH, ADAPTER_PATH].includes(url.pathname)) {
      return new Response("Not found", { status: 404 });
    }
    if (request.headers.get("Upgrade")?.toLowerCase() !== WS_UPGRADE) {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    const serverId = url.searchParams.get("serverId");
    if (!isValidIdentifier(serverId)) {
      return new Response("Invalid serverId", { status: 400 });
    }

    if (url.pathname === ADAPTER_PATH) {
      const role = url.searchParams.get("role");
      if (!["server", "client"].includes(role)) {
        return new Response("Invalid adapter role", { status: 400 });
      }
      if (role === "client" && !isValidIdentifier(url.searchParams.get("clientId"))) {
        return new Response("Invalid clientId", { status: 400 });
      }
      if (!hasBearerToken(request, env.ORCA_RELAY_TOKEN)) {
        return new Response("Unauthorized", { status: 401 });
      }
    }

    const id = env.RELAY_SESSIONS.idFromName(serverId);
    return env.RELAY_SESSIONS.get(id).fetch(request);
  },
};

export class RuntimeRelayDO {
  constructor(ctx, env) {
    this.ctx = ctx;
    this.env = env;
    this.bridge = null;
    this.adapterClients = new Map();
    this.mobileClients = new Map();
    this.restoreSockets();
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade")?.toLowerCase() !== WS_UPGRADE) {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }

    if (url.pathname === ADAPTER_PATH) {
      return this.acceptAdapterSocket(request, url);
    }
    if (url.pathname === MOBILE_DIRECT_PATH) {
      return this.acceptMobileSocket();
    }
    return new Response("Not found", { status: 404 });
  }

  webSocketMessage(socket, message) {
    const attachment = socket.deserializeAttachment();
    if (!attachment) {
      return this.close(socket, 1011, "missing socket attachment");
    }

    try {
      if (attachment.kind === "bridge") {
        this.forwardBridgeMessage(message);
        return;
      }
      if (attachment.kind === "adapter-client") {
        this.forwardAdapterClientMessage(socket, message, attachment);
        return;
      }
      if (attachment.kind === "mobile-direct") {
        this.forwardMobileMessage(socket, message, attachment);
        return;
      }
      this.close(socket, 1011, "unknown socket type");
    } catch (error) {
      this.close(socket, 1002, safeError(error));
    }
  }

  webSocketClose(socket, code, reason) {
    const attachment = socket.deserializeAttachment();
    if (!attachment) {
      return;
    }

    if (attachment.kind === "bridge") {
      if (this.bridge === socket) {
        this.bridge = null;
      }
      this.closeClientsForBridgeLoss();
      return;
    }

    if (attachment.kind === "adapter-client") {
      this.adapterClients.delete(attachment.clientId);
      return;
    }

    if (attachment.kind === "mobile-direct") {
      this.mobileClients.delete(attachment.clientId);
      this.forwardMobileClose(code, reason, attachment);
    }
  }

  webSocketError(socket) {
    const attachment = socket.deserializeAttachment();
    if (attachment?.kind === "bridge" && this.bridge === socket) {
      this.bridge = null;
      this.closeClientsForBridgeLoss();
    }
  }

  restoreSockets() {
    for (const socket of this.ctx.getWebSockets()) {
      const attachment = socket.deserializeAttachment();
      if (!attachment) {
        this.close(socket, 1011, "missing socket attachment");
        continue;
      }
      if (attachment.kind === "bridge") {
        if (this.bridge) {
          this.close(socket, 1000, "bridge replaced");
        } else {
          this.bridge = socket;
        }
      } else if (attachment.kind === "adapter-client") {
        this.adapterClients.set(attachment.clientId, socket);
      } else if (attachment.kind === "mobile-direct") {
        this.mobileClients.set(attachment.clientId, socket);
      } else {
        this.close(socket, 1011, "unknown socket type");
      }
    }
  }

  acceptAdapterSocket(request, url) {
    if (!hasBearerToken(request, this.env.ORCA_RELAY_TOKEN)) {
      return new Response("Unauthorized", { status: 401 });
    }

    const role = url.searchParams.get("role");
    const clientId = url.searchParams.get("clientId");
    if (role !== "server" && role !== "client") {
      return new Response("Invalid adapter role", { status: 400 });
    }
    if (role === "client" && !isValidIdentifier(clientId)) {
      return new Response("Invalid clientId", { status: 400 });
    }

    const [client, server] = Object.values(new WebSocketPair());
    if (role === "server") {
      if (this.bridge) {
        this.close(this.bridge, 1000, "bridge replaced");
      }
      server.serializeAttachment({ kind: "bridge" });
      this.ctx.acceptWebSocket(server);
      this.bridge = server;
    } else {
      const oldSocket = this.adapterClients.get(clientId);
      if (oldSocket) {
        this.close(oldSocket, 1000, "client replaced");
      }
      server.serializeAttachment({ kind: "adapter-client", clientId });
      this.ctx.acceptWebSocket(server);
      this.adapterClients.set(clientId, server);
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  acceptMobileSocket() {
    if (!this.bridge) {
      return new Response("Relay bridge unavailable", { status: 503 });
    }

    const clientId = `mobile-${crypto.randomUUID()}`;
    const attachment = {
      kind: "mobile-direct",
      clientId,
      connectionId: clientId,
    };
    const [client, server] = Object.values(new WebSocketPair());
    server.serializeAttachment(attachment);
    this.ctx.acceptWebSocket(server);
    this.mobileClients.set(clientId, server);
    return new Response(null, { status: 101, webSocket: client });
  }

  forwardBridgeMessage(message) {
    const frame = decodeAdapterFrame(message);
    if (frame.header.direction !== "server_to_client") {
      throw new Error("bridge sent a non-server response frame");
    }

    const adapterClient = this.adapterClients.get(frame.header.clientId);
    if (adapterClient) {
      adapterClient.send(message);
      return;
    }

    const mobileClient = this.mobileClients.get(frame.header.clientId);
    if (!mobileClient) {
      return;
    }

    const attachment = mobileClient.deserializeAttachment();
    const action = adapterResponseForMobile(message, attachment);
    if (action.kind === "message") {
      mobileClient.send(action.value);
    } else {
      this.close(mobileClient, action.code, action.reason);
    }
  }

  forwardAdapterClientMessage(socket, message, attachment) {
    const frame = decodeAdapterFrame(message);
    if (
      frame.header.clientId !== attachment.clientId ||
      frame.header.direction !== "client_to_server"
    ) {
      throw new Error("adapter client frame has invalid routing fields");
    }
    if (!this.bridge) {
      this.close(socket, 1013, "relay bridge unavailable");
      return;
    }
    this.bridge.send(message);
  }

  forwardMobileMessage(socket, message, attachment) {
    if (!this.bridge) {
      this.close(socket, 1013, "relay bridge unavailable");
      return;
    }
    this.bridge.send(rawMessageToAdapterFrame(message, attachment));
  }

  forwardMobileClose(code, reason, attachment) {
    if (!this.bridge) {
      return;
    }
    try {
      this.bridge.send(rawCloseToAdapterFrame(code, reason, attachment));
    } catch {
      // The raw connection is already closed. This is only best-effort cleanup.
    }
  }

  closeClientsForBridgeLoss() {
    for (const socket of this.adapterClients.values()) {
      this.close(socket, 1013, "relay bridge unavailable");
    }
    for (const socket of this.mobileClients.values()) {
      this.close(socket, 1013, "relay bridge unavailable");
    }
  }

  close(socket, code, reason) {
    try {
      socket.close(code, String(reason).slice(0, 123));
    } catch {
      // A close may race an already-closed peer.
    }
  }
}

function hasBearerToken(request, expectedToken) {
  if (!expectedToken) {
    return false;
  }
  const authorization = request.headers.get("Authorization");
  return authorization === `Bearer ${expectedToken}`;
}

function json(value) {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function safeError(error) {
  return error instanceof Error ? error.message.slice(0, 100) : "protocol error";
}
