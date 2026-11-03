//
//  MobileWebTuning.swift
//  DSHPortC
//
//  What a phone needs the web view to do differently, and nothing else.
//
//  WHY THIS EXISTS
//  ---------------
//  DSH's web UI is built for a desktop browser. On an iPhone it works, but five
//  behaviours that are invisible on a desktop with a mouse become the difference
//  between "an app" and "a web page in a box":
//
//    1. Tapping the composer zooms the page. iOS WebKit zooms when the element
//       it focuses renders text under 16 px, and this composer is 14 px. The
//       zoom is one-way: nothing restores it, so the layout stays pushed off
//       screen until the app is relaunched. Measured: `visualViewport.scale`
//       went 1 -> 1.1418 (= 16/14) on focus and stayed there after blur.
//    2. Double-tapping zooms as well, which on a chat surface is a stray gesture
//       that leaves the page magnified.
//    3. Dragging past the end of a list shows white behind the content, because
//       nothing told the document and the scroll view which colour the rubber
//       band should be.
//    4. A long press on text opens the system callout and link previews, which
//       on a message transcript is nearly always an accident.
//    5. Every launch mints a new `dsh-auth-*` cookie and the old ones are never
//       removed, so a long-lived install eventually sends a Cookie header over
//       Node's 16 KB limit and the server answers 431 — a blank page on every
//       launch. Measured at 70 accumulated cookies / 25 659 B.
//    6. Tapping Send raises the keyboard, and it then covers the reply. DSH's
//       toolbar keeps the draft focused on every press, which is harmless with a
//       mouse. Reported from a real iPhone.
//
//  THE THREE LAYERS
//  ----------------
//    * A USER SCRIPT injected at document start: viewport meta, the composer's
//      font size, and the CSS for overscroll colour, tap highlight and callout.
//    * WKWEBVIEW PROPERTIES only native code can set: link previews, the
//      under-page colour, and the scroll view's bounce.
//    * A COOKIE SWEEP before the first load, for (5). It removes only the
//      cookies this app's own loopback server issued, and only ones that name an
//      authority other than the one currently listening.
//
//  None of it touches DSH's own files: the user script runs in the page at
//  runtime, so an upgrade of `payload/` cannot be silently half-patched.
//
//  WHAT IS DELIBERATELY NOT DONE
//  -----------------------------
//    * Two-finger pinch zoom is DISABLED. A chat UI has nothing that benefits
//      from it, and a page that can be zoomed can be left zoomed with no
//      affordance to reset — the exact state this file is fixing. iOS's own
//      Accessibility Zoom is a system feature and is untouched.
//    * Text selection is KEPT on message content: copying a reply is normal. The
//      callout is suppressed; selection is not.
//    * Keeping the composer above the keyboard is not done here. That is
//      `ContentView`'s safe-area job, not a script's.
//

import Foundation
import UIKit
import WebKit

enum MobileWebTuning {

    /// Whether the page-side layer should run at all.
    ///
    /// Read through UserDefaults so an acceptance run can turn it off and measure
    /// the "before" column on the SAME build: `-DSHPortEShellDisable 1`.
    static var isEnabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEShellDisable") != 1
    }

    /// The viewport content this app ships.
    ///
    /// `user-scalable=no` alone is not enough on iOS: WebKit honours
    /// `maximum-scale` even when a page asks not to be scaled, and the old
    /// accessibility argument for keeping pinch-zoom no longer applies (iOS has
    /// its own zoom). `viewport-fit=cover` is harmless: the web view sits inside
    /// the safe area, so every inset the page could read is zero.
    static let viewportContent =
        "width=device-width, initial-scale=1, maximum-scale=1, minimum-scale=1, user-scalable=no, viewport-fit=cover"

    /// The user script injected at document start.
    ///
    /// At documentStart for one reason: the viewport meta has to be in place
    /// before the document's first layout, otherwise WebKit lays the page out
    /// with the shipped meta and the zoom limits arrive too late to stop the
    /// first automatic zoom.
    static func bootstrapScript() -> String {
        """
        (function () {
          if (window.__dshMobileTuning !== undefined) return;
          const state = { installedAt: Date.now(), applied: [] };
          window.__dshMobileTuning = state;

          // The two rail nodes and the style sheet, by id, so a re-install after
          // the body is replaced can find them again.
          const RAIL_EDGE_ID = 'dsh-mobile-rail-edge';
          const SCRIM_ID = 'dsh-mobile-rail-scrim';

          // ---- 1. No automatic zoom -----------------------------------
          //
          // The trigger is the FOCUSED element rendering under 16 px, so raising
          // the composer's font size removes the cause; the viewport meta is the
          // backstop for every other field. 16 px is also legible on a phone, so
          // this costs nothing.
          const VIEWPORT = '\(viewportContent)';
          const pinViewport = () => {
            let meta = document.querySelector('meta[name="viewport"]');
            if (meta === null) {
              meta = document.createElement('meta');
              meta.setAttribute('name', 'viewport');
              (document.head || document.documentElement).appendChild(meta);
            }
            if (meta.getAttribute('content') !== VIEWPORT) {
              meta.setAttribute('content', VIEWPORT);
              state.applied.push('viewport');
            }
          };
          pinViewport();

          // ---- 1b. Do not let the document scroll -------------------------
          //
          // WHAT WENT WRONG WITHOUT THIS, measured on the iPhone simulator with
          // the keyboard up: `innerHeight` 648, `visualViewport.height` 477,
          // `visualViewport.offsetTop` 225.65, `#root` 874 — and `scrollY` 226.
          // `html, body, #root { height: 100% }` in DSH's stylesheet kept
          // resolving to the pre-keyboard height, so the document was 226 px
          // taller than the layout viewport; WebKit then scrolled the document by
          // exactly that much when it focused the composer. The composer went from
          // y 438 to y 212, i.e. ABOVE the visible band 225.7…702.7 — hidden.
          //
          // THE FIX IS ONLY "NO DOCUMENT SCROLL". Nothing needs to move: the
          // composer's un-scrolled y is 438, which is *inside* 225.7…702.7. The
          // bug was entirely the extra 226 px of scrollable slack, so removing the
          // slack is enough, and pinning a height here is what creates the slack
          // in the other direction — a document pinned to `visualViewport.height`
          // (477) is shorter than the band's bottom and is worse. Measured, not
          // reasoned: that version put the composer at y 14.
          //
          // Resetting the document's scroll is the whole fix; the transcript keeps
          // its own scroller and its own bounce.
          const clampDocument = () => {
            if (window.scrollY !== 0) {
              window.scrollTo(0, 0);
              state.applied.push('scroll-reset');
            }
            if (document.documentElement.scrollTop !== 0) document.documentElement.scrollTop = 0;
            if (document.body !== null && document.body.scrollTop !== 0) document.body.scrollTop = 0;
          };
          // Only when the page tries to scroll itself — NOT on every scroll, so a
          // finger scrolling the transcript is untouched. Capture phase, because
          // the document's own scroll does not bubble.
          document.addEventListener('scroll', clampDocument, true);
          // And once after a focus settles, because WebKit's scroll happens as part
          // of the keyboard animation and can land a frame after `focusin`.
          document.addEventListener('focusin', () => {
            clampDocument();
            setTimeout(clampDocument, 60);
            setTimeout(clampDocument, 240);
            setTimeout(clampDocument, 520);
          }, true);

          // The document's head is replaced on some boot paths, so the meta has
          // to be re-asserted rather than set once.
          try {
            const observer = new MutationObserver(() => {
              const meta = document.querySelector('meta[name="viewport"]');
              if (meta === null || meta.getAttribute('content') !== VIEWPORT) pinViewport();
            });
            observer.observe(document.documentElement, {
              childList: true, subtree: true, attributes: true,
              attributeFilter: ['content', 'name'],
            });
            state.viewportObserver = observer;
          } catch (error) { /* the observer is a backstop, not a requirement */ }

          // ---- 2. The style sheet -------------------------------------
          const CSS = [
            // The cause of the automatic zoom, removed rather than hidden.
            '[data-composer-input], [contenteditable="true"], [contenteditable=""], textarea, input, select {',
            '  font-size: 16px !important;',
            '}',
            // DSH derives the composer's line box from its own 14 px size; left
            // alone, a 16 px font inside it clips descenders.
            '[data-composer-input], [contenteditable="true"], [contenteditable=""] {',
            '  line-height: 24px !important;',
            '}',
            // Stops iOS inflating text on a rotated or resized page.
            'html { -webkit-text-size-adjust: 100% !important; }',
            // The double-tap zoom, stopped by the platform instead of by a
            // script. `touch-action: manipulation` tells WebKit that a tap is a
            // tap: no double-tap zoom, no 300 ms delay, and — the part that
            // matters — a second tap 100 ms later still reaches whatever it
            // landed on. Step 11's `touchend` guard could not tell a double tap
            // apart from two quick presses on two different buttons and swallowed
            // the second one; measured on this build, a tap on the sidebar toggle
            // followed 1 ms later by a tap on "new session" left the second
            // control untouched (`secondTap.prevented: true`). The gesture is now
            // disabled where it is defined, and nothing is cancelled after the
            // fact. Text selection inside the composer keeps its own
            // double-tap-to-select, because `manipulation` does not take that
            // away from an editable element.
            'html, body { touch-action: manipulation !important; }',
            // The rubber band. The document must not bounce: the transcript is
            // the scroller and it contains its own overscroll.
            //
            // BACKGROUND: `body` ONLY.
            //
            // The token `--dsw-alias-bg-base` is declared on `body` by DSH's own
            // token stylesheet, so a rule that also names `html` resolves the
            // variable to NOTHING there and falls back to the literal `#fff`.
            // Measured in dark mode: body `rgb(21,21,23)` (correct) while html was
            // still `rgb(255,255,255)` — a white document behind a dark page, which
            // is the white flash at the edge of an overscroll and the white first
            // frame before the page paints. `body` already covers the viewport, and
            // leaving `html` unpainted lets the web view's own background show
            // through, which `MobileWebTuning.configure` and the theme mirror keep
            // in step with the page.
            'body {',
            '  overscroll-behavior: none !important;',
            '  background-color: var(--dsw-alias-bg-base, #fff);',
            '}',
            'html { overscroll-behavior: none !important; }',
            // The transcript keeps its bounce (it is what a finger pulls) but
            // does not CHAIN the scroll to the document, which is what produced
            // the white strip above and below it.
            '[data-conversation-scroll] {',
            '  overscroll-behavior: contain !important;',
            '}',
            // No grey flash on tap. Every interactive element in this UI has a
            // hover/active background of its own; the platform overlay duplicates
            // it and, on a fast scroll, sticks to the wrong row.
            '* { -webkit-tap-highlight-color: transparent !important; }',
            // The long-press callout, on CHROME ONLY.
            //
            // STEP 11 GOT THIS WRONG AND IT COST COPYING. It applied
            // `-webkit-touch-callout: none` to `body, body *`, and the comment
            // beside it claimed selection was untouched. Measured with a real
            // 1.2 s press in XCUITest, twice, in both sequences a person would
            // try (press alone, and double-tap-to-select then press): NO edit menu
            // appeared at all, and the A/B with `-DSHPortEShellDisable 1` showed
            // the same absence — the rule is what removed it. Suppressing the
            // callout suppresses the menu that carries copy, so a reply could no
            // longer be copied.
            //
            // The accidental-callout problem this rule existed for is on the
            // chrome, not on the transcript: pressing a button or a session row
            // and getting a "copy" bubble over it is the annoyance. So the
            // suppression is scoped to non-content elements, and message text
            // keeps the platform behaviour it should have had.
            'button, [role="button"], [data-row-key], [data-dockkit-tab],',
            'nav, header, [data-composer-dock], [data-composer-card], [data-shell-bottom] {',
            '  -webkit-touch-callout: none !important;',
            '  -webkit-user-select: none !important; user-select: none !important;',
            '}',
            // Link previews are a native setting (`allowsLinkPreview = false`)
            // and are still off; that is separate from the callout menu and does
            // not take copying with it.
            // A long code line scrolls inside its own box instead of widening
            // the page.
            //
            // MEASURED FIRST, and this is why the rule looks like this. A code
            // block whose single line is 232 characters renders with
            // `whiteSpace: "pre-wrap"` and `scrollWidth === clientWidth` (336 ===
            // 336): it does not widen the page — good — but it does not scroll
            // either, it WRAPS, which on a 402 pt phone turns one command into
            // nine lines. `overflow-x: auto` alone therefore changed nothing,
            // because nothing overflowed. `white-space: pre` restores the line,
            // and only then does the block's own scroller have something to
            // scroll. `overscroll-behavior-x: contain` keeps a sideways swipe at
            // the end of a line from chaining out to the transcript.
            //
            // The page keeps its own wrap toggle (`[data-code-wrap]`, the banner's
            // button, which flips `white-space` back); this sets the DEFAULT for a
            // code block on a phone, which is what the task asks for.
            'pre, pre *, [data-code-block-banner], [data-code-wrap] { max-width: 100% !important; }',
            'pre {',
            '  overflow-x: auto !important;',
            '  overscroll-behavior-x: contain !important;',
            '  white-space: pre !important;',
            '}',
            'pre [data-code-wrap], pre[data-code-wrap] { white-space: pre-wrap !important; }',
            // ---- The 56 pt rail, on a phone in portrait only ------------------
            //
            // WHY: the iPhone 15 Pro Max is 402 pt wide in portrait, and DSH's
            // narrow layout spends 56 of them (14 %) on the collapsed sidebar's
            // icon rail. Measured on this build before the change:
            // `gridTemplateColumns: "56px 346px 0px"`.
            //
            // HOW: the rail column becomes an overlay instead of a track. Closed,
            // it takes zero width and the centre gets all 402 pt; open, it is
            // drawn ON TOP of the transcript as a 280 pt drawer with a scrim,
            // which is what a phone chat app does. A 20 pt strip at the left edge
            // opens it, and so does a swipe from that edge.
            //
            // THE TWO MEDIA CONDITIONS ARE THE CONTRACT: `max-width: 520px` and
            // `orientation: portrait`. An iPad (820 pt) and any phone in landscape
            // keep DSH's own layout untouched — same 56 pt rail, same grid — so
            // nothing here can change what step 10 measured.
            //
            // The rule keys on `[data-dsh-rail]` on the root, which the script
            // sets; with the script disabled (`-DSHPortEShellDisable 1`) the
            // attribute is absent and every one of these rules is inert.
            '@media (max-width: 520px) and (orientation: portrait) {',
            '  html[data-dsh-rail] [class*="_frame"] {',
            '    grid-template-columns: minmax(0, 1fr) 0px 0px !important;',
            '  }',
            '  html[data-dsh-rail] [class*="_frame"] > [class*="_centerCol"] { grid-column: 1 !important; grid-row: 1 !important; }',
            '  html[data-dsh-rail] [class*="_frame"] > [class*="_rightbarCol"] { grid-column: 1 !important; grid-row: 1 !important; }',
            // Collapsed, the right bar goes back to its own 0 pt track. The rule above
            // would leave an empty, transparent column over the whole transcript:
            // measured with `elementsFromPoint`, every touch below the tabs landed on
            // it, so nothing there scrolled or expanded.
            '  html[data-dsh-rail] [class*="_frame"][data-rightbar-collapsed] > [class*="_rightbarCol"] { grid-column: 3 !important; }',
            '  html[data-dsh-rail] [class*="_frame"]:not([data-rightbar-collapsed]) > [class*="_rightbarCol"] { animation: dsh-rightbar-in .26s cubic-bezier(.32, .72, 0, 1); }',
            '  html[data-dsh-rail] [class*="_frame"] > [class*="_sidebarCol"] {',
            '    grid-column: 1 !important;',
            // `grid-row: 1` is not decoration. The frame's child order is
            // sidebar | centre | rightbar | bottomRow | overlay, and grid
            // auto-placement puts a second item that names the same column into
            // the NEXT row — measured with the drawer open: `centerCol` height
            // collapsed from 778 to 278 and the transcript from 738 to 238,
            // because the centre had been pushed onto the bottom row's track.
            // Pinning both to row 1 is what makes the drawer an overlay rather
            // than a reflow. It also holds while the drawer slides out, which is
            // why the position is not limited to the open state.
            '    grid-row: 1 !important;',
            '    justify-self: start !important;',
            '    width: 280px !important;',
            '    z-index: 60 !important;',
            '    box-shadow: 8px 0 24px rgba(0, 0, 0, .18) !important;',
            '    transform: translateX(0);',
            '    transition: transform .26s cubic-bezier(.32, .72, 0, 1), display .26s allow-discrete;',
            '  }',
            '  @starting-style {',
            '    html[data-dsh-rail] [class*="_frame"]:not([data-sidebar-collapsed]) > [class*="_sidebarCol"] { transform: translateX(-100%); }',
            '  }',
            '  html[data-dsh-rail] [class*="_frame"][data-sidebar-collapsed] > [class*="_sidebarCol"] {',
            '    display: none !important;',
            '    transform: translateX(-100%);',
            '    pointer-events: none !important;',
            '  }',
            // Under a finger the position is the finger's, so nothing eases toward it.
            // The transform here is only for the frame the drawer first exists; the
            // drag's own position is inline on the element and wins over it.
            '  html[data-dsh-rail-dragging] [class*="_frame"] > [class*="_sidebarCol"] { transform: translateX(-280px); transition: none !important; will-change: transform; }',
            '  html[data-dsh-rail-dragging] [data-dsh-rail-scrim] { animation: none !important; transition: none !important; will-change: opacity; }',
            '  @media (prefers-reduced-motion: reduce) {',
            '    html[data-dsh-rail] [class*="_frame"] > [class*="_sidebarCol"] { transition: none; }',
            '    html[data-dsh-rail] [data-dsh-rail-scrim] { animation: none !important; transition: none !important; }',
            '    html[data-dsh-rail] [class*="_frame"] > [class*="_rightbarCol"] { animation: none !important; }',
            '  }',
            '  html[data-dsh-rail] [data-dsh-rail-edge] {',
            '    display: grid !important;',
            '  }',
            '  html[data-dsh-rail][data-dsh-rail-open] [data-dsh-rail-edge] { display: none !important; }',
            '  html[data-dsh-rail] [data-dsh-rail-scrim] { display: block !important; }',
            '}',
            // Outside the narrow portrait case the two injected controls must not
            // exist at all. Without these lines a plain `<button>` and `<div>`
            // would render with their default styles on an iPad — the injected
            // nodes are created unconditionally, only their presentation is
            // conditional.
            '[data-dsh-rail-edge], [data-dsh-rail-scrim] { display: none !important; }',
            '[data-dsh-rail-edge] {',
            '  position: fixed; left: 0; top: 22%; bottom: 22%; width: 20px; z-index: 55;',
            '  place-items: center; padding: 0; border: none; margin: 0;',
            '  background: transparent; color: var(--dsw-alias-label-tertiary, #8a8a8e);',
            '}',
            '[data-dsh-rail-edge]::before {',
            '  content: ""; width: 4px; height: 44px; border-radius: 2px;',
            '  background: currentColor; opacity: .5;',
            '}',
            '[data-dsh-rail-scrim] {',
            '  position: fixed; inset: 0; z-index: 59; border: none; padding: 0;',
            '  background: rgba(0, 0, 0, .3);',
            '  animation: dsh-rail-scrim-in .26s ease-out;',
            '  transition: opacity .26s ease-out;',
            '}',
            '[data-dsh-rail-scrim][data-closing] { opacity: 0; pointer-events: none; }',
            '@keyframes dsh-rail-scrim-in { from { opacity: 0; } }',
            '@keyframes dsh-rightbar-in { from { transform: translateX(100%); } }',
          ].join('\\n');
          const installStyle = () => {
            if (document.getElementById('dsh-mobile-tuning') !== null) return;
            const style = document.createElement('style');
            style.id = 'dsh-mobile-tuning';
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
            state.applied.push('style');
          };
          installStyle();
          try {
            const styleWatcher = new MutationObserver(() => {
              if (document.getElementById('dsh-mobile-tuning') === null) installStyle();
            });
            styleWatcher.observe(document.documentElement, { childList: true, subtree: true });
            state.styleObserver = styleWatcher;
          } catch (error) { /* ditto */ }

          // ---- 3. Gesture guards --------------------------------------
          //
          // The double tap is stopped by `touch-action: manipulation` in the
          // style sheet above, not here. Step 11 did it here, with a `touchend`
          // guard that cancelled any second touch inside 320 ms; measured on this
          // build, a tap on the sidebar toggle followed by a tap on "new session"
          // had the SECOND tap cancelled (`secondTap.prevented: true`) and the
          // session was never created. A guard that cannot tell a double tap from
          // two quick presses is worse than the zoom it prevents: zoom is
          // recoverable by relaunching, a swallowed tap just looks broken.
          //
          // What REMAINS is the pinch guard. `user-scalable=no` covers most of
          // it, but a two-finger gesture fires `gesturestart` on iOS regardless,
          // and cancelling that is what stops the zoom on a page whose meta did
          // not take.
          state.gestureGuard = 0;
          for (const type of ['gesturestart', 'gesturechange']) {
            document.addEventListener(type, (event) => {
              state.gestureGuard += 1;
              event.preventDefault();
            }, { capture: true, passive: false });
          }

          // ---- 3c. The rail becomes a drawer on a phone ------------------
          //
          // The CSS above does the layout; this creates the two nodes it styles
          // and the one gesture it needs. Only in the narrow portrait case does
          // any of it become visible — the style sheet hides both nodes
          // everywhere else, so an iPad keeps exactly what step 10 measured.
          //
          // The drawer is driven by DSH's own toggle button (`[class*="_toggle"]`
          // with the "打开侧边栏" / "收起侧边栏" label) rather than by setting a
          // class: the layout store is the thing that decides whether the sidebar
          // is expanded, and pressing the real control is the only way to move it
          // without reaching into the client's module system.
          const railNarrow = () => window.matchMedia('(max-width: 520px) and (orientation: portrait)').matches;
          const railToggle = () => {
            const wanted = ['打开侧边栏', '收起侧边栏', 'Open sidebar', 'Collapse sidebar'];
            for (const button of document.querySelectorAll('button, [role="button"]')) {
              const label = (button.getAttribute('aria-label') || '').trim();
              if (wanted.some((w) => label.indexOf(w) >= 0)) { button.click(); return true; }
            }
            return false;
          };
          const railExpanded = () => {
            const frame = document.querySelector('[class*="_frame"]');
            return frame !== null && !frame.hasAttribute('data-sidebar-collapsed');
          };
          let scrimRemoval;
          const setDrawer = (open) => {
            if (open) {
              document.documentElement.setAttribute('data-dsh-rail-open', '');
              clearTimeout(scrimRemoval);
              const fading = document.getElementById(SCRIM_ID);
              if (fading !== null) fading.removeAttribute('data-closing');
              if (fading === null) {
                const scrim = document.createElement('div');
                scrim.id = SCRIM_ID;
                scrim.setAttribute('data-dsh-rail-scrim', '');
                scrim.addEventListener('click', (event) => {
                  event.preventDefault();
                  event.stopPropagation();
                  if (railExpanded()) railToggle();
                  setDrawer(false);
                });
                (document.body || document.documentElement).appendChild(scrim);
              }
            } else {
              document.documentElement.removeAttribute('data-dsh-rail-open');
              const scrim = document.getElementById(SCRIM_ID);
              if (scrim !== null) {
                scrim.setAttribute('data-closing', '');
                clearTimeout(scrimRemoval);
                scrimRemoval = setTimeout(() => scrim.remove(), 280);
              }
            }
          };
          state.railTaps = 0;
          const installRailEdge = () => {
            if (document.getElementById(RAIL_EDGE_ID) !== null) return;
            const edge = document.createElement('button');
            edge.id = RAIL_EDGE_ID;
            edge.type = 'button';
            edge.setAttribute('data-dsh-rail-edge', '');
            edge.setAttribute('aria-label', '打开会话列表');
            edge.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              // Inert outside the narrow portrait case even if something presses
              // it programmatically: an iPad or a landscape phone must keep DSH's
              // own sidebar behaviour, and a stray click there would open a drawer
              // the CSS is not styling.
              if (!railNarrow()) return;
              state.railTaps += 1;
              if (railExpanded()) { railToggle(); setDrawer(false); return; }
              railToggle();
              setDrawer(true);
            });
            (document.body || document.documentElement).appendChild(edge);
          };
          installRailEdge();
          document.documentElement.setAttribute('data-dsh-rail', '');

          // A press on a session row opens that conversation AND closes the
          // drawer. DSH does not collapse its own sidebar on this press — on a
          // wide screen the list is meant to stay — so without this the chosen
          // conversation would open underneath an overlay still covering it.
          //
          // STEP 21: A PRESS ON A CONTROL INSIDE THE ROW IS NOT A PRESS ON THE ROW.
          //
          // `closest()` walks up from the pressed element, and every control inside
          // a row is a descendant of it — so `归档会话`, `置顶会话` and
          // `会话“…”的操作` were all handled as "the row was pressed": pressing one
          // collapsed the sidebar. Measured on the iPhone simulator, with an
          // observer on both click phases:
          //
          //     capture  BUTTON 会话“…”的操作     drawer: true
          //     capture  BUTTON 收起侧边栏         drawer: true   <- this handler's
          //     bubble                             drawer: true      own railToggle()
          //
          // Archive and pin still landed, because they act synchronously on their
          // own click and this handler's work is deferred; step 18 saw that and read
          // the drawer closing afterwards as the expected result. Rename and delete
          // open a MENU, and the menu is dismissed by that same deferred toggle, so
          // they were unreachable on a phone — the gap REPORT-18 recorded as "置顶、
          // 重命名、删除仅显露控件，未完整操作验收", with its cause identified in
          // step 21.
          //
          // The rule is now the obvious one: a press that lands on a button (or on a
          // hit overlay this task's polish layer added) inside the row belongs to
          // that button, not to the row. Step 21's own `MobileWebPolish` cannot fix
          // this from its side — it tried four ways and documented each in
          // REPORT-21.md — because this handler is registered in the CAPTURE phase
          // on `document` and runs before anything another file can add there.
          document.addEventListener('click', (event) => {
            const target = event.target;
            if (!(target instanceof Element)) return;
            const row = target.closest('[data-row-key]');
            if (row === null) return;
            if ((row.getAttribute('data-row-key') || '').indexOf('session:') !== 0) return;
            // The row's own glyphs and menu trigger are buttons. A press on one of
            // them is that control's business: it must not collapse the sidebar, or
            // the menu it just opened goes with it.
            if (target.closest('button, [role="button"], [data-dsh-hit]') !== null) return;
            setTimeout(() => {
              if (railExpanded()) railToggle();
              setDrawer(false);
            }, 0);
          }, true);

          // The drawer follows the finger: in from the left edge, and back out from
          // anywhere once it is open. Page-side only: this catches the gesture when
          // the web view receives it, and an iOS SYSTEM edge gesture is not something
          // a page can see at all (the app sets `allowsBackForwardNavigationGestures =
          // false`, so WebKit's own back-swipe does not claim the edge).
          //
          // DSH's store flips the sidebar a moment after the toggle press, so the
          // style sheet holds the drawer off screen for as long as a drag is on, and
          // a frame loop picks the element up when it appears.
          //
          // The position is written to the drawer itself, never to the root. A custom
          // property on the root is inherited by every element, so each move restyled
          // the whole page: measured on the simulator, 8.2 ms a write against 0.1 ms,
          // with 399 elements and on a Mac. It stuttered on the phone.
          const RAIL_WIDTH = 280;
          const RAIL_FLICK = 0.4; // pt per ms
          let railDrag = null;
          let railRelease;
          const findRail = (drag) => {
            if (drag.rail === null || !drag.rail.isConnected) {
              drag.rail = document.querySelector('[class*="_frame"] > [class*="_sidebarCol"]');
            }
            return drag.rail;
          };
          const placeRail = (drag) => {
            const rail = findRail(drag);
            if (rail === null || (rail === drag.placedRail && drag.x === drag.placedX)) return;
            drag.placedRail = rail;
            drag.placedX = drag.x;
            rail.style.transform = 'translateX(' + drag.x + 'px)';
            const scrim = document.getElementById(SCRIM_ID);
            if (scrim !== null) scrim.style.opacity = String(1 + drag.x / RAIL_WIDTH);
          };
          const followRail = () => {
            const drag = railDrag;
            if (drag === null || !drag.active) return;
            placeRail(drag);
            requestAnimationFrame(followRail);
          };
          const settleRail = (drag) => {
            const root = document.documentElement;
            const rail = findRail(drag);
            const open = Math.abs(drag.velocity) > RAIL_FLICK ? drag.velocity > 0 : drag.x > -RAIL_WIDTH / 2;
            root.removeAttribute('data-dsh-rail-dragging');
            const scrim = document.getElementById(SCRIM_ID);
            if (scrim !== null) scrim.style.removeProperty('opacity');
            if (open) {
              if (rail !== null) rail.style.removeProperty('transform');
              return;
            }
            if (rail !== null) rail.style.transform = 'translateX(' + -RAIL_WIDTH + 'px)';
            if (railExpanded()) railToggle();
            setDrawer(false);
            railRelease = setTimeout(() => {
              if (rail !== null) rail.style.removeProperty('transform');
            }, 300);
          };
          document.addEventListener('touchstart', (event) => {
            railDrag = null;
            if (!railNarrow() || event.touches.length !== 1) return;
            if (document.querySelector('[role="dialog"]') !== null) return;
            const touch = event.touches[0];
            const isOpen = railExpanded() && document.documentElement.hasAttribute('data-dsh-rail-open');
            if (!isOpen && touch.clientX > 24) return;
            railDrag = {
              startX: touch.clientX, startY: touch.clientY,
              lastX: touch.clientX, lastAt: event.timeStamp,
              base: isOpen ? 0 : -RAIL_WIDTH, opening: !isOpen,
              x: isOpen ? 0 : -RAIL_WIDTH, velocity: 0, active: false,
              rail: null, placedRail: null, placedX: null,
            };
          }, { capture: true, passive: true });
          document.addEventListener('touchmove', (event) => {
            const drag = railDrag;
            if (drag === null) return;
            const touch = event.touches[0];
            if (touch === undefined) return;
            const dx = touch.clientX - drag.startX;
            const dy = touch.clientY - drag.startY;
            if (!drag.active) {
              if (Math.abs(dx) < 8 && Math.abs(dy) < 8) return;
              // A vertical start belongs to the list under the finger.
              if (Math.abs(dy) > Math.abs(dx) || (drag.opening ? dx < 0 : dx > 0)) { railDrag = null; return; }
              drag.active = true;
              clearTimeout(railRelease);
              document.documentElement.setAttribute('data-dsh-rail-dragging', '');
              placeRail(drag);
              requestAnimationFrame(followRail);
              if (drag.opening) {
                state.applied.push('rail-swipe');
                setDrawer(true);
                if (!railExpanded()) railToggle();
              }
            }
            event.preventDefault();
            const elapsed = event.timeStamp - drag.lastAt;
            if (elapsed > 0) drag.velocity = (touch.clientX - drag.lastX) / elapsed;
            drag.lastX = touch.clientX;
            drag.lastAt = event.timeStamp;
            drag.x = Math.min(0, Math.max(-RAIL_WIDTH, drag.base + dx));
            placeRail(drag);
          }, { capture: true, passive: false });
          const endRailDrag = (event) => {
            const drag = railDrag;
            railDrag = null;
            if (drag === null || !drag.active) return;
            // A finger held still before lifting is a placement, not a flick.
            if (event.timeStamp - drag.lastAt > 100) drag.velocity = 0;
            settleRail(drag);
          };
          document.addEventListener('touchend', endRailDrag, { capture: true, passive: true });
          document.addEventListener('touchcancel', endRailDrag, { capture: true, passive: true });

          // The body can be replaced during boot, taking the strip with it.
          if (state.railObserver === undefined) {
            try {
              state.railObserver = new MutationObserver(() => installRailEdge());
              state.railObserver.observe(document.documentElement, { childList: true, subtree: true });
            } catch (error) { /* the observer is a backstop */ }
          }

          // ---- 3b. The keyboard comes up when the draft is what was pressed
          //
          // DSH's composer keeps the draft focused on every toolbar press:
          // `keepDraftFocus` runs on `mousedown`, and the "+" button focuses the
          // editor before opening its menu. With a mouse that only keeps a caret.
          // On a phone the focus lands inside a user gesture, so iOS raises the
          // keyboard for a tap on Send and it covers the reply.
          //
          // So a press that did not land on the draft cannot move focus INTO it.
          // Focus that is already there stays: that is what the toolbar press is
          // for, and picking from the draft's own menu must not lose the keyboard.
          // A hardware keyboard raises nothing on screen, so all of this stands
          // aside for one.
          state.hardwareKeyboard = false;
          state.draftFocusBlocked = 0;
          let pressMayFocusDraft = false;
          let heightBeforeFocus = window.innerHeight;
          const isDraft = (el) => el instanceof Element && el.matches('[data-composer-input]');
          const draftHasFocus = () => isDraft(document.activeElement);
          const draftMayTakeFocus = () => state.hardwareKeyboard || pressMayFocusDraft;
          const pressIsOnDraft = (target) => {
            if (!(target instanceof Element)) return false;
            if (target.closest('[data-composer-input], [data-composer-overlay]') !== null) return true;
            return target.closest('[data-composer-card]') !== null
              && target.closest('button, a, input, select, textarea, [role="button"]') === null;
          };
          document.addEventListener('touchstart', (event) => {
            if (!draftHasFocus()) heightBeforeFocus = window.innerHeight;
            pressMayFocusDraft = draftHasFocus() || pressIsOnDraft(event.target);
          }, { capture: true, passive: true });
          // The two ways focus gets there. `focus()` is the one DSH calls, and
          // stopping it here means the keyboard never starts to animate. A Lexical
          // selection update can focus the editor without calling it, so `focusin`
          // catches whatever is left.
          const realFocus = HTMLElement.prototype.focus;
          HTMLElement.prototype.focus = function (options) {
            if (isDraft(this) && !draftHasFocus() && !draftMayTakeFocus()) {
              state.draftFocusBlocked += 1;
              return;
            }
            return realFocus.call(this, options);
          };
          document.addEventListener('focusin', (event) => {
            if (!isDraft(event.target)) return;
            if (!draftMayTakeFocus()) {
              state.draftFocusBlocked += 1;
              event.target.blur();
              return;
            }
            // An on-screen keyboard shrinks the web view; a hardware one does not.
            const before = heightBeforeFocus;
            setTimeout(() => {
              if (draftHasFocus()) state.hardwareKeyboard = window.innerHeight >= before - 1;
            }, 900);
          }, true);
          // The measurement above can land before a slow keyboard has finished.
          window.addEventListener('resize', () => {
            if (draftHasFocus() && window.innerHeight < heightBeforeFocus - 1) state.hardwareKeyboard = false;
          });
          // Send ends with the keyboard down, so the reply has the screen. Only the
          // tap: Return while typing keeps the keyboard, and with an empty draft the
          // same button is Stop. Capture phase, so the draft is read before DSH's
          // handler clears it, and the blur waits until that handler has run.
          document.addEventListener('click', (event) => {
            if (state.hardwareKeyboard || !(event.target instanceof Element)) return;
            if (event.target.closest('[data-composer-card] button[class*="primary"]') === null) return;
            const draft = document.querySelector('[data-composer-input]');
            if (draft === null || draft.textContent.trim() === '') return;
            pressMayFocusDraft = false;
            setTimeout(() => { if (draftHasFocus()) document.activeElement.blur(); }, 0);
          }, true);

          // ---- 4. The visual viewport, recorded -----------------------
          //
          // Not a fix: the witness. Whether the page ever returns to scale 1 is
          // the question, and only the page can answer it. Bounded so a long
          // session cannot grow it without limit.
          state.viewportLog = [];
          const recordViewport = (why) => {
            const vv = window.visualViewport;
            if (vv === undefined || vv === null) return;
            if (state.viewportLog.length >= 200) return;
            state.viewportLog.push({
              why: why, scale: vv.scale,
              w: Math.round(vv.width), h: Math.round(vv.height), t: Date.now(),
            });
          };
          if (window.visualViewport !== undefined && window.visualViewport !== null) {
            window.visualViewport.addEventListener('resize', () => recordViewport('resize'));
            window.visualViewport.addEventListener('scroll', () => recordViewport('scroll'));
          }
          document.addEventListener('focusin', () => recordViewport('focusin'), true);
          document.addEventListener('focusout', () => recordViewport('focusout'), true);
        })();
        """
    }

    /// Configure the web view for a phone. Called once, at creation.
    ///
    /// None of these has a page-side equivalent, which is why they live here
    /// rather than in the script above.
    static func configure(_ webView: WKWebView) {
        guard isEnabled else { return }
        // A long press on a link in a transcript should not raise a preview
        // bubble over the message. The link still opens on tap.
        webView.allowsLinkPreview = false
        // What shows through the rubber band. Without this it is the system's
        // white, which is the light-mode gap in a dark-mode page. DSH paints
        // `--dsw-alias-bg-base`, which is #fff / #151517 (checked in
        // dsh-client-ui-theme's token table), so the native colour is the same
        // pair and the two cannot disagree.
        webView.underPageBackgroundColor = Palette.pageBackground
        webView.backgroundColor = Palette.pageBackground
        webView.isOpaque = false
        // The transcript does its own scrolling; a bouncing document behind it is
        // the other half of the white strip.
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        // The web view already sits inside the safe area, so nothing should inset
        // its content a second time.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
    }

    /// Drop auth cookies this app's own server issued on a previous launch.
    ///
    /// WHY THIS IS NECESSARY, in numbers measured on this task's simulator:
    /// DSH's cookie name is `dsh-auth-<sha256("127.0.0.1:<port>")>`
    /// (`dsh-client-connection/lib/index.js:335`) and the port is chosen at
    /// random on every launch, so every launch mints a *new* cookie and nothing
    /// ever removes the old one. An install launched 70 times carried 70
    /// cookies — 15 958 bytes of `Cookie` header, against Node's 16 KB
    /// request-header limit — after which the server answers
    /// `431 Request Header Fields Too Large`, the web view shows a blank
    /// document, and the app looks broken with no message anywhere.
    ///
    /// Deleting them all is safe and idempotent because the cookie is not how
    /// this app authenticates *durably*: the launch URL carries a one-shot token
    /// and the server answers it with `303 + Set-Cookie`, so the cookie the
    /// current launch needs is issued by the first navigation. Measured: after
    /// a full sweep the first navigation returns 200 and the shell renders.
    ///
    /// Scope: names starting `dsh-auth-` on loopback only, so nothing else the
    /// user is signed into can be affected.
    ///
    /// @param store - the data store the web view uses.
    /// @param completion - called on the main queue with the number removed.
    static func sweepStaleAuthCookies(
        store: WKWebsiteDataStore,
        completion: @escaping (Int) -> Void
    ) {
        guard isEnabled else { completion(0); return }
        store.httpCookieStore.getAllCookies { cookies in
            let stale = cookies.filter { cookie in
                guard cookie.name.hasPrefix("dsh-auth-") else { return false }
                return cookie.domain.contains("127.0.0.1") || cookie.domain == "localhost"
            }
            guard !stale.isEmpty else { completion(0); return }
            let group = DispatchGroup()
            for cookie in stale {
                group.enter()
                store.httpCookieStore.delete(cookie) { group.leave() }
            }
            group.notify(queue: .main) { completion(stale.count) }
        }
    }

    /// Remove the `^ v ✓` accessory strip WebKit puts above the keyboard.
    ///
    /// WHAT IT IS, measured rather than assumed. With the composer focused, the
    /// web view's first responder is a `WKContentView` and its
    /// `inputAccessoryView` is a `WKFormAccessoryView` **68 pt tall** with two
    /// subviews — the `< > ✓` bar in the task's screenshot. It is WebKit's own
    /// form assistant: previous/next field, and Done. On this app it is useless.
    /// The transcript has one editable field, so previous/next has nowhere to go,
    /// and Done duplicates the tap on the conversation that dismisses the
    /// keyboard anyway.
    ///
    /// WHAT DOES *NOT* WORK, so nobody tries it twice: clearing
    /// `inputAssistantItem.leadingBarButtonGroups` / `trailingBarButtonGroups`
    /// does nothing here. That surface controls the iPad shortcut bar, not
    /// `WKFormAccessoryView`. Measured on this build: with both groups empty the
    /// accessory was still present at 68 pt.
    ///
    /// WHAT WORKS: the accessory belongs to the `WKContentView`, which is created
    /// by WebKit, so the only seam is to subclass the content view and override
    /// `inputAccessoryView` to `nil`. `WKWebViewConfiguration` has no hook for
    /// that, so the content view is swapped for a subclass of the same class the
    /// running WebKit installed — `object_setClass` on the live view, which keeps
    /// its state and only changes which `inputAccessoryView` is answered.
    ///
    /// This touches WebKit's own view class (not a private API: subclassing a
    /// responder and overriding a documented property), so it is confined to the
    /// web view this app owns and is registered in PATCHES.md.
    static func removeInputAccessoryFromContentViews(_ webView: WKWebView) {
        guard isEnabled else { return }
        installAccessorySuppressor(on: webView)
        // The content view can be created after the first load, or replaced when
        // the process is relaunched after a crash, so this also runs on every
        // focus. Idempotent: an already-swapped view is left alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            installAccessorySuppressor(on: webView)
        }
    }

    private static var suppressedClasses: [String: AnyClass] = [:]

    /// Swap every `WKContentView` in the web view for a subclass with no
    /// accessory view.
    private static func installAccessorySuppressor(on webView: WKWebView) {
        for contentView in allContentViews(in: webView) {
            let current = type(of: contentView)
            let currentName = NSStringFromClass(current)
            // Already ours: nothing to do.
            if currentName.hasSuffix("_NoAccessoryContentView") { continue }
            let subclassName = currentName + "_NoAccessoryContentView"
            let subclass: AnyClass
            if let existing = suppressedClasses[subclassName] {
                subclass = existing
            } else if let created = objc_allocateClassPair(current, subclassName, 0) {
                // -inputAccessoryView returning nil is the whole point.
                let selector = #selector(getter: UIResponder.inputAccessoryView)
                let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
                class_addMethod(created, selector, imp_implementationWithBlock(block), "@@:")
                objc_registerClassPair(created)
                suppressedClasses[subclassName] = created
                subclass = created
            } else {
                continue
            }
            object_setClass(contentView, subclass)
        }
    }

    /// Every `WKContentView` inside a web view, however deep.
    private static func allContentViews(in view: UIView) -> [UIView] {
        var found: [UIView] = []
        func walk(_ view: UIView, depth: Int) {
            if depth > 24 { return }
            if NSStringFromClass(type(of: view)).contains("WKContentView") { found.append(view) }
            for sub in view.subviews { walk(sub, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return found
    }

    /// The document background pair DSH paints, so the native layer agrees.
    ///
    /// TWO SOURCES, ONE COLOUR. `Palette` used to be a pure iOS-appearance pair,
    /// which is right only while the page and the system agree. DSH has its own
    /// theme preference (`light` / `dark` / `system`) and publishes the resolved
    /// answer as `data-ds-theme-source` on the root element; with the preference
    /// fixed to `light` on a phone in dark mode, the iOS pair paints a dark band
    /// around a light page. So the page's own answer wins whenever the page has
    /// published one, and the iOS appearance is only the fallback for the moments
    /// before the page loads (launch screen, boot screen).
    enum Palette {
        /// What UIKit should paint around the page right now.
        ///
        /// - Parameter pageScheme: `"dark"`, `"light"`, `"system"` or `nil`, as
        ///   read from the page. `nil`/`system` falls back to the trait, because
        ///   `system` means "whatever the appearance says" and the trait already
        ///   carries that answer.
        static func pageBackground(forPageScheme pageScheme: String?) -> UIColor {
            switch pageScheme {
            case "dark": return dark
            case "light": return light
            default:
                return UIColor { traits in
                    traits.userInterfaceStyle == .dark ? dark : light
                }
            }
        }

        /// The appearance-following pair, for launches before the page exists.
        static var pageBackground: UIColor {
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        }

        /// DSH's own `--dsw-alias-bg-base` values, both schemes.
        static let light = UIColor.white
        static let dark = UIColor(red: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x17 / 255.0, alpha: 1)

        /// The same pair as a colour asset, for the launch screen.
        static let assetName = "PageBackground"
    }

    /// Watch the page's theme and report every change.
    ///
    /// A POLL, not an observer of DSH's theme service: that service is a cordis
    /// plugin inside the page, and reaching it would mean going through the
    /// client's module system, which exposes no getter. What the page publishes
    /// for its own shells is `data-ds-theme-source` on the root element, and
    /// `MutationObserver` on that attribute is both cheap and exact.
    ///
    /// The poll exists as well as the observer because the page can be replaced
    /// during boot (the body is rebuilt), which takes the observer's target with
    /// it. One second is fast enough that a theme flip does not leave a visibly
    /// wrong band for long, and slow enough to be free.
    ///
    /// - Parameters:
    ///   - webView: the web view to watch.
    ///   - onChange: called on the main queue with `"light"`, `"dark"`, `"system"`
    ///     or `nil` (the page has not answered yet).
    /// - Returns: a closure that stops the watching.
    static func watchPageTheme(_ webView: WKWebView, onChange: @escaping (String?) -> Void) -> () -> Void {
        let script = """
        (function () {
          const read = () => {
            const root = document.documentElement;
            const source = root.getAttribute('data-ds-theme-source');
            if (source !== null) return source;
            if (document.body !== null && document.body.hasAttribute('data-ds-dark-theme')) return 'dark';
            return document.body === null ? null : 'light';
          };
          const answer = read();
          if (window.__dshThemeWatch === undefined) {
            window.__dshThemeWatch = true;
            const observer = new MutationObserver(() => { window.__dshThemeDirty = true; });
            observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-ds-theme-source', 'style'] });
            if (document.body !== null) {
              observer.observe(document.body, { attributes: true, attributeFilter: ['data-ds-dark-theme', 'style'] });
            }
          }
          return answer === null ? '' : String(answer);
        })();
        """
        var stopped = false
        var last: String?
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            guard !stopped else { return }
            webView.evaluateJavaScript(script) { value, _ in
                guard !stopped else { return }
                let raw = (value as? String) ?? ""
                let scheme: String? = raw.isEmpty ? nil : raw
                guard scheme != last else { return }
                last = scheme
                DispatchQueue.main.async { onChange(scheme) }
            }
        }
        return {
            stopped = true
            timer.invalidate()
        }
    }

    /// The script that reports which scheme the page is actually painting.
    ///
    /// `data-ds-theme-source` is written by DSH's own `ThemePresenter` on every
    /// theme change (`dsh-client-ui-layout`), and the body attribute is what the
    /// token stylesheets key the dark palette on. Reading BOTH means a page that
    /// has not published the source yet is still answered correctly from the
    /// palette attribute.
    static let themeProbeScript = """
    (function () {
      const root = document.documentElement;
      const source = root.getAttribute('data-ds-theme-source');
      const darkBody = document.body !== null && document.body.hasAttribute('data-ds-dark-theme');
      const background = document.body === null ? null : getComputedStyle(document.body).backgroundColor;
      return JSON.stringify({
        source: source === null ? null : source,
        darkAttribute: darkBody,
        bodyBackground: background,
        resolved: darkBody ? 'dark' : 'light',
      });
    })();
    """
}
