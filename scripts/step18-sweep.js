(function () {
  // Step 18's per-screen sweep. One pass, four questions, same answers on every
  // screen so the before/after table compares like with like.
  //
  // The ONE subtlety: "is this control big enough for a thumb" is a question
  // about the TAP REGION, not about the painted box. The polish layer grows the
  // tap region with a ::after overlay and leaves the box alone, so a control that
  // reads 28x28 still has a 44x44 target. This script therefore reports both —
  // `box` and `hit` — and the counts use `hit`, because that is what a finger
  // gets. On a build with the polish off nothing carries `data-dsh-hit`, so
  // `hit` equals `box` and the two columns of the report are the same question.
  const vv = window.visualViewport;
  const vw = window.innerWidth;
  const vh = vv ? Math.round(vv.height) : window.innerHeight;
  const vvTop = vv ? Math.round(vv.offsetTop) : 0;
  const SEL = 'button,a[href],input:not([type=hidden]),select,textarea,summary,'
    + '[role=button],[role=link],[role=tab],[role=menuitem],[role=option],'
    + '[role=checkbox],[role=switch],[role=radio],[tabindex]:not([tabindex="-1"]),'
    + '[data-row-key],[data-dockkit-tab],[data-scroll-down],[data-composer-chip]';

  const label = (el) => {
    const bits = [];
    const ds = Array.from(el.attributes).filter((a) => a.name.indexOf('data-') === 0)
      .filter((a) => a.name !== 'data-dsh-hit')
      .map((a) => a.name.slice(5) + (a.value ? '=' + a.value.slice(0, 18) : ''));
    if (ds.length) bits.push('[' + ds.join(',') + ']');
    const aria = el.getAttribute('aria-label');
    if (aria) bits.push('aria=' + aria.slice(0, 34));
    const t = (el.innerText || el.value || '').replace(/\s+/g, ' ').trim();
    if (t) bits.push('"' + t.slice(0, 34) + '"');
    return el.tagName.toLowerCase()
      + (el.getAttribute('role') ? ':' + el.getAttribute('role') : '')
      + (bits.length ? ' ' + bits.join(' ') : '');
  };

  const shown = (el) => {
    const s = getComputedStyle(el);
    if (s.display === 'none' || s.visibility === 'hidden' || parseFloat(s.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  };

  // The size a finger actually gets.
  // The overlay's own computed width/height is what WebKit will use to hit-test,
  // so read it rather than recomputing the CSS (which includes a max() against
  // 44px and would otherwise be guessed wrong). A `none` content means no
  // overlay, so the box is the target.
  const hitSize = (el, rect) => {
    const after = getComputedStyle(el, '::after');
    const has = el.hasAttribute('data-dsh-hit')
      && after.content !== 'none' && after.content !== 'normal';
    if (!has) {
      return { w: Math.round(rect.width * 10) / 10, h: Math.round(rect.height * 10) / 10, overlay: false };
    }
    const w = parseFloat(after.width);
    const h = parseFloat(after.height);
    return {
      w: Math.round((Number.isFinite(w) ? w : rect.width) * 10) / 10,
      h: Math.round((Number.isFinite(h) ? h : rect.height) * 10) / 10,
      overlay: true,
    };
  };

  const small = [], off = [], cut = [], scrollableOff = [];
  const seen = new Set();
  for (const el of document.querySelectorAll(SEL)) {
    if (seen.has(el) || !shown(el)) continue;
    seen.add(el);
    const r = el.getBoundingClientRect();
    if (r.bottom <= vvTop || r.top >= vvTop + vh || r.right <= 0 || r.left >= vw) continue;
    const box = { w: Math.round(r.width), h: Math.round(r.height) };
    const hit = hitSize(el, r);
    if (hit.w < 44 || hit.h < 44) {
      small.push(label(el) + ' box ' + box.w + 'x' + box.h + ' hit ' + hit.w + 'x' + hit.h);
    }
    if (r.left < -0.5 || r.right > vw + 0.5 || r.top < vvTop - 0.5 || r.bottom > vvTop + vh + 0.5) {
      // An element that hangs past an edge but sits inside a scroller that can
      // bring it back is REACHABLE, and calling it "off screen" would be a false
      // positive that inflates the before/after table. Whether a scroller exists
      // on that axis is read from computed style, not assumed.
      let node = el.parentElement, scrollX = false, scrollY = false, d = 0;
      while (node && d < 20) {
        const s = getComputedStyle(node);
        if (!scrollX && (s.overflowX === 'auto' || s.overflowX === 'scroll')) scrollX = true;
        if (!scrollY && (s.overflowY === 'auto' || s.overflowY === 'scroll')) scrollY = true;
        node = node.parentElement; d += 1;
      }
      const outX = r.left < -0.5 || r.right > vw + 0.5;
      const outY = r.top < vvTop - 0.5 || r.bottom > vvTop + vh + 0.5;
      const unreachable = (outX && !scrollX) || (outY && !scrollY);
      const line = label(el) + ' L' + Math.round(r.left) + ' R' + Math.round(r.right)
        + ' T' + Math.round(r.top) + ' B' + Math.round(r.bottom)
        + ' (R+' + Math.round(r.right - vw) + ' B+' + Math.round(r.bottom - vvTop - vh) + ')'
        + (unreachable ? ' UNREACHABLE' : ' scrollable');
      if (unreachable) off.push(line);
      else scrollableOff.push(line);
    }
  }

  for (const el of document.querySelectorAll('*')) {
    if (el.children.length > 0 || !shown(el)) continue;
    if (el.scrollWidth <= el.clientWidth + 1) continue;
    const t = (el.innerText || '').replace(/\s+/g, ' ').trim();
    if (!t) continue;
    // A visually-hidden label is 1 pt wide ON PURPOSE — it exists for the
    // accessibility tree only (DSH uses a `role=status` span inside each turn to
    // announce progress). Counting it as "clipped text" would put a permanent 1
    // in every screen's table and hide real findings behind it. The test is the
    // classic clip-rect idiom, plus the 1 pt box itself.
    if (el.clientWidth <= 1 || el.clientHeight <= 1) continue;
    // ── and anything whose own box is too small to be read is not "cut text",
    //    it is a collapsed container (measured: the hero's preset chip reports
    //    30/212 pt when the workspace menu has taken its space away, and it is
    //    not on screen in that state at all).
    if (el.clientWidth < 40) continue;
    const rect = el.getBoundingClientRect();
    if (rect.width <= 1 || rect.height <= 1) continue;
    const st = getComputedStyle(el);
    if (st.position === 'absolute' && parseFloat(st.clipPath || '0') === 0
        && /rect\(\s*0(px)?[,\s]+0(px)?[,\s]+0(px)?[,\s]+0(px)?\s*\)/.test(st.clip || '')) continue;
    let p = el.parentElement, scrollable = false, d = 0;
    while (p && d < 8) {
      const s = getComputedStyle(p);
      if (s.overflowX === 'auto' || s.overflowX === 'scroll' || s.overflowX === 'hidden') { scrollable = true; break; }
      p = p.parentElement; d += 1;
    }
    if (scrollable) continue;
    cut.push('"' + t.slice(0, 44) + '" ' + el.clientWidth + '/' + el.scrollWidth + 'pt');
  }

  const hoverOnly = [];
  const collects = (sheet) => {
    let rules; try { rules = sheet.cssRules; } catch (e) { return; }
    if (!rules) return;
    for (const rule of rules) {
      if (rule.cssRules !== undefined && rule.selectorText === undefined) { collects(rule); continue; }
      const sel = rule.selectorText; if (!sel || sel.indexOf(':hover') < 0) continue;
      const s = rule.style; if (!s) continue;
      const decl = [];
      for (const p of ['display', 'opacity', 'visibility', 'pointer-events']) {
        const v = s.getPropertyValue(p); if (v) decl.push(p + ':' + v);
      }
      if (!decl.length) continue;
      const reveals = decl.some((c) => c === 'display:inline-flex' || c === 'display:flex'
        || c === 'display:block' || c === 'opacity:1' || c === 'visibility:visible'
        || c === 'pointer-events:auto');
      if (reveals) hoverOnly.push(sel.slice(0, 90) + ' {' + decl.join(';') + '}');
    }
  };
  for (const s of document.styleSheets) collects(s);

  // Controls that are in the DOM but unreachable without hover — the count the
  // report uses to notice if DSH renames the container the polish layer keys on.
  const hrefOnly = [];
  for (const row of document.querySelectorAll('[data-row-key]')) {
    const actions = row.querySelector('[class*="_rowActions"]');
    if (actions === null) continue;
    const st = getComputedStyle(actions);
    const r = actions.getBoundingClientRect();
    hrefOnly.push({
      row: row.getAttribute('data-row-key').slice(0, 30),
      display: st.display,
      visible: st.display !== 'none' && r.width > 0,
      buttons: actions.querySelectorAll('button').length,
    });
  }

  const statPills = [];
  for (const pill of document.querySelectorAll('[data-composer-dock] button')) {
    const inner = pill.querySelector('span');
    statPills.push({
      aria: (pill.getAttribute('aria-label') || '').slice(0, 50),
      pillW: Math.round(pill.getBoundingClientRect().width),
      innerClientW: inner ? inner.clientWidth : null,
      innerScrollW: inner ? inner.scrollWidth : null,
      clipped: inner ? inner.scrollWidth > inner.clientWidth + 1 : null,
    });
  }

  return JSON.stringify({
    viewport: { vw: vw, vh: vh, vvTop: vvTop },
    counts: {
      smallHit: small.length,
      offScreen: off.length,
      offScreenScrollable: scrollableOff.length,
      clipped: cut.length,
      hoverRevealRules: hoverOnly.length,
      rowActionsHidden: hrefOnly.filter((h) => !h.visible).length,
      statPillsClipped: statPills.filter((p) => p.clipped === true).length,
    },
    small: small,
    offScreen: off,
    offScreenScrollable: scrollableOff,
    clipped: cut,
    rowActions: hrefOnly,
    statPills: statPills,
    hoverRules: hoverOnly,
  }, null, 1);
})()
