# Posting findings as PR comments

Only when the user asks. Follow their framing instructions exactly (e.g. "frame
as a question", "mark as not urgent") — the framing carries meaning to the team.
Post before removing the review worktree: line anchors come from the diff and
the worktree.

## Writing style — every comment

- Very simple language. Short sentences.
- Bullet points; one idea per line. Break long sentences into points and
  sub-points.
- Structure: what is wrong → why it matters → the fix.
- No severity labels, verdict words, or internal codes in the text unless the
  user asks.
- Suggest a fix whenever one exists — unless the user said "review only", in
  which case describe the defect and stop.
- A design or product doubt is posted as a question ("Is this intended?"),
  not as a defect.

## Mechanics

Write `review.json` (shape below), then post it with
`scripts/post-review.sh review.json`. The script checks every anchor against
`diff.patch` with the same logic as `scripts/anchor.sh`, fills `commit_id`
from the reviewed head, refuses to post if the PR head moved since the diff
was taken (`--force` overrides that one check; use it only after re-reading
the new commits), and prints the posted set afterwards. `--dry-run` shows the
validated JSON without posting. Underneath it is one API call:

```bash
gh api repos/OWNER/REPO/pulls/PR_NUMBER/reviews --input review.json
```

`review.json`:

```json
{
  "commit_id": "HEAD_SHA_THE_DIFF_WAS_COMPUTED_FROM",
  "event": "COMMENT",
  "body": "Short summary. Also carries findings that cannot be anchored inline.",
  "comments": [
    { "path": "src/file.ts", "line": 42, "side": "RIGHT", "body": "..." },
    { "path": "src/file.ts", "line": 17, "side": "LEFT", "body": "comment on a deleted line" },
    { "path": "src/file.ts", "start_line": 10, "start_side": "RIGHT",
      "line": 25, "side": "RIGHT", "body": "..." }
  ]
}
```

Rules that will bite you if ignored:

1. **Inline comments only land on lines that are in the diff.** A finding in an
   untouched file goes into the review `body`, not `comments`.
2. **Line numbers follow `side`.** `side: "RIGHT"` takes new-file numbers
   (the finder's `NEW:<n>`); `side: "LEFT"` takes old-file numbers (`OLD:<n>`)
   and is the only way to anchor on a deleted line. Compute them from the diff
   hunk headers; do not guess.
3. Multi-line comments need `start_line` + `line` (start < end, same hunk).
4. Set `commit_id` to the head SHA you diffed (Phase 0 `headRefOid`). If the
   PR moved since, re-fetch and recompute anchors first; posting against a
   stale SHA either fails or lands on the wrong lines.
5. Never resolve, edit, or delete a comment a human wrote. Reply in the thread
   instead.

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
6. Suggestions only on `side: "RIGHT"` anchors. A deleted line cannot carry a
   suggestion; describe the restore in prose.

## After posting

`post-review.sh` prints one line per comment:
`<path>:<start>-<line> side=<RIGHT|LEFT> suggestion=<yes|no>` (no `<start>-`
for a single-line comment). To re-check later from GitHub's side:

```bash
gh api "repos/OWNER/REPO/pulls/PR_NUMBER/comments?per_page=100" \
  --jq '.[] | "\(.path):\(if .start_line then "\(.start_line)-" else "" end)\(.line) side=\(.side) suggestion=\(if (.body | contains("```suggestion")) then "yes" else "no" end)"'
```

Report the posted comment set to the user as a short table: finding → anchor →
suggestion yes/no.
