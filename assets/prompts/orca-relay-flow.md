# Orca Relay data-flow schematic prompt

Expected output: `assets/orca-relay-flow.png`

Use this prompt with `gpt-image-2` or an equivalent image-generation workflow. Do not generate an image from this documentation step, and do not create placeholder PNG files.

## Public-safety metadata

- Purpose: public GitHub README data-flow diagram.
- Style: clean Excalidraw-style technical schematic.
- Aspect: wide 16:9.
- Primary alt text: `Orca Relay data-flow schematic showing outbound and return WebSocket paths through a VPS relay, with payload bytes treated as opaque.`
- Allowed labels: use only the compact labels listed below unless a generation workflow requires an equivalent short placeholder.
- Secret policy: no real tokens, device tokens, public keys, pairing payloads, raw pairing codes, hostnames, IP addresses, Cloudflare credentials, VPS addresses, private URLs, QR codes, or personal identifiers.
- Payload policy: relay payload bytes must be represented as opaque; do not imply the relay decrypts, parses, or inspects Orca application payloads.

## Prompt

Create a clean Excalidraw-style technical schematic for the Orca Relay data path. White or very light warm background, thin hand-drawn dark gray outlines, soft pastel fills, plenty of whitespace, simple icons, and crisp short labels. Use a wide 16:9 composition suitable for a GitHub README image. Keep all text sharp, legible, correctly spelled, and minimal.

Layout left to right with five main rounded boxes:

1. Remote side box: label `Remote machine`; inside it place two small stacked nodes labeled `Orca CLI` and `Local proxy`.
2. Internet/VPS middle box: label `VPS relay`; inside it place one node labeled `Relay /ws`.
3. Local desktop side box: label `Desktop machine`; inside it place two small stacked nodes labeled `Bridge` and `Orca runtime`.

Draw the primary outbound path as thick blue arrows moving left to right:
`Orca CLI` -> `Local proxy` -> `Relay /ws` -> `Bridge` -> `Orca runtime`.

Draw the return path as thick green arrows moving right to left underneath the outbound path:
`Orca runtime` -> `Bridge` -> `Relay /ws` -> `Local proxy` -> `Orca CLI`.

Add a small lock icon near the relay arrows with the label `WSS + bearer token`. Do not show any real token value, secret, IP address, hostname, or credential. If a value is needed, use only placeholders such as `env token` or `local ws`.

Add one compact callout near the relay in a dashed note box:
`Frame: header + opaque payload`
Under it, in smaller text:
`payload bytes are not inspected`

Add tiny labels on the adapter arrows, not too many:

- Between `Local proxy` and `Relay /ws`: `role=client`
- Between `Relay /ws` and `Bridge`: `role=server`
- Between `Orca CLI` and `Local proxy`: `local WS`
- Between `Bridge` and `Orca runtime`: `local WS`

Use visual hierarchy: the five nodes should be the clearest elements, arrows second, notes third. Avoid clutter, long paragraphs, code blocks, terminal screenshots, real URLs, real hostnames, real ports, QR codes, secrets, mascots, photorealism, 3D rendering, dark mode, and dense network-dashboard styling.

The final image should communicate: an existing Orca CLI talks to a local proxy; the proxy and bridge wrap WebSocket messages through a VPS relay; the bridge reaches the real local Orca runtime; replies travel back over the same relay path; the relay treats application payloads as opaque.

## Suggested generation settings

- Model: `gpt-image-2`
- Size/aspect: `1536x1024` or 16:9 crop-safe
- Quality: medium
- Intended file: `assets/orca-relay-flow.png`

## Text labels that may appear in the image

- `Remote machine`
- `Orca CLI`
- `Local proxy`
- `VPS relay`
- `Relay /ws`
- `Desktop machine`
- `Bridge`
- `Orca runtime`
- `local WS`
- `role=client`
- `role=server`
- `WSS + bearer token`
- `Frame: header + opaque payload`
- `payload bytes are not inspected`

## Negative constraints

Do not render real secrets, tokens, IP addresses, private credentials, personal names, terminal commands, full configuration snippets, or long URLs. Do not imply that the relay decrypts or parses Orca application content. Do not add extra components such as databases, queues, browsers, Cloudflare logos, Kubernetes, TLS certificate internals, or monitoring dashboards.

## Review checklist

- Final PNG is saved only after real generation at `assets/orca-relay-flow.png`.
- No placeholder image is committed.
- All labels are legible and correctly spelled.
- No generated detail resembles a real secret, endpoint, IP address, pairing payload, or credential.
- Diagram communicates bidirectional relay flow and opaque payload bytes.
