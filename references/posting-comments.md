# Posting findings as PR comments

Only when the user asks. Follow their framing instructions exactly (e.g. "frame
as a question", "mark as not urgent") — the framing carries meaning to the team.

## Writing style — every comment

- Very simple language. Short sentences.
- Bullet points; one idea per line. Break long sentences into points and
  sub-points.
- Structure: what is wrong → why it matters → the fix.
- No severity labels or internal codes in the text unless the user asks.
- Suggest a fix whenever one exists.

## Mechanics

Post one review with all inline comments in a single API call:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews --input review.json
```

`review.json`:

```json
{
  "event": "COMMENT",
  "body": "Short summary. Also carries findings that cannot be anchored inline.",
  "comments": [
    { "path": "src/file.ts", "line": 42, "side": "RIGHT", "body": "..." },
    { "path": "src/file.ts", "start_line": 10, "start_side": "RIGHT",
      "line": 25, "side": "RIGHT", "body": "..." }
  ]
}
```

Rules that will bite you if ignored:

1. **Inline comments only land on lines that are in the diff.** A finding in an
   untouched file goes into the review `body`, not `comments`.
2. **Line numbers are new-file line numbers** (`side: "RIGHT"`). Compute them
   from the diff hunk headers; do not guess.
3. Multi-line comments need `start_line` + `line` (start < end, same hunk).

## GitHub suggested changes (`suggestion` blocks)

When the user wants one-click-committable fixes, use fenced `suggestion` blocks
inside the comment body:

````markdown
```suggestion
replacement content
```
````

Rules:

1. A suggestion **replaces exactly the anchored line(s)**. For a multi-line fix,
   anchor the comment with `start_line`/`line` spanning precisely the lines the
   replacement covers — nothing more, nothing less.
2. The replacement must be the FULL new content for that range, with exact
   indentation, including unchanged neighbor lines inside the range.
3. A fix that also needs changes outside the anchored range (a new import at the
   top of the file, a change in another file) cannot be a complete suggestion.
   Either find a self-contained form (e.g. an inline `import('...')` type
   annotation instead of a top-of-file import) or explain the remaining step in
   prose after the suggestion block.
4. **You cannot change a comment's anchor by editing it.** To convert an
   existing single-line comment into a multi-line suggestion: post the new
   comment (new review) first, then delete the old one
   (`gh api -X DELETE repos/OWNER/REPO/pulls/comments/COMMENT_ID`).
   Editing in place (`gh api -X PATCH ... -f body='...'`) works only when the
   existing anchor already equals the lines the suggestion replaces.
5. If a suggestion changes runtime behavior (not just cleanup), tell the user
   which tests to re-run after applying it.

## After posting

Verify the comments landed with the right anchors:

```bash
gh api "repos/OWNER/REPO/pulls/PR_NUMBER/comments?per_page=100" \
  --jq '.[] | "\(.path):\(.start_line // "-")-\(.line) suggestion=\(.body | contains("```suggestion"))"'
```

Report the posted comment set to the user as a short table: finding → anchor →
suggestion yes/no.
