# site/

Static site for disinto.ai.

## Files

- `index.html` — landing page
- `dashboard.html` — live factory metrics dashboard
- `docs/quickstart.html` — quickstart guide (from zero to first automated PR)
- `docs/architecture.html` — architecture overview (agent loop, phase protocol, vault)
- `og-image.jpg` — Open Graph image used for social sharing previews (`og:image` / `twitter:image`)
- `al76.jpg` / `al76.webp` — hero image (Robot AL-76)
- `favicon.ico`, `favicon-192.png`, `apple-touch-icon.png` — favicons

## Regenerating og-image.jpg

`og-image.jpg` is a static binary asset committed to the repo. It is not
generated at build time. The recommended dimensions are **1200×630 px** (the
standard Open Graph image size).

To regenerate it:

1. Open a design tool (Figma, GIMP, Inkscape, etc.).
2. Create a canvas at 1200×630 px using the site color palette:
   - background `#0a0a0a`, foreground `#e0e0e0`, accent `#c8a46e`
3. Include the Disinto logotype / tagline and any relevant branding.
4. Export as JPEG (quality ≥ 85) and save to `site/og-image.jpg`.
5. Commit the updated file.

## Updating og-image.jpg when branding changes

Whenever the brand identity changes (logo, color palette, tagline), update
`og-image.jpg` following the steps above. Checklist:

- [ ] New image is 1200×630 px
- [ ] Colors match the current CSS variables in `index.html` (`:root` block)
- [ ] Tagline / copy matches the `<title>` and `<meta name="description">` in `index.html`
- [ ] File committed and pushed before deploying the updated `index.html`

Social platforms cache og:image aggressively. After deploying, use the
[Open Graph debugger](https://developers.facebook.com/tools/debug/) and
[Twitter Card validator](https://cards-dev.twitter.com/validator) to
invalidate their caches.
