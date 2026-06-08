# Blockquote copy-button test suite

Canonical input for manually testing the hover copy-icon button on Claude's
rendered blockquotes (see `BlockquoteScanner.swift` + `ClaudeTerminalView.swift`).
A copy icon appears at the top-right of whichever blockquote the pointer is over;
clicking it copies the dequoted text and flashes a checkmark. Always test with the
exact text below so results are comparable run to run, and refer to failures by
**case number**.

## How to run

1. `swift run DraftFrame`
2. In a session, paste this prompt to the session's Claude:

   > Reply with the following markdown **verbatim** — do not summarize, comment,
   > or wrap it in a code block. Output exactly these lines:
   >
   > (then paste the **Source markdown** block below)

3. Hover each rendered blockquote and check it against the **Expectations** table.
4. Regression check: after Claude renders the suite, send any short follow-up
   message, then hover an earlier block that's still on screen — the button must
   still work (this is the JSONL-volatility regression we fixed by scraping the
   buffer instead of the session log).

## Source markdown

Paste everything between the lines (the numbered headers are plain prose; only
the `>` lines should render with a quote bar):

---

1. Single-line block:

> This single line stands completely alone.

2. Two-line block:

> First line of a compact block.
> Second line right below it.

3. Three-line block:

> Alpha is the first quoted line.
> Beta is the second quoted line.
> Gamma is the third quoted line.

4. Nested blockquote (copy strips all markers):

> Top level quote.
>> Nested one level deeper.
>>> And a third level down.

5. Long line that soft-wraps across rows:

> This is a deliberately long blockquote line written to exceed the terminal width so it soft-wraps onto two or more rows, letting us confirm hovering any wrapped row still copies the block.

6. Two blocks separated by one prose line:

> Block six-A, the upper one.

A single sentence of prose between them.

> Block six-B, the lower one.

7. Two blocks separated by only a blank line (must stay distinct):

> Block seven-A, above the gap.

> Block seven-B, below the gap.

8. Block followed immediately by prose, no blank line:

> Quote eight, butted against prose.
This prose line directly follows the quote with no blank line.

9. Multi-paragraph block with an empty quoted line in the middle:

> Paragraph one inside the quote.
>
> Paragraph two after a blank quoted line.

10. Very short block:

> ok

11. Inline markdown, punctuation, and special characters:

> "Edge cases!" she said — with `inline code`, **bold**, 50% signs, and a trailing colon: keep it verbatim.

12. Block at the very bottom, just above the input prompt:

> Last quote in the reply, immediately above the prompt box.

---

## Expectations

Copied text = bar glyphs stripped, one terminal row per line, joined by `\n`,
trailing blank quoted lines trimmed.

| # | Case | Button? | Expected copied text |
|---|------|-------|----------------------|
| 1 | Single line | yes | `This single line stands completely alone.` |
| 2 | Two lines | yes | `First line of a compact block.`⏎`Second line right below it.` |
| 3 | Three lines | yes | the three `Alpha/Beta/Gamma` lines, `\n`-joined |
| 4 | Nested | yes | `Top level quote.`⏎`Nested one level deeper.`⏎`And a third level down.` (no `>`) |
| 5 | Soft-wrap | yes | the long sentence, **one line per visual row** (line breaks at each wrap point) |
| 6A/6B | Prose-separated | yes, two distinct | each copies only its own one line |
| 7A/7B | Blank-line-separated | yes, **two distinct blocks** (must NOT merge across the gap) | each copies only its own one line |
| 8 | Butted against prose | yes | renderer-dependent: the scraper copies exactly the rows Claude draws with a bar. Markdown lazy continuation may pull the following prose line *into* the quote (bar present → included); if Claude renders it without a bar, it's excluded. Record the actual result. |
| 9 | Internal blank quoted line | yes | `Paragraph one inside the quote.`⏎(empty)⏎`Paragraph two after a blank quoted line.` |
| 10 | Very short (`ok`) | yes (by design now; was previously suppressed) | `ok` |
| 11 | Special chars | yes | the sentence verbatim, incl. `—`, `%`, backticks/asterisks as rendered |
| 12 | Bottom, above prompt | yes | `Last quote in the reply, immediately above the prompt box.` |

Negative checks (no button should appear on hover):

- Hovering any **numbered header** or other prose line.
- Hovering the **input prompt box** or a **tool-call frame** (these use box-drawing
  `│`/`┃`, which the scanner ignores).

## Notes / known caveats

- **Case 5 (soft-wrap):** copied text breaks at each visual wrap. Claude Code draws
  the bar on every wrapped row, so the screen has no single logical line to recover;
  this is faithful to what's displayed.
- **Case 11 (inline markdown):** `**bold**`/`` `code` `` may render as styled text
  without the literal `*`/`` ` `` characters; copied text reflects the rendered
  glyphs, not the raw markdown source.
- Detection keys on left block-element bars (`▏▎▍▌▋▊▉`). If a future Claude Code
  version renders the quote bar with a different glyph, add it to
  `BlockquoteScanner.barGlyphs`.
