---
name: Attend
description: Safeguarding-grade event onboarding for under-18 Hack Club events — flat, bordered, and quiet until it needs to speak.
colors:
  accent: "#ec3750"
  accent-strong: "#d42f46"
  accent-deep: "#b82840"
  accent-soft: "rgba(236, 55, 80, 0.10)"
  accent-on: "#ffffff"
  bg-app: "#f9fafc"
  bg-elev: "#ffffff"
  bg-elev-2: "#f7f7f9"
  bg-elev-3: "#f3f4f6"
  bg-sunken: "#e6e6ea"
  bg-dark: "#17171d"
  bg-darker: "#1f2d3d"
  text-strong: "#1f2d3d"
  text: "#3c4858"
  text-soft: "#5a6473"
  text-muted: "#8492a6"
  text-faint: "#9ca3af"
  text-link: "#2563eb"
  border-soft: "#f3f4f6"
  border: "#e5e7eb"
  border-strong: "#d1d5db"
  border-card: "#e0e6ed"
  success: "#33d6a6"
  success-strong: "#2ab890"
  warning: "#ff8c37"
  warning-strong: "#f97316"
  danger: "#ec3750"
  info: "#338eda"
typography:
  display:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "1.875rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.01em"
  headline:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "1.5rem"
    fontWeight: 700
    lineHeight: 1.25
  title:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "1.125rem"
    fontWeight: 600
    lineHeight: 1.4
  body:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: 1.5
  label:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "0.75rem"
    fontWeight: 600
    lineHeight: 1.4
  eyebrow:
    fontFamily: "ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif"
    fontSize: "0.6875rem"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "0.05em"
rounded:
  sm: "4px"
  md: "6px"
  lg: "8px"
  xl: "12px"
  full: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
  "2xl": "32px"
components:
  button-primary:
    backgroundColor: "{colors.accent-strong}"
    textColor: "{colors.accent-on}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
  button-primary-hover:
    backgroundColor: "{colors.accent-deep}"
    textColor: "{colors.accent-on}"
  button-secondary:
    backgroundColor: "{colors.bg-elev}"
    textColor: "{colors.text}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "8px 16px"
  button-secondary-hover:
    backgroundColor: "{colors.bg-elev-3}"
    textColor: "{colors.text-strong}"
  button-hc-pill:
    backgroundColor: "{colors.accent-strong}"
    textColor: "{colors.accent-on}"
    typography: "{typography.title}"
    rounded: "{rounded.full}"
    padding: "12px 24px"
  input-field:
    backgroundColor: "{colors.bg-elev}"
    textColor: "{colors.text-strong}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "8px 12px"
  card:
    backgroundColor: "{colors.bg-elev}"
    textColor: "{colors.text}"
    rounded: "{rounded.lg}"
    padding: "24px"
  badge-status:
    backgroundColor: "{colors.bg-elev-3}"
    textColor: "{colors.text-strong}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: "2px 10px"
  nav-item:
    backgroundColor: "transparent"
    textColor: "{colors.text}"
    rounded: "{rounded.md}"
    padding: "6px 10px"
    height: "28px"
  nav-item-active:
    backgroundColor: "{colors.bg-sunken}"
    textColor: "{colors.text-strong}"
    rounded: "{rounded.md}"
    padding: "6px 10px"
---

# Design System: Attend

## Overview

**Creative North Star: "The Clipboard"**

Attend is the binder a good event organiser carries: tabbed, legible at arm's length, nothing on it that isn't doing a job. Every surface is a checklist in some form — an onboarding step, a consent form, a participant row, a rooming plan — and the interface's whole job is to make the state of that checklist unmistakable. Structure comes from hairline rules and tonal surfaces, not from decoration. The page is mostly quiet greys and whites; Hack Club red appears where something is actionable or wrong, and nowhere else.

The density is deliberately administrative. Body copy runs at 14px and labels at 12px because most screens carry more information than they carry prose, and the people reading them are scanning for one changed value. Type does the hierarchy work — five weights of grey across a small size range — so the layout never needs a colour to explain itself. Components are tactile where touching them matters: buttons deepen on hover, interactive cards lift and scale slightly, and the Hack Club pill button keeps its bouncy `scale(1.0625)` because a teenager pressing "Continue" on their onboarding should feel it respond.

The system carries eight themes on one semantic palette. Every colour resolves through a CSS custom property (`--accent`, `--text-strong`, `--bg-elev`), and Tailwind's own `--color-*` tokens are remapped inside each theme scope so ordinary utilities re-skin for free. That indirection is the system's spine: a hardcoded hex is not a shortcut, it's a theme that breaks.

Two things Attend must not look like. Not a **generic Tailwind starter** — undifferentiated `blue-600` buttons, indigo gradients, default `shadow-lg` cards, the look of no decision having been made. And not a **consumer event app** — gradients, hero imagery, and marketing energy inside a tool people use to do a job.

**Key Characteristics:**
- Flat surfaces, hairline borders, tonal layering instead of shadows
- One loud colour (Hack Club red) held to actions, alerts, and active state
- Dense administrative type scale: 14px body, 12px labels, weight over size for hierarchy
- Every colour semantic and themed; eight themes on one palette contract
- Mobile-first single column that widens into a 256px-sidebar shell on `lg`
- Motion is confined to `transition-colors` at ~150ms, plus a small lift on genuinely interactive cards

## Colors

A near-neutral system — cool greys and near-blacks carrying almost every pixel — with a single saturated Hack Club red that earns its rarity, and a small semantic set for state.

### Primary
- **Hack Club Red** (`{colors.accent}`): the one loud voice, and the brand's own value. Active navigation tint, unread dots, the Turbo progress bar, left-border accents on alert rows, icon fills, and any red that carries no text on it. Never used as a decorative fill or a background for a large region.
- **Deepened Red** (`{colors.accent-strong}`): the resting fill of every button, badge, or surface that carries white text — see **The Deepened Red Rule**. Visually indistinguishable from the brand red at a glance; measurably different to a contrast checker.
- **Pressed Red** (`{colors.accent-deep}`): the hover and pressed state under Deepened Red.
- **Red Wash** (`{colors.accent-soft}`): a 10% tint used for the active-tab background in the participant header and for soft alert panels. It is the only way red is allowed to occupy area.

### Secondary
No second accent. Blue appears in the codebase (`bg-blue-600` buttons, `ring-blue-500` focus rings across the onboarding wizard and guardian portal) but it is **drift, not design** — see Do's and Don'ts.

### Neutral
- **Paper** (`{colors.bg-app}`): the app canvas behind everything. Never used for a card.
- **Card White** (`{colors.bg-elev}`): the surface every card, panel, dropdown, and input sits on. The single most common background in the system.
- **Rest Grey** (`{colors.bg-elev-2}`): sunken panels, the admin sidebar column, secondary-button hover.
- **Press Grey** (`{colors.bg-elev-3}`): hover fills on icon buttons and dropdown items.
- **Sunken Grey** (`{colors.bg-sunken}`): the active navigation item's background — the deepest neutral before you're into ink.
- **Ink** (`{colors.text-strong}`): headings, active nav labels, primary values in a table. The darkest text.
- **Slate** (`{colors.text}`): body copy default.
- **Soft Slate** (`{colors.text-soft}`) and **Muted Steel** (`{colors.text-muted}`): secondary values, helper text, timestamps.
- **Faint** (`{colors.text-faint}`): placeholders and disabled labels only. Not a text colour for anything a user must read.
- **Hairline** (`{colors.border}`) / **Card Hairline** (`{colors.border-card}`) / **Strong Hairline** (`{colors.border-strong}`): the borders that do the structural work shadows would otherwise do.

### Tertiary
State colours, used as badge tints and status dots, never as brand:
- **Mint** (`{colors.success}`) — complete, checked in, confirmed.
- **Amber** (`{colors.warning}`) — awaiting the guardian, pending action, impersonation banner.
- **Sky** (`{colors.info}`) — informational, awaiting participant.

### Named Rules

**The One Voice Rule.** Hack Club red covers ≤10% of any screen. If two things on a page are red, at most one of them is a button. Its rarity is what makes a red thing mean "act on me".

**The No Literal Hex Rule.** Every colour resolves through a semantic custom property or a Tailwind token remapped in `themes.css`. A raw hex in a template is a theme bug: it renders correctly in light and wrong in the other seven. New work uses `var(--accent)`, not `#ec3750`.

**The Deepened Red Rule.** `{colors.accent}` on white measures **4.02:1** — below WCAG AA's 4.5:1 for normal text. WCAG's large-text exemption (3:1) starts at 18.66px bold or 24px regular, which no button in Attend reaches, so the type cannot buy its way out. The colour moves instead: **wherever white text sits on red, the fill is `{colors.accent-strong}` (4.89:1)**, hovering to `{colors.accent-deep}`. `{colors.accent}` keeps every use that carries no text on it — dots, bars, icon fills, borders, tints, and the progress bar. The two reds are one perceptual step apart; nobody sees the difference, and every white label clears AA.

## Typography

**Display Font:** the system UI stack (`ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto`) — Tailwind's default, adopted deliberately. There is no webfont; a guardian on a slow connection gets text on first paint.
**Body Font:** the same stack. One family, differentiated entirely by weight and size.
**Label/Mono Font:** none distinct. `<kbd>` in the search trigger is the only monospace-adjacent treatment and it uses the same stack at 11px.

**Character:** neutral, native, and unbranded on purpose. The type carries no personality of its own so the density can be high without becoming tiring, and so an eleven-line participant record reads as data rather than as design.

### Hierarchy
- **Display** (700, 1.875rem / `text-3xl`, 1.2): page titles on the few marketing-adjacent surfaces — home, public profiles, docs. Rare (30 uses).
- **Headline** (700, 1.5rem / `text-2xl`, 1.25): the title of a screen or a major panel. The normal top of a page inside the app.
- **Title** (600, 1.125rem / `text-lg`, 1.4): card headings, section headings within a form step, and the required size for text on a red fill.
- **Body** (500, 0.875rem / `text-sm`, 1.5): the workhorse — by a factor of three the most common size in the codebase. Form labels, table cells, button text, nav items. `font-medium` is the default weight, not `font-normal`; the small size needs the extra stem.
- **Label** (600, 0.75rem / `text-xs`, 1.4): status badges, helper text, metadata, timestamps.
- **Eyebrow** (600, 0.6875rem, uppercase, 0.05em): sidebar section headers only.

### Named Rules

**The Weight-Before-Size Rule.** Hierarchy is built by moving 500 → 600 → 700 at the same size before reaching for a larger size. Attend has more levels of meaning than it has room for type sizes.

**The Fourteen Rule.** Body copy is 14px, not 16px, everywhere inside the app shell — including on red fills, which is why **The Deepened Red Rule** moves the colour rather than the type. The one exception is long-form prose on the docs and public-profile surfaces, which may run at 16px with a 65–75ch measure.

## Layout

A single mobile-first column that becomes a shell at the large breakpoint. Participant and guardian surfaces use `container mx-auto px-4 sm:px-6 lg:px-8 py-8` with a content cap between `max-w-2xl` and `max-w-4xl` — forms stay narrow enough to read in one eye-line. Admin surfaces use a fixed **256px** (`w-64`) left sidebar that appears at `lg` and collapses to an overlay drawer below it, with content filling the remainder unconstrained; tables need the width.

The breakpoint weighting tells the truth about the audience: `sm:` outnumbers `md:` more than three to one and `xl:` is essentially unused. Design for a phone, then for a laptop; there is no third case.

Spacing runs on a 4px base with 8/12/16/24 doing nearly all the work. Card interiors are 24px (`p-6`) on desktop and 16px on mobile; stacked form fields sit 16px apart; related controls sit 8px apart. Buttons are `py-2 px-4` at rest.

**The Full-Width-Then-Auto Rule.** Every primary action is `w-full sm:w-auto`. On a phone a button is a full-width target; on a desktop it shrinks to its content. This pattern appears on essentially every form in the app and is not optional on guardian or participant surfaces.

## Elevation & Depth

Attend is **flat by default, and borders do the work.** Depth is expressed as a tonal stack — `--bg-app` behind `--bg-elev` behind `--bg-elev-2`/`--bg-elev-3` — plus a 1px hairline. This is why `border-gray-300` appears 651 times and `shadow-sm` only 34: the border is the structure, not a shadow.

Shadows are reserved for things that genuinely float above the document and need to break the plane.

### Shadow Vocabulary
- **Hairline lift** (`box-shadow: var(--shadow-sm)` → `0 1px 2px rgba(0,0,0,0.06)`): sticky headers and the app bar, where a border alone would disappear against a scrolling surface.
- **Overlay** (`box-shadow: var(--shadow-lg)` → `0 8px 24px rgba(15,23,42,0.10)`): dropdowns, the command palette, modals, mobile drawers.
- **Card lift** (`box-shadow: var(--hc-shadow-card)` → `0 4px 8px rgba(0,0,0,0.125)`): the legacy Hack Club card and pill button only, where it is part of the brand component rather than the layout system.

Dark themes scale the same three roles up in opacity (0.4 / 0.5 / 0.6) because a shadow that reads on white vanishes on `#0f1115`.

### Named Rules

**The Flat-By-Default Rule.** A surface is flat at rest. If you reach for a shadow, first ask whether the element actually floats. If it doesn't, it gets a border and a tonal step instead.

## Shapes

Two radii carry the system: **6px** (`rounded-md`, 702 uses) for anything interactive and rectangular — buttons, inputs, nav items, icon buttons — and **8px** (`rounded-lg`, 569 uses) for containers and cards. 12px (`rounded-xl`) appears only on floating overlays; 16px+ is essentially absent and should stay that way.

**Full-round** (`rounded-full`, 296 uses) is the system's one piece of personality and it is strictly typed: status badges, avatars, count bubbles, sidebar selector pills, and the Hack Club pill button. A pill in Attend means "this is a piece of state or an identity", never "this is a generic button".

Borders are always 1px, always a hairline neutral, never coloured except to signal state — a red left border on an alert row, an amber dashed border on the admin escape hatch in the participant header. The dashed border is meaningful: it marks a control that isn't part of the normal user's world.

**The Two-Radius Rule.** 6px for controls, 8px for containers, full for state and identity. A third value needs a reason.

## Components

Components are **tactile and confident**: they respond when touched, and the response is proportional to how much the action matters.

### Buttons
- **Shape:** softly rounded (6px / `rounded-md`); the Hack Club variant is a full pill (9999px).
- **Primary:** `{colors.accent-strong}` fill per **The Deepened Red Rule**, white text at 14px/500–600, `py-2 px-4`, `w-full sm:w-auto`.
- **Hover / Focus:** fill deepens to `{colors.accent-deep}` over `transition-colors` (~150ms). Focus shows a 2px ring in `{colors.accent}` at 30% — never `ring-blue-500`.
- **Secondary:** white fill, `{colors.text}` label, 1px hairline border, hover fills to `{colors.bg-elev-3}`. Used for "Back", "Cancel", and any second action in a pair.
- **Hack Club pill:** `{colors.accent-strong}` fill, 700 weight, full radius, card shadow, and a `scale(1.0625)` lift on hover over 125ms. Reserved for the single most important call to action on marketing and first-run surfaces. It is the only component allowed to scale.
- **Every button carries `cursor-pointer`** — Tailwind v4 no longer sets it on `<button>`, and a `<button>` that doesn't change the cursor reads as broken.

### Cards / Containers
- **Corner Style:** 8px (`rounded-lg`).
- **Background:** `{colors.bg-elev}` on the `{colors.bg-app}` canvas.
- **Shadow Strategy:** none at rest — see **The Flat-By-Default Rule**.
- **Border:** 1px `{colors.border-card}`.
- **Internal Padding:** 24px desktop, 16px mobile.
- **Interactive variant:** when a whole card is a link, it lifts and scales on hover (`scale(1.0625)`, `--hc-shadow-elevated`). Only cards that navigate somewhere get this.

### Inputs / Fields
- **Style:** white fill, 1px hairline border, 6px radius, `px-3 py-2`, 14px/500 text.
- **Focus:** outline removed, replaced by a 2px ring in `{colors.accent}` at 30% opacity plus a border shift to `{colors.accent}`. The ring is the only focus indicator, so it must never be suppressed.
- **Placeholder:** `{colors.text-faint}` — placeholder text is decoration, never the label.
- **Error:** red border and a 12px `{colors.danger}` message below the field, not a tooltip.
- **Theming caveat:** `themes.css` sets `background-color` and `color` on bare `input, select, textarea` under every non-light theme. That rule beats Tailwind's utilities on specificity ties; new input styling must be verified in a dark theme, not only in light.

### Status Badges
Attend's most-repeated pattern and the closest thing it has to a signature. A full-round pill, 12px/600, `px-2.5 py-0.5`, tinted background with same-hue dark text: green for Complete, sky for Awaiting Participant, amber for Awaiting Parent, red for Withdrawn and Rejected, grey as the fallback. The tint carries the meaning at a glance and the word carries it precisely — **never the tint alone**, since colour is not an accessible signal on its own.

### Navigation
- **Participant header:** 64px tall, white, hairline bottom border. Links are 14px/500 in `{colors.text}`, 6px radius, and the active item takes an `{colors.accent-soft}` background with `{colors.accent}` text. Collapses to a hamburger below `md`.
- **Admin sidebar:** 256px, `{colors.bg-elev-2}`, items at 13px/500 with a 20px icon in `{colors.text-muted}`; hover is a 4% black wash, active is `{colors.bg-sunken}` with `{colors.text-strong}` at 600 and the icon darkening to match. Section headers are uppercase 11px eyebrows. Sidebar selector pills (user, event) are full-round with a hairline border that darkens on hover.

### Search Trigger
A Stripe-style faux input in the admin header: 240px minimum, `{colors.bg-elev-2}` fill, hairline border, 8px radius, muted placeholder text, and a `<kbd>` shortcut hint pushed to the right edge. It looks like an input and behaves like a button that opens the command palette.

## Do's and Don'ts

### Do:
- **Do** resolve every colour through a semantic custom property (`var(--accent)`, `var(--text-strong)`) or a Tailwind token that `themes.css` remaps. There are eight themes; a literal hex serves one.
- **Do** fill any red surface that carries white text with `{colors.accent-strong}`, not `{colors.accent}`. **The Deepened Red Rule** is an accessibility floor, not a preference, and no type size in Attend is large enough to opt out of it.
- **Do** make every primary action `w-full sm:w-auto`. Guardians and participants are on phones.
- **Do** build depth from tonal surfaces and 1px hairlines. Reach for a shadow only when the element genuinely floats.
- **Do** pair every status colour with its word. A green pill without "Complete" in it is a colour-only signal.
- **Do** verify new UI in a dark theme as well as light — `themes.css` overrides bare `input`, `select`, and `textarea` elements, and remaps `--color-white` away from white.
- **Do** rebuild Tailwind before judging any visual change; the compiled CSS is the thing the browser sees.
- **Do** add `cursor-pointer` to every button and clickable element.

### Don't:
- **Don't** add new `bg-blue-600` buttons or `ring-blue-500` focus rings. The blue running through the onboarding wizard and guardian portal (35 blue fills, 277 blue rings) is **drift from a Tailwind default, not a decision**. Red is the accent everywhere; converge on it when touching those files.
- **Don't** let Hack Club red occupy area. It fills buttons, badges, and 1px borders. Large red panels, red page headers, and red backgrounds behind body copy are out — use `{colors.accent-soft}` if a red-tinted region is genuinely needed.
- **Don't** ship gradients, hero imagery, or marketing motion inside the app shell. Attend is a tool someone uses to do a job, not a consumer event app.
- **Don't** introduce a webfont. The system stack is a deliberate performance choice for guardians on slow connections and old phones.
- **Don't** add a third container radius. 6px controls, 8px containers, full for state and identity.
- **Don't** use `rounded-full` on a plain action button. A pill in Attend means state or identity; the Hack Club brand pill is the one sanctioned exception.
- **Don't** suppress the focus ring. `focus:outline-none` is only acceptable when a `focus:ring-2` replaces it in the same class list.
- **Don't** use `{colors.text-faint}` for anything a user has to read. It is for placeholders and disabled states only.
