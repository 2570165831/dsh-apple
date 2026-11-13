// Installed at document start in the main frame. Wait for a rendered client
// surface; document completion and startup errors alone do not settle a launch.
(function () {
  if (window.top !== window || location.protocol !== 'http:'
      || !['127.0.0.1', 'localhost', '[::1]', '::1'].includes(location.hostname)) return;

  const state = window.__dshBootState = { ready: false, error: null };
  let timer;
  const stop = () => {
    clearInterval(timer);
    window.removeEventListener('error', onError);
    window.removeEventListener('unhandledrejection', onRejection);
  };
  const remember = (reason) => {
    const message = String(reason?.message || reason || 'Client startup error').slice(0, 1200);
    if (/^ResizeObserver loop\b/.test(message)) return;
    if (!state.error) state.error = message;
  };
  const onError = (event) => {
    if (event.error || event.message) remember(event.error || event.message);
  };
  const onRejection = (event) => remember(event.reason);
  const check = () => {
    const root = document.getElementById('root');
    const text = root?.innerText.trim();
    if (document.readyState !== 'complete' || !text || text.startsWith('Loading plugins')) return;
    // Layout markers cover empty sessions; ordinary controls also cover
    // onboarding and dialogs without depending on their language or labels.
    const surfaces = root.querySelectorAll(
      '[data-composer-input], [data-sidebar-collapsed], [data-rightbar-collapsed], '
      + 'button, a[href], input, select, textarea, [contenteditable="true"], [role="button"], [role="dialog"]');
    if (!Array.from(surfaces).some((element) => element.getClientRects().length > 0
        && !['hidden', 'collapse'].includes(getComputedStyle(element).visibility))) return;
    state.ready = true;
    stop();
  };
  window.addEventListener('error', onError);
  window.addEventListener('unhandledrejection', onRejection);
  timer = setInterval(check, 200);
  check();
})();
