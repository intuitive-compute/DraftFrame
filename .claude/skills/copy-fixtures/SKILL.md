---
name: copy-fixtures
description: Print a fixed set of terminal fixtures for manually testing DraftFrame's selection copy (issue #25, LogicalLineJoiner). Run this inside a Claude Code session in DraftFrame, then drag-select each block, Cmd+C, and paste into a shell or editor to confirm wrapped rows re-join as logical lines while lists, tables and diffs keep their line breaks.
---

# Copy fixtures

You are running inside DraftFrame's terminal. The human wants specific shapes
drawn on screen so they can select them and press Cmd+C. Your job is
reproduction, not authoring. Do exactly two things and nothing else.

**Step 1.** Call the Bash tool once, with this command verbatim as a single
string (it only echoes; it needs no network and changes nothing):

echo "refactor the wrapper" && printf '%s\n' "the quick brown fox jumps over the lazy dog while this tool header wraps onto a second and third visual row of the terminal at any sensible window width"

**Step 2.** Reply with the text between the BEGIN and END lines below,
character for character. Do not include the BEGIN and END lines. Do not add a
greeting, a summary, a closing sentence, headings of your own, or any
sentence that is not already in the text. Do not reflow, shorten, or
"improve" the wording: the line lengths are the test. Do not wrap any of it
in a code fence except the one block that is already fenced.

BEGIN
COPY FIXTURES. Select each block, Cmd+C, paste into a shell or editor, compare with the Expected line. Pasted text must start at its first character with no leading gutter spaces.

1. The ⏺ Bash( header above. Expected: pastes as ONE line containing the whole echo command. Repeat it starting the drag on the "e" of "echo" instead of column 0. Expected: still ONE line.

2. Terminals draw text into a fixed grid of cells, so any line longer than the grid is wrapped by the terminal itself, but some programs wrap the text on their own before it ever reaches the terminal and emit each visual row as a separate line. Expected: this paragraph pastes as ONE line.

3. https://example.com/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/bbb.tar.gz then more words. Expected: ONE line with NO space anywhere inside the URL, and a space before "then".

4. Lists:
- Read the buffer line by line and note which rows carry the wrapped flag so that the copy path can decide where the logical line boundaries actually are in the output
- Short second item
1. Numbered item
2. Another one
Expected: the first bullet is ONE line; every other item stays on its own line.

5. Table:
| id    | UUID   | Stable identifier for the session row, never reused |
|-------|--------|------------------------------------------------------|
| title | String | Display name shown in the sidebar and the tab strip  |
Expected: three lines, none glued to the previous one.

6. Code:
```swift
guard let session = sessions.first(where: { $0.id == id }) else { return nil }
let value = computeSomething(from: input, options: options, strict: true)
return value
```
Expected: three lines.

7. Fixed the 🐛 in parser.swift and updated the 日本語 handling so the ✅ status renders at the right column even when the row wraps onto the next line of the terminal display. Expected: ONE line, glyphs intact.

Done. Also try the Quick Terminal: seq 1 5 there must copy as five lines.
END
