// hero cast — landing page. Three scenes: atuin ghost-accept,
// guardrail confirm-prompt, llm `#:` rewrite. Loops until the
// user navigates away or hits replay.
//
// Cast scripts use the api passed by terminal_example.js's engine.
// MUST honour api.alive(myRun) between every await — without that
// guard, replays from the previous run keep typing into the new
// screen and the demo melts.
(function () {
  window.attyTerminalCasts = window.attyTerminalCasts || {};
  window.attyTerminalCasts['hero'] = function (api) {
    return async function play(myRun) {
      while (api.alive(myRun)) {
        api.screen.innerHTML = '';

        var line1 = api.el('line');
        line1.append(api.span('prompt', '$ '));
        var typed1 = api.span('typed', '');
        line1.append(typed1);
        api.setActiveCaret(line1);
        api.screen.append(line1);
        await api.typeInto(myRun, typed1, 'git checkout featu');
        if (!api.alive(myRun)) return;
        await api.sleep(240);
        if (!api.alive(myRun)) return;
        var ghost = api.span('ghost', 're/auth-refactor');
        line1.append(ghost);
        api.setActiveCaret(line1);
        api.screen.append(api.el('line dim', '  → atuin: dim ghost suggests your last matching cmd — Right Arrow/End accepts'));
        await api.sleep(1800);
        if (!api.alive(myRun)) return;
        typed1.textContent = 'git checkout feature/auth-refactor';
        ghost.remove();
        await api.sleep(1000);
        if (!api.alive(myRun)) return;

        var line2 = api.el('line');
        line2.append(api.span('prompt', '$ '));
        var typed2 = api.span('typed', '');
        line2.append(typed2);
        api.setActiveCaret(line2);
        api.screen.append(line2);
        await api.typeInto(myRun, typed2, 'echo pipe-execution-test | sh', 26);
        if (!api.alive(myRun)) return;
        await api.sleep(420);
        if (!api.alive(myRun)) return;
        var warn = api.el('line danger');
        warn.append(api.span('warn-glyph', '!'));
        warn.append(document.createTextNode('atty guardrail: pipe to `sh` detected'));
        api.screen.append(warn);
        api.screen.append(api.el('line dim', '        line: echo pipe-execution-test | sh'));
        api.screen.append(api.el('line dim', '        press Enter again to confirm, any other key to cancel.'));
        await api.sleep(2400);
        if (!api.alive(myRun)) return;

        var line3 = api.el('line');
        line3.append(api.span('prompt', '$ '));
        var typed3 = api.span('typed', '');
        line3.append(typed3);
        api.setActiveCaret(line3);
        api.screen.append(line3);
        await api.typeInto(myRun, typed3, '#: list large files');
        if (!api.alive(myRun)) return;
        await api.sleep(520);
        if (!api.alive(myRun)) return;
        api.screen.append(api.el('line dim', '  ↪ llm module · Alt+A → fills the line · Enter to run'));
        await api.sleep(900);
        if (!api.alive(myRun)) return;
        typed3.textContent = 'du -sh * | sort -h';
        await api.sleep(2000);
        if (!api.alive(myRun)) return;

        await api.sleep(1200);
      }
    };
  };
})();
