const HEADER_LENGTH_BYTES = 4;
const MAX_ADAPTER_HEADER_BYTES = 64 * 1024;

export const MAX_SERVER_ID_LENGTH = 128;

export function isValidIdentifier(value) {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= MAX_SERVER_ID_LENGTH &&
    /^[A-Za-z0-9._-]+$/.test(value)
  );
}

export function encodeAdapterFrame(header, payload = new Uint8Array()) {
  const headerBytes = new TextEncoder().encode(JSON.stringify(header));
  if (headerBytes.byteLength > MAX_ADAPTER_HEADER_BYTES) {
    throw new Error("adapter header exceeds the allowed size");
  }

  const body = asBytes(payload);
  const frame = new Uint8Array(HEADER_LENGTH_BYTES + headerBytes.byteLength + body.byteLength);
  new DataView(frame.buffer).setUint32(0, headerBytes.byteLength, false);
  frame.set(headerBytes, HEADER_LENGTH_BYTES);
  frame.set(body, HEADER_LENGTH_BYTES + headerBytes.byteLength);
  return frame;
}

export function decodeAdapterFrame(value) {
  const frame = asBytes(value);
  if (frame.byteLength < HEADER_LENGTH_BYTES) {
    throw new Error("adapter frame is shorter than its header length prefix");
  }

  const headerLength = new DataView(
    frame.buffer,
    frame.byteOffset,
    frame.byteLength,
  ).getUint32(0, false);
  if (headerLength === 0 || headerLength > MAX_ADAPTER_HEADER_BYTES) {
    throw new Error("adapter frame has an invalid header length");
  }

  const headerEnd = HEADER_LENGTH_BYTES + headerLength;
  if (headerEnd > frame.byteLength) {
    throw new Error("adapter frame header is truncated");
  }

  let header;
  try {
    header = JSON.parse(
      new TextDecoder("utf-8", { fatal: true }).decode(
        frame.subarray(HEADER_LENGTH_BYTES, headerEnd),
      ),
    );
  } catch {
    throw new Error("adapter frame header is not valid UTF-8 JSON");
  }

  if (!header || typeof header !== "object" || Array.isArray(header)) {
    throw new Error("adapter frame header must be an object");
  }
  if (
    !isValidIdentifier(header.clientId) ||
    !isValidIdentifier(header.connectionId) ||
    !["client_to_server", "server_to_client"].includes(header.direction) ||
    !["text", "binary", "close"].includes(header.opcode)
  ) {
    throw new Error("adapter frame header has invalid routing fields");
  }

  return {
    header,
    payload: frame.subarray(headerEnd),
  };
}

export function rawMessageToAdapterFrame(message, attachment) {
  if (typeof message === "string") {
    return encodeAdapterFrame(
      {
        clientId: attachment.clientId,
        connectionId: attachment.connectionId,
        direction: "client_to_server",
        opcode: "text",
      },
      new TextEncoder().encode(message),
    );
  }

  return encodeAdapterFrame(
    {
      clientId: attachment.clientId,
      connectionId: attachment.connectionId,
      direction: "client_to_server",
      opcode: "binary",
    },
    asBytes(message),
  );
}

export function rawCloseToAdapterFrame(code, reason, attachment) {
  return encodeAdapterFrame({
    clientId: attachment.clientId,
    connectionId: attachment.connectionId,
    direction: "client_to_server",
    opcode: "close",
    closeCode: Number.isInteger(code) ? code : 1000,
    closeReason: String(reason ?? "").slice(0, 123),
  });
}

export function adapterResponseForMobile(frame, attachment) {
  const { header, payload } = decodeAdapterFrame(frame);
  if (
    header.clientId !== attachment.clientId ||
    header.connectionId !== attachment.connectionId ||
    header.direction !== "server_to_client"
  ) {
    throw new Error("adapter response does not belong to this mobile connection");
  }

  if (header.opcode === "text") {
    return {
      kind: "message",
      value: new TextDecoder("utf-8", { fatal: true }).decode(payload),
    };
  }
  if (header.opcode === "binary") {
    return { kind: "message", value: payload };
  }
  return {
    kind: "close",
    code: Number.isInteger(header.closeCode) ? header.closeCode : 1000,
    reason: String(header.closeReason ?? "").slice(0, 123),
  };
}

function asBytes(value) {
  if (value instanceof Uint8Array) {
    return value;
  }
  if (value instanceof ArrayBuffer) {
    return new Uint8Array(value);
  }
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  throw new Error("expected a binary WebSocket message");
}
