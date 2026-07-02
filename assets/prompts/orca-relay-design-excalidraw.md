# Orca Relay Excalidraw system design prompt

Expected output: `assets/orca-relay-design-excalidraw.png`

Use this prompt with `gpt-image-2` or an equivalent image-generation workflow. Do not generate an image from this documentation step, and do not create placeholder PNG files.

## Public-safety metadata

- Purpose: public GitHub README architecture diagram.
- Style: Excalidraw-style system design diagram.
- Aspect: wide 16:9.
- Primary alt text: `Excalidraw-style Orca Relay architecture diagram showing a remote Orca CLI, local proxy, VPS relay, bridge, and local Orca runtime exchanging opaque WebSocket frames.`
- Allowed labels: short component and invariant labels listed in the prompt below.
- Secret policy: no real tokens, device tokens, public keys, pairing payloads, raw pairing codes, hostnames, IP addresses, Cloudflare credentials, VPS addresses, private URLs, QR codes, or personal identifiers.
- Payload policy: relay payload bytes must be represented as opaque; do not imply the relay decrypts, parses, or inspects Orca application payloads.

## Prompt

Create a clean Excalidraw-style system design diagram for **Orca Relay**. The diagram should explain how existing Orca CLI WebSocket traffic can cross a VPS relay without modifying the Orca desktop app bundle.

Style: hand-drawn Excalidraw look, off-white canvas, rough black outlines, subtle pastel fills, simple icons, rounded rectangles, sketchy arrows, high whitespace, neat alignment, limited palette. Use solid-line boxes for current implemented components. Use dashed-line boxes only for optional future ideas. Keep all text short, sharp, legible, correctly spelled. Do not include long URLs, tokens, secrets, IP addresses, pairing payloads, or private credentials.

Composition: wide 16:9 architecture diagram, left-to-right flow with three vertical zones:

1. Left zone title: **Remote machine**
2. Center zone title: **VPS relay**
3. Right zone title: **Desktop machine**

Current implementation, all with solid borders:

- In the left zone, draw a terminal/laptop icon labeled **Orca CLI**.
- Below or beside it, draw a solid box labeled **local proxy**.
- In the center zone, draw a cloud/server box labeled **relay server**.
- In the right zone, draw a solid box labeled **bridge**.
- Beside the bridge, draw a desktop/app box labeled **Orca runtime**.
- Add a small solid utility box near the left bottom labeled **pairing rewrite**.

Arrows and labels:

- Arrow from **Orca CLI** to **local proxy**, label: **raw WS**.
- Arrow from **local proxy** to **relay server**, label: **client role**.
- Arrow from **relay server** to **bridge**, label: **server role**.
- Arrow from **bridge** to **Orca runtime**, label: **local WS**.
- Add reverse arrows or double-headed arrows where helpful to show bidirectional messaging.
- Near the long relay path, add a small note bubble labeled **opaque frames**.
- Near that note bubble, add a tiny frame strip with short labels only: **header** + **payload**.
- Near the frame strip, add tiny chips: **clientId**, **connId**, **opcode**.
- From **pairing rewrite** to **local proxy**, draw a small arrow labeled **endpoint only**.

Security / invariants callouts, short labels only:

- Add a small lock icon near the relay connection labeled **env token**.
- Add a small sealed-envelope icon near payload path labeled **payload opaque**.
- Add a small warning-free checkmark near pairing rewrite labeled **keeps keys**.

Optional future ideas, dashed borders only, visually secondary and placed along the bottom or far right:

- Dashed box labeled **client pool**.
- Dashed box labeled **metrics**.
- Dashed box labeled **multi bridge**.

Important visual constraints:

- Current components must use solid borders: **Orca CLI**, **local proxy**, **relay server**, **bridge**, **Orca runtime**, **pairing rewrite**.
- Future ideas must use dashed borders: **client pool**, **metrics**, **multi bridge**.
- Labels must be short; no paragraphs inside the image.
- Do not draw or write any real token, device token, public key, long pairing code, long WebSocket URL, hostname, or IP address.
- Do not imply the relay decrypts or inspects payloads. The relay should visually route frames only.
- Make the final diagram suitable as a public GitHub README asset.

## Suggested negative prompt

No photorealism, no 3D render, no dense text, no tiny unreadable labels, no code blocks, no terminal logs, no real credentials, no long URLs, no private hostnames, no IP addresses, no QR codes, no actual pairing code, no token string, no cluttered arrows, no dark background.

## Review checklist

- Final PNG is saved only after real generation at `assets/orca-relay-design-excalidraw.png`.
- No placeholder image is committed.
- All labels are legible and correctly spelled.
- No generated detail resembles a real secret, endpoint, IP address, pairing payload, or credential.
- Diagram communicates that relay frames carry opaque payload bytes.
