// Shared terminal-example playback engine. Auto-attaches to every
// .demo[data-cast] panel on the page; looks up the cast script
// in window.attyTerminalCasts[id] and drives the playback.
//
// Casts register themselves by ID:
//   window.attyTerminalCasts = window.attyTerminalCasts || {};
//   window.attyTerminalCasts['hero'] = function (api) {
//     return async function play(myRun) { /* ... */ };
//   };
//
// The `api` arg is the shared toolkit (sleep, typing, line/span
// builders, single-caret tracking). Cast scripts MUST honour
// api.alive(myRun) between every await to handle restarts.
//
// Honors prefers-reduced-motion (disables replay button + keeps
// the static fallback). Each panel gets its own runner so multi-
// embed pages don't share state.
(function () {
  var panels = document.querySelectorAll('.demo[data-cast]');
  if (!panels.length) return;
  var reducedMotion = window.matchMedia &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  panels.forEach(function (panel) {
    var castId = panel.getAttribute('data-cast');
    var screen = panel.querySelector('.demo-body');
    var replayBtn = panel.querySelector('[data-replay]');
    if (!screen) return;

    if (reducedMotion) {
      if (replayBtn) {
        replayBtn.disabled = true;
        replayBtn.textContent = '○ static (reduced motion)';
      }
      return;
    }

    var registry = window.attyTerminalCasts || {};
    var castFactory = registry[castId];
    if (typeof castFactory !== 'function') {
      // Cast script didn't load (404 / typo / race) — keep the
      // static fallback visible, disable the replay button with
      // a clear hint instead of silently doing nothing.
      if (replayBtn) {
        replayBtn.disabled = true;
        replayBtn.textContent = '⚠ cast "' + castId + '" missing';
      }
      return;
    }

    var currentRun = 0;
    var timers = new Map();

    function sleep(ms) {
      return new Promise(function (resolve) {
        var id = setTimeout(function () {
          timers.delete(id);
          resolve();
        }, ms);
        timers.set(id, resolve);
      });
    }
    function flushTimers() {
      timers.forEach(function (resolve, id) {
        clearTimeout(id);
        resolve();
      });
      timers.clear();
    }
    function el(cls, text) {
      var d = document.createElement('div');
      if (cls) d.className = cls;
      if (text != null) d.textContent = text;
      return d;
    }
    function span(cls, text) {
      var s = document.createElement('span');
      if (cls) s.className = cls;
      if (text != null) s.textContent = text;
      return s;
    }
    function caret() { return span('caret', ''); }
    // Move the blinking caret to `node`, removing any caret
    // that's still attached elsewhere in this panel. Real
    // terminals only render one cursor at a time — without
    // this, every line that previously hosted typing keeps its
    // caret on screen forever (the original demo bug, #350).
    function setActiveCaret(node) {
      var stale = screen.querySelectorAll('.caret');
      for (var i = 0; i < stale.length; i++) stale[i].remove();
      var c = caret();
      node.append(c);
      return c;
    }
    function alive(myRun) { return myRun === currentRun; }

    async function typeInto(myRun, node, text, cps) {
      cps = cps || 22;
      var baseDelay = 1000 / cps;
      for (var i = 0; i < text.length; i++) {
        if (!alive(myRun)) return;
        var ch = text.charAt(i);
        node.textContent += ch;
        var jitter = (Math.random() - 0.5) * baseDelay * 0.55;
        var pause = (ch === ' ') ? baseDelay * 1.35 : baseDelay;
        await sleep(Math.max(22, pause + jitter));
      }
    }

    var api = {
      screen: screen,
      sleep: sleep,
      el: el,
      span: span,
      caret: caret,
      setActiveCaret: setActiveCaret,
      typeInto: typeInto,
      alive: alive,
    };

    var play = castFactory(api);
    if (typeof play !== 'function') {
      if (replayBtn) {
        replayBtn.disabled = true;
        replayBtn.textContent = '⚠ cast "' + castId + '" broken';
      }
      return;
    }

    function restart() {
      currentRun += 1;
      flushTimers();
      play(currentRun);
    }

    if (replayBtn) replayBtn.addEventListener('click', restart);
    restart();
  });
})();
