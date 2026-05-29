# terminal-example casts

Each `<id>.js` here is a self-registering cast for the
`{% include terminal_example.html cast="<id>" %}` panel. The
engine is in `../terminal_example.js`; the include lives at
`../../_includes/terminal_example.html`.

## Adding a new cast

1. Create `docs/assets/casts/<id>.js`. Register the cast with:

   ```js
   (function () {
     window.attyTerminalCasts = window.attyTerminalCasts || {};
     window.attyTerminalCasts['<id>'] = function (api) {
       return async function play(myRun) {
         while (api.alive(myRun)) {
           api.screen.innerHTML = '';
           // … build lines via api.el / api.span / api.typeInto …
           // ALWAYS guard awaits with: if (!api.alive(myRun)) return;
           // Use api.setActiveCaret(line) to move the cursor —
           // never api.caret() + manual remove (that's the bug
           // closed in #350).
           await api.sleep(1200);
         }
       };
     };
   })();
   ```

2. Embed in a page (markdown or HTML):

   ```liquid
   {% include terminal_example.html
        cast="<id>"
        title="~/code/atty — atty bash"
        rows_em=17
        caption="Optional one-line caption under the panel." %}
   ```

## API (passed to your cast factory)

| Field              | What                                                            |
|--------------------|-----------------------------------------------------------------|
| `screen`           | The `.demo-body` DOM node. Clear via `screen.innerHTML = ''`.   |
| `sleep(ms)`        | Cancellable timeout (returns Promise).                          |
| `el(cls, text?)`   | `<div class="cls">text</div>`.                                  |
| `span(cls, text?)` | `<span class="cls">text</span>`.                                |
| `caret()`          | Bare `<span class="caret">`. Prefer `setActiveCaret`.           |
| `setActiveCaret(n)`| Remove any existing caret from this panel + add fresh on `n`.   |
| `typeInto(myRun, node, text, cps?)` | Per-char typing with jitter. Default 22 cps. |
| `alive(myRun)`     | `false` after replay-button restart — bail your await loop.     |

## Style guide

- Each scene clears `screen.innerHTML` at the top of the loop iteration.
- Use `setActiveCaret`, not bare `caret()` + manual remove — single caret invariant per #350.
- Honour `api.alive(myRun)` between EVERY `await`. Without that guard, restart races leak typing into the new screen.
- Pick `rows_em` so the script comfortably fits the body — playback that overflows will scroll inside the panel (overflow-y: auto) instead of growing the page.

## Casts on the site today

| ID    | Where         | What it shows                                              |
|-------|---------------|------------------------------------------------------------|
| hero  | `/`           | atuin ghost · guardrail prompt · `#:` rewrite              |
| llm   | `/llm/`       | Alt+A single · inline chat collapsed exec stub · Alt+R recall |
