(() => {
  if (!window.__codexBoxWindowFocus) {
    const state = {lastFocus: 0};
    window.__codexBoxWindowFocus = state;
    window.addEventListener('focus', () => { state.lastFocus = Date.now(); });
  }
  const focused = document.hasFocus();
  if (focused) window.__codexBoxWindowFocus.lastFocus = Date.now();
  return {focused, lastFocus: window.__codexBoxWindowFocus.lastFocus};
})()
