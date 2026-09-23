import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import process from "node:process";
import WebSocket from "ws";

import { decodeAdapterFrame, encodeAdapterFrame } from "../src/protocol.mjs";

const relayOrigin = process.env.ORCA_WORKER_URL;
if (!relayOrigin) {
  throw new Error("ORCA_WORKER_URL must be supplied through the environment");
}
const relayToken = process.env.ORCA_RELAY_TOKEN;
if (!relayToken) {
  throw new Error("ORCA_RELAY_TOKEN must be supplied through the environment");
}

const serverId = `mobile-smoke-${randomUUID()}`;
const bridge = await openSocket(
  `${relayOrigin}/ws?role=server&serverId=${serverId}&v=1`,
  { Authorization: `Bearer ${relayToken}` },
);

try {
  const phone = await openSocket(`${relayOrigin}/mobile/ws?serverId=${serverId}`);
  try {
    const delivered = new Promise((resolve, reject) => {
      phone.once("message", (data, isBinary) => {
        try {
          assert.equal(isBinary, false);
          assert.equal(data.toString(), "pong");
          resolve();
        } catch (error) {
          reject(error);
        }
      });
      phone.once("error", reject);
    });

    const bridgeFrame = new Promise((resolve, reject) => {
      bridge.once("message", (data, isBinary) => {
        try {
          assert.equal(isBinary, true);
          const frame = decodeAdapterFrame(data);
          assert.equal(frame.header.direction, "client_to_server");
          assert.equal(frame.header.opcode, "text");
          assert.equal(new TextDecoder().decode(frame.payload), "ping");
          resolve(frame);
        } catch (error) {
          reject(error);
        }
      });
      bridge.once("error", reject);
    });

    phone.send("ping");
    const received = await bridgeFrame;
    bridge.send(
      encodeAdapterFrame(
        {
          clientId: received.header.clientId,
          connectionId: received.header.connectionId,
          direction: "server_to_client",
          opcode: "text",
        },
        new TextEncoder().encode("pong"),
      ),
    );
    await delivered;
    console.log("Live mobile-direct relay smoke test: PASS");
  } finally {
    phone.close();
  }
} finally {
  bridge.close();
}

function openSocket(url, headers = undefined) {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, { headers });
    const timer = setTimeout(() => {
      socket.terminate();
      reject(new Error(`timed out opening ${url}`));
    }, 15_000);
    socket.once("open", () => {
      clearTimeout(timer);
      resolve(socket);
    });
    socket.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}
