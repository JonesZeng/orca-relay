# Orca Relay GitHub cover prompt

Expected output: `assets/orca-relay-cover.png`

Use this prompt with `gpt-image-2` or an equivalent image-generation workflow. Do not generate an image from this documentation step, and do not create placeholder PNG files.

## Public-safety metadata

- Purpose: public GitHub README cover image.
- Style: modern infrastructure/tooling hero artwork.
- Aspect: wide 16:9.
- Primary alt text: `Orca Relay project cover art with abstract remote client, VPS relay, and local runtime infrastructure connected by secure WebSocket-style links.`
- Text rule: the only readable text in the image should be `Orca Relay`.
- Secret policy: no real tokens, device tokens, public keys, pairing payloads, raw pairing codes, hostnames, IP addresses, Cloudflare credentials, VPS addresses, private URLs, QR codes, or personal identifiers.
- Payload policy: packet/frame traces should remain abstract and opaque; do not imply payload inspection.

## Generation settings

- Model: `gpt-image-2`
- Aspect ratio: `16:9`
- Suggested size: wide GitHub/README cover, e.g. `1536x864` or nearest available 16:9 export
- Text to render: `Orca Relay`
- Text rule: render only the title text `Orca Relay`; no subtitle, labels, captions, UI copy, numbers, logos, badges, or watermarks.

## Prompt

Create a modern GitHub project cover image for an infrastructure/tooling project named **Orca Relay**.

The image should communicate: a secure WebSocket relay that lets a local Orca runtime and remote CLI clients communicate through a small VPS relay, without modifying the Orca app bundle. Show the idea as abstract infrastructure, not as a cute mascot.

Visual direction:

- A polished, technical hero image for an open-source developer tool.
- Dark navy / deep graphite background with subtle grain and a faint blueprint grid.
- Three abstract infrastructure zones arranged left-to-right:
  1. left: a remote terminal/client node represented by a minimal glowing command-line window or small server tile,
  2. center: a compact VPS relay node represented by a luminous routing core,
  3. right: a local workstation/runtime node represented by a desktop/server tile.
- Connect the three zones with clean cyan/teal WebSocket-like arcs or fiber lines, passing through the central relay node.
- Add a few thin packet/frame traces along the links, using small rectangular pulses; keep them abstract and payload-opaque, not readable text.
- Include a very subtle orca-inspired shape only as an elegant wave/dorsal-fin silhouette integrated into the central relay glow or background negative space. It must not look like a cartoon mascot or animal illustration.
- Use crisp vector-like geometry, soft volumetric glow, high contrast, and careful spacing.
- Overall mood: reliable, secure, fast, developer-focused, cloud/VPS networking, command-line tooling.

Composition:

- Wide 16:9 cover, centered hero composition with generous margins for GitHub README use.
- Place the title **Orca Relay** large and sharp near the lower-left or centered-lower third, with strong contrast and excellent legibility.
- Use only the title text **Orca Relay** in the image. No other words or symbols that resemble text.
- Keep the title unobstructed, with a clean dark area behind it.
- Avoid clutter; prioritize a memorable silhouette that still reads at small GitHub preview sizes.

Style:

- Modern infrastructure illustration, premium open-source tooling aesthetic.
- Semi-flat vector shapes mixed with soft gradients and subtle glassmorphism.
- Color palette: deep navy, graphite black, muted indigo, electric cyan, teal, small hints of cool white.
- No brand logos, no GitHub logo, no Cloudflare logo, no real company marks.
- No real IP addresses, URLs, tokens, QR codes, or credentials.

Negative constraints:

- Do not make a mascot-heavy image.
- Do not draw a cute whale/orca character.
- Do not include people, hands, faces, boats, ocean scenery, splashes, or nature-poster elements.
- Do not include dense code screenshots, illegible paragraphs, mock UI text, random letters, badges, or labels.
- Do not include extra title variants, subtitles, taglines, watermarks, signatures, or spelling mistakes.
- Do not imply payload inspection; packet traces should be opaque abstract blocks only.

Quality requirements:

- The title text **Orca Relay** must be sharp, legible, correctly spelled, and the only readable text.
- The image should feel like a serious developer infrastructure project cover, suitable for the top of a public GitHub README.
- Final artwork should be clean enough to crop or downscale while preserving the relay-node concept.

## Review checklist

- Final PNG is saved only after real generation at `assets/orca-relay-cover.png`.
- No placeholder image is committed.
- The only readable text is exactly `Orca Relay`.
- No generated detail resembles a real secret, endpoint, IP address, pairing payload, credential, logo, or watermark.
- Artwork communicates abstract relay infrastructure without suggesting payload inspection.
