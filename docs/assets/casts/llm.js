// llm cast — demonstrates the three LLM entry points: Alt+A
// single rewrite, Alt+S dialog with the inline observation
// stub, and Alt+R recall with the first-user-line preview.
(function () {
  window.attyTerminalCasts = window.attyTerminalCasts || {};
  window.attyTerminalCasts['llm'] = function (api) {
    return async function play(myRun) {
      while (api.alive(myRun)) {
        api.screen.innerHTML = '';

        // Scene 1: Alt+A single-prompt rewrite.
        var l1 = api.el('line');
        l1.append(api.span('prompt', '$ '));
        var typed1 = api.span('typed', '');
        l1.append(typed1);
        api.setActiveCaret(l1);
        api.screen.append(l1);
        await api.typeInto(myRun, typed1, '#: list zig files modified this week', 24);
        if (!api.alive(myRun)) return;
        await api.sleep(500);
        if (!api.alive(myRun)) return;
        api.screen.append(api.el('line dim', '  ↪ Alt+A → single rewrite · Alt+S → dialog · Alt+C → inline chat'));
        await api.sleep(1200);
        if (!api.alive(myRun)) return;
        typed1.textContent = 'find src -name "*.zig" -mtime -7';
        await api.sleep(1800);
        if (!api.alive(myRun)) return;

        // Scene 2: inline chat panel (Alt+C) — atty: exec turn
        // collapses its observation to a compact stub.
        var hint = api.el('line dim', '');
        hint.textContent = '─── inline chat panel (Alt+C) ───';
        api.screen.append(hint);
        var ask = api.el('line');
        ask.append(api.span('prompt', 'You:'));
        ask.append(document.createTextNode(' fix the failing test in atoms.rs'));
        api.screen.append(ask);
        await api.sleep(800);
        if (!api.alive(myRun)) return;
        var atty = api.el('line');
        atty.append(api.span('prompt', 'atty:'));
        atty.append(document.createTextNode(' run the test to see the failure'));
        api.screen.append(atty);
        var cmd = api.el('line dim');
        cmd.textContent = '      $ cargo test atoms::parser';
        api.screen.append(cmd);
        await api.sleep(700);
        if (!api.alive(myRun)) return;
        var out = api.el('line dim');
        out.textContent = 'Output: [42 lines · Alt+Shift+C to inspect]';
        api.screen.append(out);
        await api.sleep(1800);
        if (!api.alive(myRun)) return;

        // Scene 3: Alt+R recall — picker shows first user line
        // of each persisted dialog.
        api.screen.append(api.el('line dim', '─── Alt+R recall picker ───'));
        var rows = [
          ['▶', '  1.', '2026-05-29 09:12', '· fix the failing test in atoms.rs'],
          [' ', '  2.', '2026-05-29 08:47', '· wire the new metrics endpoint'],
          [' ', '  3.', '2026-05-28 22:30', '· refactor the trust-store write lock'],
        ];
        for (var i = 0; i < rows.length; i++) {
          if (!api.alive(myRun)) return;
          var row = api.el(i === 0 ? 'line' : 'line dim');
          row.append(api.span(i === 0 ? 'warn-glyph' : '', rows[i][0]));
          row.append(document.createTextNode(' ' + rows[i][1] + ' ' + rows[i][2] + ' '));
          row.append(api.span('ghost', rows[i][3]));
          api.screen.append(row);
          await api.sleep(120);
        }
        if (!api.alive(myRun)) return;
        await api.sleep(2200);
        if (!api.alive(myRun)) return;
        await api.sleep(1200);
      }
    };
  };
})();
