# Orca Relay image assets

This directory contains public-safe metadata and prompts for README image generation. The final PNG files are intentionally not checked in by this step; generate them separately from the prompt files and place them at the exact paths below.

| Image | Prompt source | Expected PNG | Suggested README alt text |
| --- | --- | --- | --- |
| System design diagram | `assets/prompts/orca-relay-design-excalidraw.md` | `assets/orca-relay-design-excalidraw.png` | `Excalidraw-style Orca Relay architecture diagram showing a remote Orca CLI, local proxy, VPS relay, bridge, and local Orca runtime exchanging opaque WebSocket frames.` |
| Data-flow schematic | `assets/prompts/orca-relay-flow.md` | `assets/orca-relay-flow.png` | `Orca Relay data-flow schematic showing outbound and return WebSocket paths through a VPS relay, with payload bytes treated as opaque.` |
| GitHub cover image | `assets/prompts/orca-relay-cover.md` | `assets/orca-relay-cover.png` | `Orca Relay project cover art with abstract remote client, VPS relay, and local runtime infrastructure connected by secure WebSocket-style links.` |

## Generation notes

- Use the prompt files under `assets/prompts/` as the source of truth for image-generation copy.
- Do not create fake, blank, or placeholder PNG files. Only add PNGs after real image generation and review.
- Keep final images suitable for public GitHub documentation.
- Preserve the no-secret constraints in every generation pass: no real tokens, device tokens, public keys, pairing codes, hostnames, IP addresses, Cloudflare credentials, VPS addresses, private URLs, QR codes, or personal identifiers.
- If a placeholder value must be visible, use generic labels such as `env token`, `local WS`, `role=client`, or `role=server` exactly as allowed by the relevant prompt.
- Keep relay payload language honest: this project treats relay payload bytes as opaque and does not claim to encrypt, decrypt, or inspect Orca application payloads.
- Review generated text carefully. Labels and title text must be sharp, legible, correctly spelled, and limited to the label set in each prompt.

## Expected paths

Final reviewed images should be saved as:

- `assets/orca-relay-design-excalidraw.png`
- `assets/orca-relay-flow.png`
- `assets/orca-relay-cover.png`
