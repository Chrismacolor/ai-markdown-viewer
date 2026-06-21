# docs/

Assets for the README.

## screenshot.png

The hero image shown at the top of the main README. To add it:

1. Open a good-looking Markdown file in Margins (something with a heading, a
   list, a code block, and a table reads well — `/tmp/margins_smoke.md` or this
   repo's `README.md` both work).
2. Capture **just the window**: press `⇧⌘4`, then `Space`, then click the
   Margins window. macOS saves a clean shot with the rounded corners and shadow.
3. Save/rename it to `docs/screenshot.png`.
4. In the top-level `README.md`, uncomment the image line:
   `![Margins rendering a Markdown document](docs/screenshot.png)`

Guidance:

- Use a Retina display if you can — the 2x capture looks crisp on GitHub.
- Light or dark theme is fine; dark tends to pop more in a README.
- Aim for a reasonably wide window (~1000–1200 pt) so the typography shows.
- Optional: add `docs/demo.gif` (a few seconds of live reload + Find) and embed
  it the same way for an even stronger first impression.
