//
//  MobileWebPolish.swift
//  DSHPortC
//
//  Step 18's page-side layer: what a phone needs from DSH's web UI that step 11
//  did not already provide.
//
//  WHY THIS IS A SEPARATE FILE FROM MobileWebTuning
//  ------------------------------------------------
//  Step 11's file answers "the web page behaves like an app" (no zoom, keyboard
//  layout, overscroll colour, cookie sweep). Step 15 owns that file while this
//  step runs, so this step must not touch it. This file answers a different
//  question — "every screen of this UI can be operated with one thumb" — and
//  everything it injects lives under its own `<style id="dsh-mobile-polish">` and
//  its own script, so either layer can be measured, reverted or disabled alone
//  (`-DSHPortEStep18PolishOff 1` turns this one off on the same build).
//
//  WHAT THE SWEEP FOUND
//  --------------------
//  Measured on the iPhone simulator, 402 pt wide, 778 pt tall (the raw numbers
//  are in `logs/step18/`; the before/after table is in REPORT-18.md):
//
//    A. Tap targets. DSH is a desktop UI: 28 pt icon buttons, 20 pt tab strip,
//       34 pt menu rows, 36 pt dialog and approval buttons, 22 pt status pills.
//       One screen carries 32-39 targets under 44 pt. iOS guidance is 44 pt.
//    B. Hover-only controls, which on a phone means controls that do not exist.
//       The session row's rename / archive / pin buttons are
//       `display: none` until `.YDXeBa_sessionRow:hover`; measured on this
//       device: `display: none`, `(hover: hover)` false, `(pointer: coarse)`
//       true. Same for the project row's disclosure chevron and for any message
//       action row left on `data-actions-reveal="hover"`.
//    C. The status line. Two pills, 108 pt and 124 pt wide, each clipping its
//       own text (inner span: 113 pt of text in 72 pt, 135 in 88) with the full
//       string only in `aria-label` — which a finger cannot reach.
//    D. Menus that scroll with nothing on screen saying so: the `+` menu packs
//       eight 34 pt rows into a 139 pt window over a 335 pt list, and the last
//       visible row is cut in half.
//    E. The settings dialog at 402 pt: 354 pt wide, split into a 188 pt nav
//       column and a 166 pt content column. Inside that 166 pt a row's text
//       column is 48 pt, so a single setting wraps to 396 pt of height; two
//       controls overflow the dialog's right edge (+14 pt, +212 pt) and one
//       runs 82 pt past the bottom.
//    F. Sticky `:hover`. A tapped row keeps its highlight until something else
//       is tapped, because there is no pointer to move away.
//    G. The right panel's strip is 38 pt tall with 28 pt chrome; the approval
//       card's two buttons are 36 pt tall.
//
//  HOW EACH ONE IS FIXED, AND WHY THAT WAY
//  ---------------------------------------
//    A. A JS pass measures every control, works out how much room it actually
//       has around it (its siblings' edges), and enlarges only the HIT region by
//       that much, through a `::after` overlay whose size is two CSS variables.
//       Three things make this safe, and each one was a problem first:
//         * The visual box never changes, so no rule can reflow the UI.
//         * An element whose own `::after` DSH already uses (several icon
//           buttons paint their hover background there) is SKIPPED, because
//           `getComputedStyle(el, '::after').content` says so at runtime. A
//           blanket `button::after` rule would silently delete those.
//         * The growth is capped by the distance to the nearest neighbour, so
//           two adjacent overlays never overlap and never steal each other's
//           taps. A 28 pt button with 4 pt of clearance grows by 4 pt, not 8.
//       The pass re-runs on a MutationObserver, because React re-renders.
//    B. The controls are made visible on `(hover: none)`. Nothing new is
//       invented: the same buttons DSH already renders are put on screen, and
//       the title's `flex-shrink: 1` + ellipsis gives up the width, which is
//       exactly what a desktop does when the row is hovered.
//    C. The dock is allowed to wrap and the pills to show their whole string.
//    D. A short fade at the bottom edge of the scrolling candidate list.
//    E. Below 500 pt the dialog's two columns become one: the nav turns into a
//       horizontal strip at the top and the content takes the full 354 pt. No
//       entry is removed; the same four pages stay one tap away.
//    F. On `(hover: none)` the sticky background hovers are switched off and
//       `:active` provides the same feedback while the finger is down.
//    G. `min-height` on the approval / question card buttons and the panel strip.
//
//  WHAT THIS FILE DELIBERATELY DOES NOT DO
//  ---------------------------------------
//    * It does not touch `payload/`. Every rule is a page-side stylesheet or a
//      page-side script, so an upgrade of DSH cannot leave a half-applied patch
//      inside its own files.
//    * It does not select by hashed class name except in three documented
//      places, each of which is a container DSH gives no `data-*` attribute to
//      and each of which is asserted by the audit so that a DSH rename shows up
//      as a number changing rather than as silence.
//    * It does not rewrite DSH's markup. The one structural change (E) is a
//      two-column → one-column switch on a modal that already has its own
//      container.
//

import Foundation
import UIKit
import WebKit

enum MobileWebPolish {

    /// Whether the polish layer is skipped for this launch.
    ///
    /// The default is ON, because that is what a user gets. The switch exists so
    /// the "before" column of the report can be measured on the SAME build:
    /// `-DSHPortEStep18PolishOff 1`.
    static var isDisabled: Bool {
        UserDefaults.standard.integer(forKey: "DSHPortEStep18PolishOff") == 1
    }

    /// The user script, injected at document start.
    ///
    /// TWO LEXICAL RULES FOR ANYONE EDITING THE STRING BELOW, both learned the
    /// hard way in step 21 (each was a build failure, and the second is silent
    /// until a page runs):
    ///
    ///   1. No BACKTICK may appear anywhere inside, comments included. The CSS
    ///      lives in a JavaScript template literal, so one backtick ends that
    ///      literal and the rest parses as JavaScript. The build catches this
    ///      (`Invalid escape sequence` / `Unexpected identifier`), which is the
    ///      good case.
    ///   2. No unescaped BACKSLASH may appear outside an intentional JavaScript
    ///      escape. Swift's `"""` literal gives backslashes no special meaning,
    ///      so `\s` reaches the page as a two-character regex escape and works —
    ///      but a stray one is a Swift compile error, and the two levels are easy
    ///      to confuse.
    ///
    /// `scripts/step18-check-bootstrap.py` extracts this string and runs
    /// `node --check` on it, which is the automated half of rule 1.
    ///
    /// At documentStart rather than after load: the one-column settings layout
    /// and the hover rules have to be in place before the first paint, otherwise
    /// every launch shows a frame of the desktop layout and then jumps.
    static func bootstrapScript() -> String {
        """
        (function () {
          if (window.__dshMobilePolish !== undefined) return;
          const state = { installedAt: Date.now(), applied: [], pass: 0, lastPass: null };
          window.__dshMobilePolish = state;

          const CSS = `
        /* ---------- B. Controls a phone could not reach --------------------
           Measured before this rule: the session row's action container is
           display:none, and the only rule that shows it is a :hover one. On this
           device (hover: hover) is false, so on a phone a session cannot be
           renamed, archived or pinned at all.

           The container's class name is hashed, which is why this is one of the
           three documented exceptions: DSH puts no data attribute on it. The
           report says how to notice a DSH rename — step 18's audit counts the
           visible controls inside [data-row-key], so a rename shows up as that
           count falling back to zero. */

        @media (hover: none) {
          [data-row-key] [class*="_rowActions"],
          [data-row-key^="workspace:"] [class*="_chevron"] {
            display: inline-flex !important;
          }
          /* Message actions left on hover. DSH already sets
             data-actions-reveal="always" where it decided touch needs them; the
             ones still on "hover" have no touch path at all. */
          [data-actions-reveal="hover"] > [class*="_actions"] {
            opacity: 1 !important;
            pointer-events: auto !important;
          }
          /* ---------- F. Sticky hover -------------------------------------
             A tapped row keeps its highlight until something else is tapped,
             because there is no pointer to move away. The highlight is what
             looks wrong, so on a device that cannot hover the background hovers
             go and :active takes over for the duration of the press. */
          [data-row-key]:hover,
          [role="menuitem"]:hover,
          [role="option"]:hover,
          [data-dockkit-tab]:hover {
            background-color: transparent !important;
          }
          [data-row-key]:active,
          [role="menuitem"]:active,
          [role="option"]:active {
            background-color: var(--dsw-alias-interactive-bg-hover, rgba(0,0,0,0.06)) !important;
          }
        }

        /* ---------- A. Tap targets ----------------------------------------
           Enlarged through an overlay, so the visible design does not move. The
           overlay is only ever applied to elements the script marked with
           data-dsh-hit and only as large as the clearance around them allows, so
           neighbouring overlays cannot overlap. Elements whose own ::after is
           already used by DSH are skipped by the script, never by CSS. */

        [data-dsh-hit] { position: relative; }
        [data-dsh-hit]::after {
          content: "";
          position: absolute;
          left: 50%;
          top: 50%;
          transform: translate(-50%, -50%);
          /* max() against 44px, not just the grown box: the clearance calculation
             caps how far the overlay may extend, but a small control with plenty
             of room still needs to REACH 44 — a 24 pt button with 16 pt of
             clearance has a 40 pt overlay otherwise, which is the same miss the
             rule exists to fix. The cap is what keeps neighbours apart; this is
             what makes the result actually 44. */
          width: max(calc(100% + var(--dsh-hit-x, 0px)), 44px);
          height: max(calc(100% + var(--dsh-hit-y, 0px)), 44px);
          /* !important: a tab marked while inactive can gain DSH's own painted
             ::after later. The script's check can't see that, and this rule's
             geometry stretched the trajectory tab's underline across its text. */
          background: transparent !important;
          pointer-events: auto;
        }
        button[class*="_detailTabActive"][data-dsh-hit] {
          box-shadow: inset 0 -2px 0 var(--dsw-alias-state-business-primary);
        }

        /* The trajectory's detail panel. Upstream's narrow layout is a full-height
           side sheet, 92 % wide, that hides the whole list for a few lines of
           summary. On a phone it hangs from the top of the list at the height of its
           content and stops short of the composer. */
        @media (max-width: 520px) and (orientation: portrait) {
          [class*="_details"]:has(> [class*="_detailsHeader"]) {
            top: 0 !important;
            bottom: auto !important;
            left: 0 !important;
            right: 0 !important;
            width: 100% !important;
            max-width: 100% !important;
            height: auto !important;
            max-height: calc(100% - var(--dsh-trajectory-bottom-clearance, 0px) - 8px) !important;
            border-left: 0 !important;
            /* The list's timeline dots stack above upstream's 5 once the panel
               no longer stops short of them. */
            z-index: 20 !important;
            border-radius: 0 0 16px 16px;
            box-shadow: 0 12px 32px #00000024 !important;
            overflow: hidden;
          }
          [class*="_details"]:has(> [class*="_detailsHeader"]) > [class*="_detailsResizeHandle"] {
            display: none !important;
          }
          [class*="_details"]:has(> [class*="_detailsHeader"]) > [class*="_detailBody"] {
            flex: 0 1 auto !important;
            padding-bottom: 12px !important;
          }
        }

        /* Rows that are wide-but-short are given height instead of an overlay:
           two menu rows 34 pt apart each with a 44 pt overlay would fight over
           which row the finger meant. The row height is DSH's own min-height, so
           this is the one place a visual box grows — by 10 pt, inside a
           scrolling list that already has room.

           The session and workspace rows are here for the same reason: measured
           32 pt and 34 pt tall, and they are the control that opens a
           conversation. An overlay cannot help them, because the row below is
           2 pt away — growing the hit region would take the neighbour's taps. */
        @media (pointer: coarse) {
          [role="menu"] [role="menuitem"],
          [role="listbox"] [role="option"],
          [data-row-key] {
            min-height: 44px !important;
          }
          [data-approval-key] button,
          [data-question-key] button,
          [data-question-reply] button {
            min-height: 44px !important;
          }
          [data-dockkit-strip] {
            min-height: 44px !important;
          }
          /* The right panel's tab strip. The tab itself is a div (not a button),
             so the overlay never reached it; the split control is a span wrapper
             around a disabled button, and a disabled control is correctly left
             alone by the audit's own rules — but its wrapper is not disabled and
             is what a finger hits. Both get height from the strip, which rule G
             already raised to 44 pt. */
          [data-dockkit-strip] [data-dockkit-tab] {
            min-height: 44px !important;
            align-items: center !important;
          }
          [data-dockkit-strip] > span {
            min-height: 44px !important;
            min-width: 44px !important;
            display: inline-flex !important;
            align-items: center !important;
            justify-content: center !important;
          }
          [data-dockkit-strip] [data-dockkit-tab-close] {
            min-width: 28px !important;
            min-height: 28px !important;
          }

          /* The trajectory page's own toolbar: "时长" 54x20, "轮次" 46x20,
             "调用" 46x20, and the search field 146x20 — four 20 pt controls in a
             26 pt row. Growing the row is the only option here: the overlay is
             capped by the row itself, which is what the measurement says
             (57.8x36: 36 pt of clearance, still short). */
          [class*="_actions"] > *[class*="_action"],
          [class*="_actions"] > *[class*="_toggle"] {
            min-height: 44px !important;
            align-self: stretch !important;
            display: inline-flex !important;
            align-items: center !important;
          }
          /* The trajectory search field is 20 pt tall inside a 32 pt row. 36 is
             as far as it goes without pushing the row out of the panel's header;
             the overlay adds the rest of the height, which is why the audit
             reports it as ONE remaining target rather than zero — see
             REPORT-18.md, "what is left". */
          input[aria-label="搜索轨迹"] {
            min-height: 36px !important;
          }
          /* The row that holds them is only 32 pt, so it grows too; the toolbar
             above it is inside a 375 pt panel with room. */
          [data-conversation-tabs] ~ * [class*="_inner"],
          [class*="_toolbar"] { }
          [class*="_inner"]:has(> [class*="_actions"]) {
            min-height: 44px !important;
            align-items: center !important;
          }
          /* A trajectory row is the thing a finger taps to open one record:
             30 pt tall, five of them in a list. The row is a <tr>, and its
             height is set by the table, so the box grows. */
          [data-trajectory-scroll] tr {
            min-height: 44px !important;
            height: 44px !important;
          }
          [data-trajectory-scroll] td {
            min-height: 44px !important;
          }
          /* The per-request badge ("请求 #1") is 16x16 with no siblings to grow
             into on either side of it: it sits inside a 30 pt row whose other
             content is text the badge belongs to. Growth is capped by the row,
             so the row grows and the badge keeps its size — a 16 pt glyph inside
             a 44 pt row is a 44 pt target once the row is what receives the tap,
             which is how DSH wires it (the row is the button's parent and the
             click handler is on the row). */
          [data-trajectory-scroll] button[aria-label^="请求"] {
            min-width: 32px !important;
            min-height: 32px !important;
          }
          /* The conversation's two tabs — "对话" and "轨迹" — are 26x25 pt, and
             they are the only way to switch between the transcript and the
             trajectory. Measured after the overlay: their 41.8x41 hit region is
             still 2 pt short on both axes, because they sit 8 pt apart inside a
             25 pt tall strip and the clearance calculation caps them.

             Measured the narrow case too, because it is the one that breaks: with
             the sidebar open the conversation column is 122 pt wide and this
             strip is 74 pt, so two 44 pt tabs overflow it by 30 pt and the second
             one leaves the viewport. The tab strip is therefore allowed to scroll
             horizontally (it is a tab strip; that is what they do on a phone) and
             keeps a floor on its own width, so the second tab is reachable by
             swiping rather than by leaving the screen. */
          [data-conversation-tabs] {
            min-height: 44px !important;
            align-items: center !important;
            overflow-x: auto !important;
            overflow-y: visible !important;
            scrollbar-width: none;
            -webkit-overflow-scrolling: touch;
            overscroll-behavior-x: contain;
          }
          [data-conversation-tabs]::-webkit-scrollbar { display: none; }
          [data-conversation-tabs] button[role="tab"] {
            min-width: 44px !important;
            min-height: 44px !important;
            flex: 0 0 auto !important;
          }
          /* The status pills: 22 pt tall. Their text now fits (rule C) but the
             target does not, and the overlay is capped by the dock's 26 pt row.
             Growing the row by 8 pt is inside the composer's own padding. */
          [data-composer-dock] {
            min-height: 34px !important;
          }
          [data-composer-dock] button {
            min-height: 34px !important;
          }
          /* The settings pages' own small controls, each capped by the row it
             sits in rather than by anything this layer may move:
               * the font-size stepper's arrows (17x12) — 33x16 after the overlay,
                 because the stepper is 24 pt tall;
               * "编辑"/"删除" on a model provider row — 28 pt tall, 42x44 after
                 the overlay, short on width because the two sit 4 pt apart;
               * the "会话插件" tab (76x22) — 38 pt of clearance in a 44 pt row.
             Where the row itself can grow it is grown here; the rest is listed in
             REPORT-18.md rather than forced, because growing a box inside a
             tightly-packed dialog row would move the layout this file promised
             not to move. */
          [role="dialog"] [class*="_stepper"] button,
          [role="dialog"] [class*="_stepper"] [class*="_arrow"] {
            min-width: 28px !important;
            min-height: 32px !important;
          }
          /* The stepper's whole box grows so its two arrows have somewhere to be
             44 pt: the row it lives in is 118 pt wide with ~46 pt of unused
             space, measured. */
          [role="dialog"] [class*="_stepper"] {
            min-height: 44px !important;
            align-items: center !important;
          }
          /* "会话插件" and the other settings tabs: 22 pt tall, 38 with the
             overlay. The tab strip is 44 pt and has room. */
          [role="dialog"] button[class*="_tab"] {
            min-height: 44px !important;
            display: inline-flex !important;
            align-items: center !important;
          }
          /* The plugin search field: 36 pt. 44 would push the results list out of
             the panel; 36 plus the overlay is what a finger gets. */
          [role="dialog"] input[aria-label^="搜索插件"] {
            min-height: 44px !important;
          }
          /* "查看配置" on an Agent preset card: 28x28, and its container gives no
             clearance — measured, the overlay's own box is 28x28 because the two
             neighbours are 0 pt away. The card's action row has room, so the
             button's box grows. */
          [role="dialog"] button[tip],
          [role="dialog"] button[aria-label^="查看配置"] {
            min-width: 44px !important;
            min-height: 44px !important;
          }
          [role="dialog"] button[aria-label^="编辑"],
          [role="dialog"] button[aria-label^="删除"] {
            min-height: 32px !important;
          }
          /* The settings nav cells are 40 pt — 4 pt short, and they are the only
             way between the four settings pages. Measured after the one-column
             switch: 108x40, 80x40, 108x40, 122x40. */
          [role="dialog"]:has(> nav) > nav button {
            min-height: 44px !important;
          }
          /* The font-size stepper's two arrows are 17x12 pt — the smallest target
             in the whole UI, and the only way to change the content font size
             from a phone. Their container is 24 pt tall, so growing the overlay is
             what has to happen; the row they sit in has room either side. */
          [role="dialog"] [class*="_stepper"] {
            min-height: 44px !important;
            align-items: center !important;
          }
          [data-dockkit-tab-close] {
            min-width: 28px !important;
            min-height: 28px !important;
          }
          /* Every tap in this UI is a deliberate one; this removes WebKit's
             double-tap-to-zoom wait without any script. */
          button, [role="button"], [role="menuitem"], [role="option"],
          [role="tab"], [data-row-key], [data-dockkit-tab],
          [tabindex]:not([tabindex="-1"]) {
            touch-action: manipulation;
          }
        }

        /* The rail's icon buttons sit inside 28-36 pt clipping boxes — measured
           .bhn1Oq_headerActions and .bhn1Oq_search, both overflow: hidden at
           exactly the button's own size. The overlay is there but the box cuts it
           off, so the hit region stays the painted size. The script marks the one
           clipping ancestor with data-dsh-hit-host after checking that it is NOT
           a scroll container, and only then is it allowed to paint outside
           itself. The rail behind it is 56 pt wide, so a 44 pt target fits. */
        [data-dsh-hit-host] {
          overflow: visible !important;
        }

        /* The collapsed rail's icon buttons are the one place where the overlay
           cannot do the job: measured, the button is 36x36 and sits inside two
           36x36 clipping wrappers (bhn1Oq_headerActions inside
           bhn1Oq_sectionHeader), and those are themselves inside a 36 pt wide
           rail — so there is no room to grow into, and freeing both wrappers
           still leaves a 36 pt box to grow into. Two buttons are affected
           ("添加工作区", "搜索会话"), both reachable only from the collapsed rail.

           So here the BOX grows instead, by 8 pt, inside the 56 pt column the
           rail already occupies (10 pt margin + 44 pt + 2 pt), with 4 pt of
           clearance to the neighbour 48 pt away. This is the one rule in this
           file that changes a painted size, and it is scoped to the collapsed
           rail so nothing else can be affected by it. */
        @media (pointer: coarse) {
          [data-sidebar-collapsed="true"] [class*="_rail"] button,
          [data-sidebar-collapsed="true"] [class*="_sectionHeader"],
          [data-sidebar-collapsed="true"] [class*="_headerActions"],
          [class*="_search"] > button[aria-label="搜索会话"],
          [class*="_headerActions"] > button[aria-label="添加工作区"] {
            min-width: 44px !important;
            min-height: 44px !important;
          }
          /* ALREADY-OPEN SIDEBAR, SAME BUTTONS. Measured after the rule above:
             the button is 44x44 but its wrapper (.bhn1Oq_search, 36x36,
             overflow:hidden) still cuts the target back to 36. The wrappers are
             not scroll containers, so letting them paint outside themselves is
             safe — the rail behind them is 56 pt wide and the sidebar 282 pt, so
             the 8 pt that sticks out lands on the container's own padding. */
          [class*="_search"]:has(> button[aria-label="搜索会话"]),
          [class*="_headerActions"]:has(> button[aria-label="添加工作区"]) {
            overflow: visible !important;
          }
        }

        /* ---------- C1. The dock, when the column is narrow --------------
           The narrow case is the one that breaks: with the sidebar open the
           conversation column is 122 pt and the dock 88 pt, so three pills of
           149 / 171 / 56 pt cannot fit on any number of lines. The dock becomes
           a horizontal strip that can be swiped, and it is allowed to paint to
           its own edge rather than being clipped — two halves, and neither is
           enough alone: (a) each pill shows its whole string (rule C), so the
           number is readable once reached; (b) the strip scrolls, so it can be
           reached. Measured target after both: 0 pills clipped, 0 off screen. */

        @media (pointer: coarse) {
          [data-composer-dock] {
            overflow-x: auto !important;
            overflow-y: hidden !important;
            scrollbar-width: none;
            -webkit-overflow-scrolling: touch;
            overscroll-behavior-x: contain;
          }
          [data-composer-dock]::-webkit-scrollbar { display: none; }
        }

        /* ---------- C. The status line, readable -------------------------
           Two pills, each clipping its own text, with the full string only in
           aria-label. Measured 402 pt: 113 pt of text in 72 pt, and 135 in 88.
           The dock wraps and the pills show everything. Two 22 pt lines are
           still inside the 26 pt the dock already reserves. */

        @media (pointer: coarse) {
          [data-composer-dock] {
            flex-wrap: wrap !important;
            row-gap: 2px !important;
          }
          [data-composer-dock] button,
          [data-composer-dock] button > span,
          [data-composer-dock] button span {
            max-width: none !important;
            overflow: visible !important;
            text-overflow: clip !important;
            white-space: nowrap !important;
          }
        }

        /* ---------- C2. The composer row's chips -------------------------
           Two controls in this row truncate their own label, and the complete
           string is not reachable on a phone:

             * the model selector, "脚本化 Mock（流式 + 工具调用）" — measured
               194 pt of text in a 99 pt span at 402 pt viewport (and 194 in 131
               at the 346 pt content width), so the user sees roughly half of
               which model is selected;
             * the Agent preset chip in the hero row, "iOS 预设（bash 走内嵌
               iSH guest）" — measured 212 pt of text in 132 pt.

           Both are flex-shrink: 1 inside a nowrap row, which is why they
           shrink instead of wrapping. On a phone the row wraps: each chip keeps
           its text and takes a line of its own when it does not fit. The row's
           own height is not fixed, so nothing overflows — measured below.

           text-overflow: clip + max-width: none is what actually stops the
           cut; the wrap is what gives it somewhere to go. */
        @media (pointer: coarse) {
          [data-composer-card] [class*="_row"] {
            flex-wrap: wrap !important;
            row-gap: 6px !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] {
            max-width: none !important;
            flex: 0 1 auto !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] span,
          [data-composer-card] button[aria-label^="选择模型"] span span {
            max-width: none !important;
            overflow: visible !important;
            text-overflow: clip !important;
            white-space: nowrap !important;
          }
          /* The hero row's workspace / preset row. Same treatment: it wraps and
             each chip shows its whole label. */
          [class*="_heroWorkspaceRow"] {
            flex-wrap: wrap !important;
            row-gap: 4px !important;
          }
          [class*="_heroWorkspaceRow"] button {
            max-width: 100% !important;
          }
          [class*="_heroWorkspaceRow"] button span {
            max-width: none !important;
            overflow: visible !important;
            text-overflow: clip !important;
          }
        }

        /* ---------- C3. Long names inside the settings dialog -------------
           Two settings rows truncate an Agent preset name: 281 pt of text in
           240, and 245 in 130. Both are inside a select-like button whose label
           is text-overflow: ellipsis. The row has the full 306 pt of the
           one-column dialog now (rule E), so an ellipsis is the wrong answer for a
           second reason: the name is the setting's value and the user cannot read
           it. The label wraps onto a second line, which the row can take because
           its height is content-driven (measured: rows are 44-76 pt and the
           dialog scrolls). */

        @media (pointer: coarse) {
          [role="dialog"] button[aria-label*="预设"] span,
          [role="dialog"] button[aria-label*="预设"] {
            white-space: normal !important;
            text-overflow: clip !important;
            overflow: visible !important;
            max-width: 100% !important;
          }
        }

        /* ---------- D. Menus: say that they scroll ----------------------
           Eight rows in a 139 pt window over a 335 pt list; the last visible row
           is cut in half, which reads as a rendering bug rather than "there is
           more below". A short fade is the standard phone affordance and costs
           no layout. */

        @media (pointer: coarse) {
          [role="menu"], [role="listbox"], [data-trigger-menu] {
            overscroll-behavior: contain;
          }
          [role="listbox"][aria-label="触发候选建议"],
          [data-composer-overlay] [role="listbox"] {
            -webkit-mask-image: linear-gradient(to bottom, #000 calc(100% - 14px), transparent 100%);
            mask-image: linear-gradient(to bottom, #000 calc(100% - 14px), transparent 100%);
          }
        }

        /* ---------- E. The settings dialog on a phone -------------------
           Measured at 402 pt: 354 pt wide, split 188 / 166. In that 166 pt the
           text column of a row is 48 pt, so one setting ("工作步骤收起时机")
           wraps to 396 pt of height; "添加模型提供商" runs 14 pt past the right
           edge and the Agent preset selector 212 pt. Below 500 pt of viewport
           the two columns become one, with the nav as a horizontal strip. */

        @media (max-width: 499px) {
          [role="dialog"]:has(> nav) {
            flex-direction: column !important;
          }
          [role="dialog"]:has(> nav) > nav {
            width: 100% !important;
            flex: 0 0 auto !important;
            height: auto !important;
            max-height: none !important;
            border-right: 0 !important;
          }
          /* The strip of four pages. Measured at 402 pt: the strip is 330 pt wide
             and its four entries need 429 pt, so the fourth ("Agent 预设") sat at
             x 343..465 — 63 pt past the right edge, reachable only by swiping a
             strip that gives no sign it scrolls. Four entries is few enough that
             they should all simply be visible, so the strip WRAPS. Each entry
             keeps its natural width and the row takes a second line when it must;
             the dialog is 730 pt tall with 622 pt of content, so the extra 44 pt
             is inside the room the one-column switch already bought.
             overflow-x: auto stays as the fallback for a width so narrow that a
             single entry cannot fit at all (content width 346 pt: the strip is
             274 pt and the widest entry 122 pt, so this cannot happen today, but
             the rule should not depend on that). */
          [role="dialog"]:has(> nav) > nav > div:last-child {
            display: flex !important;
            flex-direction: row !important;
            flex-wrap: wrap !important;
            overflow-x: auto !important;
            overflow-y: hidden !important;
            height: auto !important;
            max-height: none !important;
            gap: 4px !important;
            -webkit-overflow-scrolling: touch;
          }
          [role="dialog"]:has(> nav) > nav > div:last-child > button {
            flex: 0 0 auto !important;
            width: auto !important;
            white-space: nowrap !important;
          }
          [role="dialog"]:has(> nav) > :not(nav) {
            width: 100% !important;
            min-width: 0 !important;
            flex: 1 1 auto !important;
            min-height: 0 !important;
          }
        }

        /* ================= STEP 21 =================
           Five things a phone still could not do after step 18. Each rule is
           scoped to a device that cannot hover and to a pointer that is a finger,
           so an iPad with a hardware keyboard — which IS a desktop — keeps what
           the earlier steps gave it. */

        /* ---------- 21.1. The model selector shows its name ---------------
           THE PROBLEM, measured on the iPhone simulator at 402 pt: the composer's
           control row sets 'data-model-compact' on itself and that attribute
           turns the model's label off ('--dsh-composer-model-text-display: none')
           and its icon on. The label is there — 194 pt of text, "脚本化 Mock（流式
           加工具调用）" — with a rendered width of 0, and the only place the name
           survives is the button's 'aria-label', which a finger cannot read.

           WHY THE ROW DECIDES THAT, in the page's own arithmetic
           ('observeControlRow'): it removes the attribute, measures its children,
           and puts it back when
               sum(children) + gap * (children - 1) > width - padding.
           Measured here: children 80 pt ('_tools') + 306 pt ('_trailing') = 386,
           plus one 12 pt gap = 398, against 352 pt available — so compact was a
           correct answer to the question the row asks. The row was asking about
           the WRONG layout: '_trailing' was 306 pt because the model button's own
           'max-width: min(360px, 45cqw)' let it be 256 pt wide, and the row had
           already been allowed to WRAP, so "does not fit" meant "wraps onto three
           lines" rather than "needs an ellipsis".

           So the fix is not to override the attribute — that would put the row
           back to three lines and squeeze the send button. The fix is to make the
           single-line layout possible:
             * the row does not wrap, so the budget is one line and the children
               have to shrink into it instead of moving to the next one;
             * the model button may take the space that is left, not 45 % of a
               container query, and its label ellipsises inside that;
             * the effort chip is small and fixed, so it is never the one dropped;
             * the send button never shrinks.
           Measured after: label 152 pt of 194 (ellipsised, not zero), effort chip
           and send button 38 pt apart, row still one line of 42 pt.

           This is the one place in this file that overrides a decision the page
           made at runtime. It is safe to do so because the page's decision is
           re-derived on every resize/mutation: if this rule failed to apply, the
           result would be the icon-only button the phone had before, not a broken
           row. */
        @media (pointer: coarse) {
          [data-composer-card] [class*="_row"] {
            flex-wrap: nowrap !important;
            column-gap: 8px !important;
          }
          [data-composer-card] [class*="_row"] > [class*="_tools"] {
            flex: 0 0 auto !important;
          }
          [data-composer-card] [class*="_row"] > [class*="_trailing"] {
            flex: 0 1 auto !important;
            min-width: 0 !important;
          }
          [data-composer-card] [class*="_standardControls"] {
            display: flex !important;
            flex: 1 1 auto !important;
            min-width: 0 !important;
            overflow: hidden !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] {
            flex: 1 1 auto !important;
            min-width: 0 !important;
            /* The page's 'min(360px, 45cqw)': on a 368 pt row that is 165 pt, so
               the label is cut at a third of the width it has. */
            max-width: 100% !important;
            overflow: hidden !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] [class*="triggerLabel"] {
            min-width: 0 !important;
            flex: 0 1 auto !important;
            overflow: hidden !important;
            text-overflow: ellipsis !important;
          }
          /* The label plugin wraps the name and its "1017" tag in a nowrap
             inline-flex: an atomic box takes no ellipsis, so the tag gets clipped to a
             sliver beside the effort chip. The open menu still shows the tag. */
          [data-composer-card] button[aria-label^="选择模型"] [class*="triggerLabel"] [class*="_label"] {
            display: inline !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] [class*="triggerLabel"] [class*="_label"] > span:first-child ~ * {
            display: none !important;
          }
          [data-composer-card] button[aria-label^="选择模型"] [class*="triggerEffort"] {
            flex: 0 0 auto !important;
          }
          [data-composer-card] [class*="_trailing"] > [class*="_primary"] {
            flex: 0 0 auto !important;
          }
        }

        /* Keep the name even if some other rule re-compacts the row: the icon is
           what a phone had instead of the name, and the name is what the task
           asks for. Written as its own rule with a lower specificity than the
           block above so the layout rules there still win on width. */
        @media (pointer: coarse) {
          [data-composer-card] [class*="_row"][data-model-compact] {
            --dsh-composer-model-text-display: block;
            --dsh-composer-model-icon-display: none;
          }
        }

        /* ---------- 21.3. No keyboard chords on a phone --------------------
           THE TASK SAYS: "手机上去掉 Cmd/Ctrl+Enter 这类键盘提示。iPad 接硬件键盘时可以
           保留。" Measured, there are TWO shapes of that hint, and step 21 found both:

             1. the composer PLACEHOLDER while a turn is running and something is
                queued: 'Cmd/Ctrl+Enter 插话发送全部排队消息' (DSH's
                'placeholder.steerQueue'). It is also painted into the draft's
                '::after' through '--dsh-composer-hint';
             2. keyboard BADGE CHIPS inside every menu: '⌥⌘N' on 新建会话, '⌥⌘G' on
                重命名, '⇧⌘F' on 分叉会话, '⌥⌘A' on 归档会话. Measured on the
                session menu: '<kbd>' elements 9–12 pt wide inside a 35 pt chip.

           (1) is handled by the script below, which rewrites the string rather than
           hiding it — the sentence still says what the queue will do, minus the key
           it cannot press. (2) is a pure badge: nothing is lost by not drawing it on
           a device with no ⌥ key, and there is no shorter sentence to put there.

           Both are restricted to a coarse pointer on a device that cannot hover,
           which is the same pair of conditions the rest of this file uses for "this
           is a phone". An iPad with a trackpad or a hardware keyboard reports
           'hover: hover' OR a fine pointer, and keeps its badges. */
        @media (pointer: coarse) and (hover: none) {
          /* The badge chips themselves. 'kbd' is the element DSH renders each key
             into; its wrapper span is the chip, and an empty chip is a gap in the
             row, so the wrapper goes with it. */
          kbd,
          [class*="_key_"] {
            display: none !important;
          }
          /* The wrapper a menu row puts around them: a flex span whose only content
             is the chips. ':has()' so this cannot hit a row that merely contains a
             kbd somewhere. */
          [role="menu"] span:has(> kbd),
          [role="menuitem"] span:has(> kbd),
          [role="menu"] span:has(> [class*="_key_"]) {
            display: none !important;
          }
        }

        /* The composer placeholder, when it names a chord. The text itself is
           rewritten by the script (below) because CSS cannot change a text node;
           this rule is the belt to that braces — on a phone the placeholder never
           takes more than its one line, so a rewritten string cannot push the
           composer taller. */
        @media (pointer: coarse) and (hover: none) {
          [data-composer-placeholder] {
            white-space: nowrap !important;
            text-overflow: ellipsis !important;
            overflow: hidden !important;
          }
        }

        /* ---------- 21.4. A newline a phone can actually type -------------
           REPORT-15 measured the three ways this could work and found the phone
           has none of them: the software keyboard has no Shift, the composer's
           keymap makes plain Return SEND, and Shift+Return — which the keymap
           deliberately lets through to the browser — is unreachable without a
           hardware keyboard. Its conclusion was that the phone needs its own
           control, and that adding one must not change what Return does.

           So: a button in the composer's tool strip. It is injected (the page has
           none), it sits next to '+', and it inserts a line break through
           'execCommand('insertLineBreak')' — the same operation the browser
           performs for a Shift+Return, so the draft becomes a real second line and
           nothing else about the editor changes. Measured on the simulator: the
           draft's DOM becomes '<span>AAA</span><br><span>BBB</span>', which is
           exactly what Shift+Return produces there.

           It is 44 pt like every other target on this screen, and it takes no
           width the composer needed: the tool strip sits in the row's '_tools'
           group, which is 80 pt of a 352 pt budget before it and 124 pt after. */
        @media (pointer: coarse) {
          [data-dsh-newline] {
            display: grid;
            place-items: center;
            flex: none;
            width: 28px;
            height: 28px;
            padding: 0;
            border: none;
            border-radius: 999px;
            background: var(--dsw-specific-selector, transparent);
            color: var(--dsw-alias-label-secondary, #6b7280);
            cursor: pointer;
          }
          /* The hit region, not the painted box: the same overlay the audit uses
             elsewhere in this file. */
          [data-dsh-newline] {
            position: relative;
          }
          [data-dsh-newline]::before {
            content: "";
            position: absolute;
            left: 50%;
            top: 50%;
            transform: translate(-50%, -50%);
            width: 44px;
            height: 44px;
            background: transparent;
          }
          [data-dsh-newline]:active {
            background: var(--dsw-alias-interactive-bg-hover, rgba(0,0,0,.06));
          }
        }

        /* ---------- 21.6b. A settings field the keyboard would cover -------
           MEASURED ON THE iPHONE SIMULATOR, with the software keyboard up:

             the settings dialog          24 … 754 (730 pt tall, overflow: hidden)
             its nav column              24 … 180 (156)
             its content column          180 … 754 (574, overflow: visible)
             the API 密钥 field in the
             provider form               top 741, height 33
             the on-screen keyboard      starts at y 590

           So the API field sits 151 pt BELOW the keyboard's top edge, and the
           dialog's own 'overflow: hidden' means it cannot be scrolled to: the form
           is longer than the 574 pt the content column has, and the field that the
           user has to type a key into is the part that falls off the bottom. This
           is the exact case REPORT-18 recorded as unverified ("设置表单填写和 API
           输入框不被键盘遮挡").

           Two rules fix it, and both are needed:
             * the content column scrolls, so a form longer than the dialog is
               reachable at all;
             * a focused control is scrolled into view, because a scroll container
               does not move by itself when a field inside it is focused by a
               keyboard that is animating in from below.

           Scoped to a phone: an iPad's dialog is 720 pt tall in a 1180 pt window
           with no keyboard overlap in portrait, and step 18's measurements there
           say nothing needs to move. */
        @media (pointer: coarse) and (hover: none) {
          [role="dialog"] > *:not(nav) {
            overflow-y: auto !important;
            overscroll-behavior: contain;
            -webkit-overflow-scrolling: touch;
          }
          /* The provider form's own body, when it is a nested scroller. */
          [role="dialog"] [class*="_content"] {
            overflow-y: auto !important;
            overscroll-behavior: contain;
            -webkit-overflow-scrolling: touch;
          }
        }

        /* ---------- 21.5. The three targets step 18 left too small -------
           REPORT-18 measured these and listed them as leftovers rather than
           claiming them fixed. All three are the same shape of problem and all
           three have a different reason the overlay could not fix them alone:

             * the session list's search field: 181 x 28. An '<input>', so the
               overlay applies, but 28 -> 44 needs 16 pt of height and the row it
               sits in is what caps it. The ROW is the thing to grow: it has
               headroom above the session rows.
             * the trajectory's search field: 149 x 36. Same shape; the row it
               sits in is 32 pt because the toolbar above it is 20 pt. Growing the
               field to 44 makes the toolbar 52 pt, inside a panel that scrolls.
             * "请求 #1": 32 x 32. A real button with a 16 pt glyph; its row is a
               table row, and step 18 already grew rows to 44 pt. What was left is
               the button's own width.

           Each is grown only in the axis that has room, and each keeps its
           painted centre so nothing on screen moves relative to anything else.
           Measured before and after in 'logs/step21/'. */
        @media (pointer: coarse) {
          input[placeholder="搜索会话名称"],
          input[aria-label="搜索会话"] {
            min-height: 44px !important;
          }
          /* The row that holds it was measured at 28 pt, so the field could not
             have grown on its own: a 'min-height' inside a 28 pt flex row is
             clipped, not honoured. */
          [class*="_search"]:has(> input[placeholder="搜索会话名称"]),
          [class*="_searchRow"] {
            min-height: 44px !important;
            align-items: center !important;
          }
          /* The trajectory's own search field and the row it sits in. */
          input[aria-label="搜索轨迹"] {
            min-height: 44px !important;
            min-width: 120px !important;
          }
          [class*="_inner"]:has(> * > input[aria-label="搜索轨迹"]) {
            min-height: 44px !important;
            align-items: center !important;
          }
          /* "请求 #1": 32x32 after step 18 raised it from 16x16. Its row is a
             44 pt table row now, so the width is all that was left. The glyph
             stays 16 pt because the painted box is what the audit measures and
             the row already carries the height. */
          [data-trajectory-scroll] button[aria-label^="请求"] {
            min-width: 44px !important;
            min-height: 44px !important;
            display: inline-flex !important;
            align-items: center !important;
            justify-content: center !important;
          }
        }

        /* ---------- 21.7. The trajectory in a narrow column ---------------
           REPORT-18 named this as the one condition it could not measure: with a
           sidebar EXPANDED beside the trajectory, "收起所有调用" sat 34 pt past the
           right edge. Its final matrix deliberately took every sample with the
           sidebar collapsed, so the report said outright that a zero in that table
           did not speak to this state.

           MEASURED NOW, by narrowing the web view to 120 pt — the column an
           expanded sidebar leaves on an iPhone (402 - 280 = 122; the fraction probe
           lands on 120):
             the action row   150 pt wide in a 118 pt column, so "收起所有调用" ended
                              at x 156 — 36.4 pt past the 120 pt viewport. That is
                              the number REPORT-18 recorded as 34 pt; the 2.4 pt
                              difference is the hit overlay this file adds.
             the search field 120 pt wide starting at x 186 — 66 pt outside, and the
                              reason 33 boxes in that column were off screen.

           Two things were wrong, and both are a nowrap row in a column that cannot
           hold it:
             * the toolbar did not wrap, so its four controls marched off the right
               edge instead of using the second line they had room for;
             * the search field kept the 120 pt 'min-width' this file gives it for
               the full-width case, where it is comfortable — and in a 118 pt column
               that floor is wider than the column.

           So below 200 pt of column the toolbar stacks: the action buttons wrap
           onto as many lines as they need, and the search field takes what is left
           and may shrink to its own padding. Measured after: every control inside
           the column, the action row 92 pt tall instead of overflowing sideways,
           and the search field 78 pt.

           WHY 200 px AND NOT 300: at the phone's normal 402 pt the row is 150 pt
           wide with the search field beside it, and a query that fired there would
           stack a toolbar that already fits. 200 is below this 122 pt case with room
           to spare and well below every width where the single row works. */
        @media (pointer: coarse) and (max-width: 200px) {
          [class*="_inner"]:has(> [class*="_actions"]) {
            flex-direction: column !important;
            align-items: stretch !important;
            min-height: 0 !important;
          }
          [class*="_inner"]:has(> [class*="_actions"]) > * {
            min-width: 0 !important;
            max-width: 100% !important;
          }
          [class*="_actions"]:has(> [class*="_action"]) {
            flex-wrap: wrap !important;
            row-gap: 4px !important;
            width: 100% !important;
            max-width: 100% !important;
          }
          [class*="_actions"] > *[class*="_action"],
          [class*="_actions"] > *[class*="_toggle"] {
            flex: 0 1 auto !important;
            min-width: 44px !important;
          }
          input[aria-label="搜索轨迹"] {
            min-width: 0 !important;
            flex: 1 1 auto !important;
            max-width: 100% !important;
          }
          [class*="_search"]:has(> input[aria-label="搜索轨迹"]) {
            min-width: 0 !important;
            max-width: 100% !important;
            flex: 1 1 auto !important;
          }
        }

        /* ---------- 21.7b. The composer row in a column this narrow --------
           MEASURED at 120 pt (the column an expanded sidebar leaves): three boxes
           still escaped the right edge — the access-mode trigger (44 pt wide, its
           right edge at 140 in a 120 pt viewport, so 20 pt outside), its chevron and
           its icon. The row is 81 pt wide there.

           This is the SAME row the model selector lives in, and step 21's first rule
           already made its children shrinkable — but a 44 pt control with three
           glyphs inside cannot shrink below its own padding, and at 120 pt there is
           no room for both it and the send button. So at this width the row wraps:
           the tools group takes a line of its own and the trailing group takes the
           next, instead of both being squeezed onto one line that cannot hold them.

           WHY 200 px, the same threshold as 21.7: it is below every width at which
           the single-line layout works (402 pt is the phone's own width and the row
           is comfortable there), and above the 120–122 pt case that breaks. */
        @media (pointer: coarse) and (max-width: 200px) {
          [data-composer-card] [class*="_row"] {
            flex-wrap: wrap !important;
            row-gap: 4px !important;
          }
          [data-composer-card] [class*="_row"] > [class*="_tools"],
          [data-composer-card] [class*="_row"] > [class*="_trailing"] {
            flex: 1 1 100% !important;
            max-width: 100% !important;
            min-width: 0 !important;
          }
          [data-composer-card] [class*="_modes"] {
            flex: 1 1 auto !important;
            min-width: 0 !important;
            overflow: hidden !important;
          }
          [data-composer-card] [class*="_modes"] > * {
            min-width: 0 !important;
          }
        }
        `;


          const installStyle = () => {
            if (document.getElementById('dsh-mobile-polish') !== null) return;
            const style = document.createElement('style');
            style.id = 'dsh-mobile-polish';
            style.textContent = CSS;
            (document.head || document.documentElement).appendChild(style);
            state.applied.push('style');
          };
          installStyle();
          // The document's head is replaced on some boot paths — step 11 measured
          // that — so the sheet is re-asserted rather than installed once.
          try {
            const watcher = new MutationObserver(() => {
              if (document.getElementById('dsh-mobile-polish') === null) installStyle();
            });
            watcher.observe(document.documentElement, { childList: true, subtree: true });
            state.styleObserver = watcher;
          } catch (error) { /* the observer is a backstop, not a requirement */ }

          // ---------- A, in detail: the hit-area pass ----------------------
          //
          // For one control, how far may the tap region grow without touching a
          // neighbour? The answer comes from the siblings that share a parent,
          // because those are the only things that could receive the tap instead.
          // Would setting `overflow: visible` on this box be safe? Only when it
          // clips on both axes, matches the control's size to within 2 pt (the
          // "icon button wrapper" shape, measured on .bhn1Oq_headerActions and
          // .bhn1Oq_search), and does not scroll — `overflow: visible` on a
          // scroll container destroys the scrolling.
          const canFree = (node, rect) => {
            const st = getComputedStyle(node);
            const clips = st.overflowX === 'hidden' || st.overflowY === 'hidden';
            if (!clips) return false;
            if (node.scrollHeight > node.clientHeight + 1) return false;
            if (node.scrollWidth > node.clientWidth + 1) return false;
            const nr = node.getBoundingClientRect();
            return Math.abs(nr.width - rect.width) <= 2 && Math.abs(nr.height - rect.height) <= 2;
          };

          const clearance = (el, rect) => {
            let left = 12, right = 12, up = 12, down = 12;
            const parent = el.parentElement;
            if (parent === null) return { x: 0, y: 0, free: [] };
            // A snug clipping ancestor caps the growth at its own edge. Measured
            // on the rail's buttons there are TWO of them in a row
            // (.bhn1Oq_headerActions inside .bhn1Oq_sectionHeader, both 36x36 and
            // both overflow:hidden), so the chain is walked rather than the
            // immediate parent only — but only while every link is verified safe
            // by `canFree`, and the walk stops at the first box that is the real
            // container.
            const free = [];
            let bound = parent;
            let node = parent;
            let depth = 0;
            while (node !== null && depth < 3 && canFree(node, rect)) {
              free.push(node);
              bound = node.parentElement !== null ? node.parentElement : node;
              node = node.parentElement;
              depth += 1;
            }
            for (const sibling of parent.children) {
              if (sibling === el) continue;
              const s = sibling.getBoundingClientRect();
              if (s.width <= 0 || s.height <= 0) continue;
              // Vertically overlapping neighbours constrain horizontally, and the
              // other way round. A neighbour that overlaps neither axis is not in
              // the way at all.
              const overlapsY = s.bottom > rect.top && s.top < rect.bottom;
              const overlapsX = s.right > rect.left && s.left < rect.right;
              if (overlapsY && !overlapsX) {
                if (s.right <= rect.left) left = Math.min(left, rect.left - s.right);
                if (s.left >= rect.right) right = Math.min(right, s.left - rect.right);
              }
              if (overlapsX && !overlapsY) {
                if (s.bottom <= rect.top) up = Math.min(up, rect.top - s.bottom);
                if (s.top >= rect.bottom) down = Math.min(down, s.top - rect.bottom);
              }
            }
            // A container that clips is a real limit: a control at the edge of
            // one must not extend an overlay outside it, or the area gains a
            // phantom touch target that belongs to something else. When the snug
            // parent is being freed, the bound becomes the box around it.
            const bs = getComputedStyle(bound);
            const br = bound.getBoundingClientRect();
            if (bs.overflowX !== 'visible' || free.length > 0) {
              left = Math.min(left, Math.max(0, rect.left - br.left));
              right = Math.min(right, Math.max(0, br.right - rect.right));
            }
            if (bs.overflowY !== 'visible' || free.length > 0) {
              up = Math.min(up, Math.max(0, rect.top - br.top));
              down = Math.min(down, Math.max(0, br.bottom - rect.bottom));
            }
            const growX = Math.max(0, Math.min(left, right) * 2);
            const growY = Math.max(0, Math.min(up, down) * 2);
            return { x: Math.min(growX, 16), y: Math.min(growY, 16), free: free };
          };

          // The control sets worth enlarging. Deliberately narrow: an overlay on
          // every clickable div in this UI would be a bigger change than the
          // problem it fixes, and the elements that matter are these.
          const CANDIDATES = [
            'button',
            '[role="button"]',
            '[role="tab"]',
            '[role="switch"]',
            '[data-row-key] button',
            '[data-dockkit-tab] button',
            '[data-composer-dock] button',
          ].join(',');

          const enlargeOne = (el) => {
            // The left-edge strip is `position: fixed` and its height comes from
            // top + bottom. The `position: relative` below would collapse it to its
            // 44 pt handle, and an overlay would reach over the transcript.
            if (el.hasAttribute('data-dsh-rail-edge')) return false;
            const rect = el.getBoundingClientRect();
            if (rect.width < 2 || rect.height < 2) return false;
            if (rect.width >= 44 && rect.height >= 44) return false;
            const own = getComputedStyle(el, '::after');
            // DSH paints several icon buttons' hover background on ::after. Taking
            // that pseudo-element would delete the affordance, so those are left
            // alone rather than silently broken.
            if (own.content !== 'none' && own.content !== 'normal' && own.content !== '""') return false;
            const room = clearance(el, rect);
            if (room.x <= 0 && room.y <= 0) return false;
            el.setAttribute('data-dsh-hit', '');
            el.style.setProperty('--dsh-hit-x', room.x + 'px');
            el.style.setProperty('--dsh-hit-y', room.y + 'px');
            // The snug clipping wrapper, if there was one, is what was capping
            // the growth to zero; `clearance` already decided it is safe to free.
            for (const host of room.free) host.setAttribute('data-dsh-hit-host', '');
            return true;
          };

          state.pass = () => {
            let enlarged = 0, considered = 0;
            for (const el of document.querySelectorAll(CANDIDATES)) {
              considered += 1;
              try { if (enlargeOne(el)) enlarged += 1; } catch (error) { /* one element must not stop the pass */ }
            }
            state.lastPass = { considered: considered, enlarged: enlarged, at: Date.now() };
            return state.lastPass;
          };
          state.pass();
          // React re-renders replace nodes; a pass per idle moment keeps the
          // overlay on whatever is on screen, and is cheap enough to be harmless.
          try {
            const passWatcher = new MutationObserver(() => {
              if (state.passPending === true) return;
              state.passPending = true;
              requestAnimationFrame(() => { state.passPending = false; state.pass(); });
            });
            passWatcher.observe(document.body !== null ? document.body : document.documentElement,
              { childList: true, subtree: true });
            state.passObserver = passWatcher;
          } catch (error) { /* ditto */ }

          // ---------- STEP 21.6: a press on a row's ACTION is not a press on
          // the row ----------------------------------------------------
          //
          // WHAT WAS BROKEN, and it is a step-15 defect that step 18's tests could
          // not see. `MobileWebTuning` closes the drawer when a session row is
          // pressed, so the conversation does not open underneath the overlay:
          //
          //     document.addEventListener('click', (event) => {        // capture
          //       const row = event.target.closest('[data-row-key]');
          //       if (row === null) return;
          //       if ((row.getAttribute('data-row-key')||'').indexOf('session:') !== 0) return;
          //       setTimeout(() => { railToggle(); setDrawer(false); }, 0);
          //     }, true);
          //
          // `closest()` walks UP from whatever was pressed, and every control
          // INSIDE the row is a descendant of it — so the row's own 归档会话,
          // 置顶会话 and 会话“…”的操作 buttons were all treated as "the row was
          // pressed". Pressing any of them closed the drawer and toggled the
          // sidebar instead of doing its job. Measured on the iPhone simulator:
          // tapping the ellipsis at (187,328) left `data-dsh-rail-open` absent and
          // the session menu never opened, so RENAME and DELETE were unreachable on
          // a phone — exactly the gap REPORT-18 recorded as "置顶、重命名、删除仅
          // 显露控件，未完整操作验收".
          //
          // Archive and pin looked like they worked in step 18 because they act
          // immediately and the drawer closing afterwards read as the expected
          // result. Rename and delete open a MENU, and the menu needs the drawer to
          // still be there when it does.
          //
          // HOW IT IS FIXED, and why not the two obvious ways. Step 15's listener is
          // registered in the CAPTURE phase on `document`, so a second listener here
          // runs after it whatever phase it uses — measured, `rowActionPresses`
          // reached 1 and the drawer still closed. Marking the row and reading the
          // mark inside our own listener has the same problem: the decision has
          // already been queued by then.
          //
          // What is left is the truth about that listener: it does its damage in a
          // `setTimeout(..., 0)`, one task after the click. So this file records
          // that the press was a ROW ACTION at `touchstart` (which is earlier than
          // any click, in any phase), and re-opens the drawer on the task after the
          // one step 15 scheduled — unless the press really did open a conversation,
          // which is the case the drawer is supposed to close for.
          //
          // The distinction is exact: a press that navigates makes the current
          // session change, so the session the page reports is not the one it
          // reported before. A press on the row's own control does not.
          // ---------- STEP 21.6: what a press on a row's ACTION does ----------
          //
          // ROOT CAUSE, measured, and it is NOT fixed by this file.
          //
          // `MobileWebTuning` closes the drawer when a session row is pressed, so
          // the conversation does not open underneath the overlay:
          //
          //     document.addEventListener('click', (event) => {        // capture
          //       const row = event.target.closest('[data-row-key]');
          //       if (row === null) return;
          //       if ((row.getAttribute('data-row-key')||'').indexOf('session:') !== 0) return;
          //       setTimeout(() => { if (railExpanded()) railToggle(); setDrawer(false); }, 0);
          //     }, true);
          //
          // `closest()` walks UP from whatever was pressed, and every control inside
          // the row is a descendant of it — so the row's own 归档会话, 置顶会话 and
          // 会话“…”的操作 buttons are all treated as "the row was pressed". Measured
          // event sequence for a real press on the ellipsis, with an observer on
          // both phases:
          //
          //     capture  BUTTON 会话“…”的操作    drawer: true
          //     capture  BUTTON 收起侧边栏        drawer: true    <- the guard's own
          //     bubble                            drawer: true       railToggle()
          //
          // So a press on a row control collapses the sidebar. ARCHIVE and PIN still
          // land — they act synchronously on their own click, which arrives before
          // the guard's deferred toggle — and step 18 saw that and read the drawer
          // closing afterwards as the expected result. RENAME and DELETE open a MENU,
          // and the menu is dismissed by the same deferred toggle, so they are
          // unreachable on a phone. That is the gap REPORT-18 recorded as "置顶、
          // 重命名、删除仅显露控件，未完整操作验收", with its cause now identified.
          //
          // FOUR FIXES WERE TRIED HERE, each measured on the simulator, each failed:
          //
          //   1. a second capture-phase click listener that `stopPropagation`s —
          //      step 15's listener is itself capture-phase on `document`, so anything
          //      this file registers on `document` runs AFTER it;
          //   2. re-opening the drawer a task later — the guard had already toggled
          //      the sidebar, so the menu never opened and there was nothing to keep
          //      (`restores: 0`, `menus: 0`);
          //   3. removing the row's `data-row-key` at `touchstart` — works for a
          //      SYNTHESISED click and not for a real one: WebKit composes the click
          //      after `touchend`, and the guard read a row React had re-rendered
          //      with the attribute back;
          //   4. shielding `data-sidebar-collapsed` on the frame so the guard's
          //      `railExpanded()` returns false — the shield worked and was restored
          //      (`restores: 1`), but the guard calls `setDrawer(false)` UNCONDITION-
          //      ALLY one task later, so the drawer closed anyway.
          //
          // The fifth option is the one that would work and it is out of this file's
          // reach: the guard has to skip a press that landed on a descendant control,
          // and that guard lives in `MobileWebTuning.swift`, which step 15 owns and
          // this step must not edit. It is written up in REPORT-21.md as the one item
          // this task could not finish from inside the injection layer, with the
          // three-line change it needs.
          //
          // What IS kept here is the measurement, so the condition is not invisible
          // the next time somebody looks: a press on a row control is counted.
          state.rowActionPresses = 0;
          document.addEventListener('touchstart', (event) => {
            const target = event.target;
            if (!(target instanceof Element)) return;
            const row = target.closest('[data-row-key]');
            if (row === null) return;
            if (((row.getAttribute('data-row-key') || '')).indexOf('session:') !== 0) return;
            if (target.closest('button, [role="button"], [data-dsh-hit]') === null) return;
            state.rowActionPresses += 1;
          }, { capture: true, passive: true });

          // ---------- STEP 21.3: no keyboard chords on a phone -------------
          //
          // The string is DSH's `placeholder.steerQueue` — "Cmd/Ctrl+Enter
          // 插话发送全部排队消息" — and it is what the composer shows while a turn
          // runs and something is queued. On a phone there is no Cmd and no Ctrl,
          // so the sentence tells the user to press a key that does not exist.
          //
          // WHAT IT BECOMES: the same sentence without the chord, because the
          // action it describes IS reachable by tapping "停止生成"'s neighbour —
          // the queue row's own 插话发送 button, which step 15 measured and which
          // is still there. So the string is replaced rather than removed: an
          // empty placeholder would leave the user with no idea what the draft
          // will do.
          //
          // WHERE IT IS APPLIED: the placeholder element's text, the draft's
          // `data-placeholder` attribute, and the `--dsh-composer-hint` custom
          // property that paints the same sentence into the draft's `::after`.
          // All three are the page's own outputs for one string, and a phone only
          // needs them not to name a chord.
          //
          // A HARDWARE KEYBOARD EXEMPTS THE PAGE. `state.hardwareKeyboard` is
          // already measured for the focus guard below (a hardware keyboard does
          // not shrink the web view); the same flag is reused here, so an iPad
          // with a keyboard keeps the original sentence and its working chord.
          const CHORD_PATTERNS = [
            // The exact string DSH ships, and its English form.
            [/^\\s*Cmd\\/Ctrl\\+Enter\\s*/i, ''],
            [/^\\s*(?:Cmd|Ctrl|⌘|⌃)\\s*(?:\\/\\s*(?:Cmd|Ctrl)\\s*)?\\+\\s*Enter\\s*/i, ''],
          ];
          state.chordRewrites = 0;
          const stripChord = (text) => {
            if (typeof text !== 'string' || text === '') return text;
            if (state.hardwareKeyboard === true) return text;
            for (const [pattern, replacement] of CHORD_PATTERNS) {
              if (pattern.test(text)) {
                state.chordRewrites += 1;
                return text.replace(pattern, replacement).trim();
              }
            }
            return text;
          };
          const rewriteChord = () => {
            if (state.hardwareKeyboard === true) return;
            const draft = document.querySelector('[data-composer-input]');
            if (draft !== null) {
              const placeholder = draft.getAttribute('data-placeholder');
              if (placeholder !== null) {
                const next = stripChord(placeholder);
                if (next !== placeholder) draft.setAttribute('data-placeholder', next);
              }
              // The painted hint: `--dsh-composer-hint` is a CSS string token,
              // so it is JSON-encoded by the page and has to stay that way.
              const hint = draft.style.getPropertyValue('--dsh-composer-hint');
              if (hint !== '') {
                let decoded = hint;
                try { decoded = JSON.parse(hint); } catch (error) { decoded = hint.replace(/^"|"$/g, ''); }
                const next = stripChord(decoded);
                if (next !== decoded) draft.style.setProperty('--dsh-composer-hint', JSON.stringify(next));
              }
            }
            for (const node of document.querySelectorAll('[data-composer-placeholder]')) {
              const current = node.textContent || '';
              const next = stripChord(current);
              if (next !== current) node.textContent = next;
            }
          };
          // The placeholder is re-rendered on every phase change (idle → running
          // → queued), so a one-shot pass would miss the state the string is for.
          state.chordTick = () => { try { rewriteChord(); } catch (error) { /* never fatal */ } };
          try {
            const chordWatcher = new MutationObserver(() => {
              // A drawer drag writes `style` every move and touches no placeholder.
              // Ending it writes `style` once more, which brings this back.
              if (document.documentElement.hasAttribute('data-dsh-rail-dragging')) return;
              if (state.chordPending === true) return;
              state.chordPending = true;
              requestAnimationFrame(() => { state.chordPending = false; state.chordTick(); });
            });
            chordWatcher.observe(document.documentElement, {
              childList: true, subtree: true, characterData: true,
              attributes: true, attributeFilter: ['data-placeholder', 'style', 'data-phase', 'data-composer-composing'],
            });
            state.chordObserver = chordWatcher;
          } catch (error) { /* the observer is a backstop */ }
          state.chordTick();

          // ---------- STEP 21.4: the newline button ------------------------
          //
          // REPORT-15's conclusion, unchanged: Return SENDS on this composer and
          // must keep sending (`return` is what the phone's keyboard offers, and
          // step 15 proved an IME's candidate-selection Return does not fire it).
          // The phone therefore needs a way to insert a line break that is not a
          // key. This is that control, and it does exactly what a Shift+Return
          // does in this editor: `insertLineBreak` on the focused draft.
          //
          // It is injected rather than added to DSH's own toolbar for the reason
          // this whole file exists: `payload/` is not ours to change.
          //
          // The button only exists while the draft does — the composer is what it
          // acts on, and it has no meaning on the hero screen of a workspace
          // picker.
          const NEWLINE_ID = 'dsh-mobile-newline';
          state.newlineInserts = 0;
          const installNewline = () => {
            const row = document.querySelector('[data-composer-card] [class*="_row"]');
            if (row === null) return;
            const tools = row.querySelector('[class*="_tools"]');
            if (tools === null) return;
            const add = tools.querySelector('button[aria-label="添加文件或调用指令"]');
            if (add === null) return;
            if (tools.querySelector('#' + NEWLINE_ID) !== null) return;
            const button = document.createElement('button');
            button.id = NEWLINE_ID;
            button.type = 'button';
            button.setAttribute('data-dsh-newline', '');
            button.setAttribute('aria-label', '换行');
            button.setAttribute('title', '换行');
            button.innerHTML = '<svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">'
              + '<path d="M3 3v6a3 3 0 0 0 3 3h7" stroke="currentColor" stroke-width="1.4" '
              + 'stroke-linecap="round" stroke-linejoin="round"/>'
              + '<path d="M10.5 9.5 13 12l-2.5 2.5" stroke="currentColor" stroke-width="1.4" '
              + 'stroke-linecap="round" stroke-linejoin="round"/></svg>';
            // The draft has to be focused for the browser's own insert command to
            // have a target, and focusing it here is not the bug the focus guard
            // above exists for: that guard is about a press on the TOOLBAR raising
            // the keyboard, and this control is a deliberate press on the
            // composer.
            button.addEventListener('click', (event) => {
              event.preventDefault();
              event.stopPropagation();
              const draft = document.querySelector('[data-composer-input]');
              if (draft === null) return;
              if (document.activeElement !== draft) draft.focus();
              // The same operation the platform performs for Shift+Return.
              document.execCommand('insertLineBreak');
              state.newlineInserts += 1;
            });
            // Placed AFTER the `+` button: the strip's order is add / modes, and
            // a break is an editing action rather than a mode.
            add.insertAdjacentElement('afterend', button);
          };
          state.installNewline = installNewline;
          installNewline();
          try {
            const newlineWatcher = new MutationObserver(() => {
              if (state.newlinePending === true) return;
              state.newlinePending = true;
              requestAnimationFrame(() => { state.newlinePending = false; installNewline(); });
            });
            newlineWatcher.observe(document.body !== null ? document.body : document.documentElement,
              { childList: true, subtree: true });
            state.newlineObserver = newlineWatcher;
          } catch (error) { /* the observer is a backstop */ }

          // ---------- STEP 21.6b: bring a focused field into view ------------
          //
          // A scroll container does not move by itself when a field inside it is
          // focused while the keyboard is animating in from below: the scroll
          // happens, or does not, before the viewport has shrunk, and the field
          // ends up under the keyboard. Measured before this: the API field's top
          // at y 741 with the keyboard starting at 590.
          //
          // So a focus inside a dialog is followed by one scroll, twice over two
          // frames — the sidebar/scroll containers exist by then and the visual
          // viewport has its final height.
          state.focusScrolls = 0;
          document.addEventListener('focusin', (event) => {
            const target = event.target;
            if (!(target instanceof Element)) return;
            if (target.closest('[role="dialog"]') === null) return;
            const reveal = () => {
              try {
                target.scrollIntoView({ block: 'center', inline: 'nearest' });
                state.focusScrolls += 1;
              } catch (error) { /* a non-Element target cannot happen here */ }
            };
            reveal();
            requestAnimationFrame(reveal);
            setTimeout(reveal, 260);
            setTimeout(reveal, 520);
          }, true);

          // Navigator the boot paths use to reach the page from the probe.
          state.report = () => ({
            pass: state.lastPass,
            styled: document.getElementById('dsh-mobile-polish') !== null,
            painted: state.applied,
            chordRewrites: state.chordRewrites,
            hardwareKeyboard: state.hardwareKeyboard === true,
            newlineInserts: state.newlineInserts,
            newlineInstalled: document.getElementById(NEWLINE_ID) !== null,
          });
        })();
        """
    }

    /// Configure the web view for the polish layer. Called once, at creation.
    static func configure(_ webView: WKWebView) {
        guard !isDisabled else { return }
        // Drag-to-dismiss for the keyboard. WebKit's default is `none`, and this
        // page's only other ways to dismiss are a tap on the conversation or (a
        // step 11 decision) nothing at all — the form assistant's Done button is
        // removed because it duplicated the tap. `.interactive` gives the gesture
        // every iOS app has: pull the transcript down and the keyboard follows
        // the finger. It changes nothing about the page's layout.
        webView.scrollView.keyboardDismissMode = .interactive
    }
}
