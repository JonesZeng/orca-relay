import assert from "node:assert/strict";
import test from "node:test";

import {
  adapterResponseForMobile,
  decodeAdapterFrame,
  encodeAdapterFrame,
  rawCloseToAdapterFrame,
  rawMessageToAdapterFrame,
} from "../src/protocol.mjs";

const attachment = {
  kind: "mobile-direct",
  clientId: "mobile-123",
  connectionId: "mobile-123",
};

test("raw text message becomes a client-to-server adapter frame", () => {
  const frame = rawMessageToAdapterFrame("hello", attachment);
  const decoded = decodeAdapterFrame(frame);

  assert.deepEqual(decoded.header, {
    clientId: "mobile-123",
    connectionId: "mobile-123",
    direction: "client_to_server",
    opcode: "text",
  });
  assert.equal(new TextDecoder().decode(decoded.payload), "hello");
});

test("raw binary message remains binary in an adapter frame", () => {
  const frame = rawMessageToAdapterFrame(new Uint8Array([0, 1, 255]), attachment);
  const decoded = decodeAdapterFrame(frame);

  assert.equal(decoded.header.opcode, "binary");
  assert.deepEqual([...decoded.payload], [0, 1, 255]);
});

test("server text response restores the raw mobile message", () => {
  const frame = encodeAdapterFrame(
    {
      clientId: "mobile-123",
      connectionId: "mobile-123",
      direction: "server_to_client",
      opcode: "text",
    },
    new TextEncoder().encode("ready"),
  );

  assert.deepEqual(adapterResponseForMobile(frame, attachment), {
    kind: "message",
    value: "ready",
  });
});

test("server close response restores a WebSocket close", () => {
  const frame = encodeAdapterFrame({
    clientId: "mobile-123",
    connectionId: "mobile-123",
    direction: "server_to_client",
    opcode: "close",
    closeCode: 1013,
    closeReason: "runtime unavailable",
  });

  assert.deepEqual(adapterResponseForMobile(frame, attachment), {
    kind: "close",
    code: 1013,
    reason: "runtime unavailable",
  });
});

test("raw close becomes a client-to-server close frame", () => {
  const frame = rawCloseToAdapterFrame(1001, "backgrounded", attachment);
  const decoded = decodeAdapterFrame(frame);

  assert.equal(decoded.header.opcode, "close");
  assert.equal(decoded.header.closeCode, 1001);
  assert.equal(decoded.header.closeReason, "backgrounded");
});

test("adapter responses cannot cross mobile connections", () => {
  const frame = encodeAdapterFrame(
    {
      clientId: "mobile-other",
      connectionId: "mobile-other",
      direction: "server_to_client",
      opcode: "binary",
    },
    new Uint8Array([1]),
  );

  assert.throws(() => adapterResponseForMobile(frame, attachment));
});
