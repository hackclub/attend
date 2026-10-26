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

> **Two worlds, one file.** Attend ships two visual systems, split by surface:
>
> - **The Clipboard** (everything in this file above the *Admin Console* section, and the YAML frontmatter): participant, guardian, onboarding, public-profile, docs and support surfaces. Unchanged, and still authoritative for them.
> - **The Cloud Console** (the *Admin Console (/admin)* section at the end, and `extensions.console` in `.impeccable/design.json`): the staff admin console under `/admin` only, rendered by `layouts/admin.html.erb` and styled by `app/assets/stylesheets/console.css`.
>
> The frontmatter tokens below describe the Clipboard. Inside `/admin`, console.css repoints the shared semantic properties (`--accent`, `--bg-elev`, `--text-strong`, …) at the console's `--cs-*` tokens, so a Clipboard token name used in admin markup resolves to the console value, not the frontmatter hex.

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
- Mobile-first single column for participants and guardians; the support desk widens into a 256px-sidebar shell on `lg` (the admin console has its own shell; see *Admin Console*)
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
- **Rest Grey** (`{colors.bg-elev-2}`): sunken panels and secondary-button hover.
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

**The No Literal Hex Rule.** Every colour resolves through a semantic custom property or a Tailwind token remapped in `themes.css`. A raw hex in a template is a theme bug: it renders correctly in light and wrong in the other seven. New work uses `var(--accent)`, not `#ec3750`. The one exception is a pin drawn onto OpenStreetMap tiles: the tiles stay light under every theme, so map markers (series map, public profile map, landing map) pin their fill and white ring as literal hex; everything the app paints around the map still resolves through tokens.

**The Theme Foreground Rule.** `text-white` is not a colour outside the default theme. It compiles to `var(--color-white)`, which `themes.css` remaps to `var(--bg-elev)` so `bg-white` re-skins — correct for surfaces, silently wrong for text. A filled surface therefore declares its own foreground in `themes.css` rather than trusting `text-white`: accent fills take `--accent-on`, fills that resolve to `--bg-dark`/`--bg-darker` take `--text-on-dark`, fills that resolve to `--bg-elev-2` take `--text-strong` (it is a *light* surface under Catppuccin Latte), and unremapped literal fills pin `#ffffff`. Pin it with a descendant selector (`.bg-x .text-white`), not inheritance — a `text-white` on the child outranks a colour inherited from the parent.

**The Deepened Red Rule.** `{colors.accent}` on white measures **4.02:1** — below WCAG AA's 4.5:1 for normal text. WCAG's large-text exemption (3:1) starts at 18.66px bold or 24px regular, which no button in Attend reaches, so the type cannot buy its way out. The colour moves instead: **wherever white text sits on red, the fill is `{colors.accent-strong}` (4.89:1)**, hovering to `{colors.accent-deep}`. `{colors.accent}` keeps every use that carries no text on it — dots, bars, icon fills, borders, tints, and the progress bar. The two reds are one perceptual step apart; nobody sees the difference, and every white label clears AA. Themes whose own `--accent` already clears their `--accent-on` (all six Catppuccin/Dracula/Nord variants) inherit this for free; `dark` and `solarized-dark` declare `--accent-fill` / `--accent-fill-hover` because theirs do not.

## Typography

**Display Font:** the system UI stack (`ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto`) — Tailwind's default, adopted deliberately. Clipboard surfaces load no webfont; a guardian on a slow connection gets text on first paint. (The admin console self-hosts Open Sans for staff only; that font must never reach a Clipboard surface.)
**Body Font:** the same stack. One family, differentiated entirely by weight and size.
**Label/Mono Font:** none distinct.

**Character:** neutral, native, and unbranded on purpose. The type carries no personality of its own so the density can be high without becoming tiring, and so an eleven-line participant record reads as data rather than as design.

### Hierarchy
- **Display** (700, 1.875rem / `text-3xl`, 1.2): page titles on the few marketing-adjacent surfaces — home, public profiles, docs. Rare (30 uses).
- **Headline** (700, 1.5rem / `text-2xl`, 1.25): the title of a screen or a major panel. The normal top of a page inside the app.
- **Title** (600, 1.125rem / `text-lg`, 1.4): card headings, section headings within a form step, and the required size for text on a red fill.
- **Body** (500, 0.875rem / `text-sm`, 1.5): the workhorse — by a factor of three the most common size in the codebase. Form labels, table cells, button text, nav items. `font-medium` is the default weight, not `font-normal`; the small size needs the extra stem.
- **Label** (600, 0.75rem / `text-xs`, 1.4): status badges, helper text, metadata, timestamps.
- **Eyebrow** (600, 0.6875rem, uppercase, 0.05em): its documented home, the old admin sidebar's section headers, was retired with the admin console. The token stays because Clipboard markup still carries uppercase labels, but it is not a pattern to extend to new surfaces.

### Named Rules

**The Weight-Before-Size Rule.** Hierarchy is built by moving 500 → 600 → 700 at the same size before reaching for a larger size. Attend has more levels of meaning than it has room for type sizes.

**The Fourteen Rule.** Body copy is 14px, not 16px, everywhere inside the app shell — including on red fills, which is why **The Deepened Red Rule** moves the colour rather than the type. The one exception is long-form prose on the docs and public-profile surfaces, which may run at 16px with a 65–75ch measure.

## Layout

A single mobile-first column that becomes a shell at the large breakpoint. Participant and guardian surfaces use `container mx-auto px-4 sm:px-6 lg:px-8 py-8` with a content cap between `max-w-2xl` and `max-w-4xl` — forms stay narrow enough to read in one eye-line. The support desk uses a fixed **256px** (`w-64`) left sidebar that appears at `lg`, with content filling the remainder. The admin console's layout is documented in *Admin Console*.

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

**Full-round** (`rounded-full`, 296 uses) is the system's one piece of personality and it is strictly typed: status badges, avatars, count bubbles, the profile pill in the participant header, and the Hack Club pill button. (Inside `/admin` the console turns legacy status pills into 4px badges.) A pill in Attend means "this is a piece of state or an identity", never "this is a generic button".

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
Attend's most-repeated pattern on Clipboard surfaces and the closest thing it has to a signature. A full-round pill, 12px/600, `px-2.5 py-0.5`, tinted background with same-hue dark text: green for Complete, sky for Awaiting Participant, amber for Awaiting Parent, red for Withdrawn and Rejected, grey as the fallback. The tint carries the meaning at a glance and the word carries it precisely — **never the tint alone**, since colour is not an accessible signal on its own.

### Navigation
- **Participant header:** 64px tall, white, hairline bottom border. Links are 14px/500 in `{colors.text}`, 6px radius, and the active item takes an `{colors.accent-soft}` background with `{colors.accent}` text. Collapses to a hamburger below `md`.
- **Admin navigation:** the light 256px admin sidebar, its uppercase section eyebrows, the full-round user/event selector pills and the faux-input search trigger were all retired when `/admin` moved to the console. Admin navigation is now documented in *Admin Console*; don't rebuild those pieces on a Clipboard surface.

## Event Branding

A series can brand registration for all of its events (**Registration branding** on the series form, in both the classic admin and the console). Onboarding pages for those events, including the signed-out invitation page, render with `<html data-branded>` plus a `<style>` of token values from `BrandTheme`. It is the one sanctioned exception to the rules below, and it is scoped to participant onboarding: the app shell, admin, dashboard and guardian portal stay on the system above. No code is specific to any one brand; a brand is data on the series.

- **What an admin sets:** page background, text colour (ink) and accent (required); optionally a button colour, secondary, highlight and event-card gradient; body and heading fonts; logo, mascot, footer and t-shirt images; and the step navigation (numbered steps or a progress bar). Fonts are self-hosted files listed in `BrandTheme::FONTS` (`app/assets/fonts/<font>/`, declared in `app/assets/tailwind/brand.css`). Images are picked from `app/assets/images/brands/`. Adding a brand means pushing its assets and then filling in the form.
- **How the tokens are made:** `BrandTheme#resolved_tokens` works out the full light-theme set (`--bg-*`, `--text-*`, `--border-*`, `--accent-*`, `--success-*`, plus `--brand-*` extras) from those colours. Text shades are mixed from the ink and pulled back until they clear 4.5:1, and fills are darkened until white text clears 4.5:1. Any token can be pinned to an exact value under "Exact token values".
- **What it keeps:** every contrast floor. A brand won't save unless every text token clears 4.5:1 on the page and on cards, white clears 4.5:1 on every fill, ink clears 4.5:1 on both card gradient stops, and `--border-strong` and `--focus-ring` clear 3:1. The accent is for decoration and never carries words.
- **Themes:** the colours apply only on the light theme. Someone who picked another theme keeps it on branded pages, with the brand's fonts and artwork on top.
- **Why the fonts are self-hosted:** the CSP allows no font hosts, and registrants are mostly minors whose browsers shouldn't be sent to Google. Each font's OFL licence sits next to its files.
- **Every event, branded or not,** gets the welcome screen before the first step and the "you're registered" screen after submitting, both headed by the event card.

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
- **Don't** introduce a webfont on a Clipboard surface. The system stack is a deliberate performance choice for guardians on slow connections and old phones. (The console's Open Sans is staff-only and loads only under `/admin`.)
- **Don't** add a third container radius. 6px controls, 8px containers, full for state and identity.
- **Don't** use `rounded-full` on a plain action button. A pill in Attend means state or identity; the Hack Club brand pill is the one sanctioned exception.
- **Don't** trust `text-white` to be white. Outside the default theme it resolves to a surface colour; a new filled surface needs its foreground declared in `themes.css` per **The Theme Foreground Rule**, or its label disappears.
- **Don't** suppress the focus ring. `focus:outline-none` is only acceptable when a `focus:ring-2` replaces it in the same class list.
- **Don't** use `{colors.text-faint}` for anything a user has to read. It is for placeholders and disabled states only.

## Admin Console (/admin)

**Scope:** every page rendered by `layouts/admin.html.erb`, which alone sets `html.cs-console`. Nothing in this section applies to participant, guardian, onboarding, public, docs or support surfaces, and nothing in the Clipboard sections above applies here unless this section says so. Tokens live in `app/assets/stylesheets/console.css` (`--cs-*` custom properties, light and dark) and are mirrored in `extensions.console` of `.impeccable/design.json`. Helpers live in `app/helpers/console_helper.rb`.

### Overview

**Creative North Star: "The Cloud Console"**

Staff spend whole event cycles in `/admin`, so it borrows the tool they already know how to read: AWS's Cloudscape design system (cloudscape.design, visual refresh), built in ERB, Tailwind and Stimulus rather than imported. The look is a cloud console's: a dark top bar, a white side navigation, breadcrumbs, a flashbar, and content laid out as bordered containers, dense tables and key-value panels. Values come from Cloudscape's published design tokens with one deliberate swap: Hack Club red replaces Cloudscape's interactive blue, deepened so every label clears AA.

The console is a translation, not a remix. Where Cloudscape has a component, the console uses its shape, spacing and states; where Attend needs one Cloudscape lacks, it is assembled from existing kit parts. Its single Hack Club gesture beyond the red is the 3px accent rail on the active side-nav link.

**Key Characteristics:**
- Dark top navigation in both modes, white (or dark-mode slate) side navigation, bordered 16px containers
- Hack Club red as the interactive colour (`--cs-accent`), Cloudscape's own status colours for state
- Open Sans at 14/20, bold (700) for labels, headings and buttons
- Two modes only: the app's nine themes collapse to light or dark inside the console
- Status as icon + word; badges as 4px-radius chips
- One content width for every page, capped at 1680px

### Colors

The console palette is Cloudscape's neutral ramp plus one accent. All values are `--cs-*` tokens; the shared semantic names (`--accent`, `--bg-elev`, `--text-strong`, `--border-card`, …) are repointed at them inside the console, so legacy markup and `themes.css` resolve to the console palette.

**Primary**
- **Console Red** (`--cs-accent`: #c8283f light, 5.48:1 on white; #ff7a8a dark, 6.79:1 on the dark container): buttons, links, the active side-nav link and its rail, the selected tab bar, selected calendar day, checked toggles and tiles, segmented-control selection, progress fill, focus outline (`--cs-focus`). Hover deepens to #8f1426 light / lightens to #ffb3bc dark (`--cs-accent-hover`); pressed is #7a0f20 light (`--cs-accent-active`).
- **Label on red** (`--cs-accent-on`): #ffffff light, #0f141a dark. Dark mode flips to ink on a light red because white on #ff7a8a fails.
- **Selection wash** (`--cs-bg-selected` #fff5f6 / #2a0d14; `--cs-bg-pressed` #ffe5e9 / #3d121c): normal-button hover and press, selected tile and menu item backgrounds, `::selection`.
- **Brand red** (`--cs-brand` #ec3750) is declared but carries no text; it is not an interactive colour in the console.

**Neutral (light / dark)**
- **Page and container** (`--cs-bg-page`, `--cs-bg-container`): #ffffff / #161d26.
- **Shaded and hover** (`--cs-bg-shaded`, `--cs-bg-hover`): #f6f6f9 / #1b232d.
- **Input** (`--cs-bg-input`): #ffffff / #0f141a; disabled #ebebf0 / #1b232d.
- **Heading and body ink** (`--cs-text-heading` #0f141a / #ebebf0, `--cs-text-body` #0f141a / #dedee3), **secondary** (#424650 / #c6c6cd), **muted** (#656871 / #a4a4ad), **disabled** (#8c8c94, placeholders and disabled labels only).
- **Dividers** (`--cs-border-divider` #c6c6cd / #424650 for table heads and menus; `--cs-border-divider-secondary` #ebebf0 / #232b37 for row rules and in-container dividers), **container border** (#c6c6cd / #424650), **input border** (#8c8c94 / #656871).
- **Top navigation** (`--cs-topnav-bg` #0f141a light, #0a0e12 dark): dark in both modes, with its own text (#dedee3), muted (#a4a4ad), field (#161d26) and hover (#1b232d) tokens. #0f141a is also the console's `theme-color`.

**Status (light / dark)**
- **Success** #00802f / #2bb534, **error** #db0000 / #ff7a7a, **warning** text #855900 / #fbd332 with fill #ffe347 / #fbd332, **info** #006ce0 / #42b4ff, **inactive** #656871 / #a4a4ad, each with a matching tinted alert background. Info blue is Cloudscape's status colour for information and in-progress; it is never an action colour.
- **Severity** (incidents): critical #870303, high #ce3311, medium #f89256, low #f2cd54, neutral #656871, with light text on the two darkest and ink on the rest; dark mode lifts critical and high to #d63f38 and #fe6e73 with dark text.

**Named Rules**

**The Red-For-Blue Rule.** Every place Cloudscape uses its interactive blue, the console uses `--cs-accent`, and nowhere else. Red never marks an error state in the console; errors use `--cs-error`, a different red from a different ramp.

**The Two Modes Rule.** The console has Cloudscape's light and dark modes, not the app's nine themes. `admin_console_theme` maps `light` and `catppuccin-latte` to light and every other theme to dark, and the theme controller applies the same mapping client-side. New console styling is written against `--cs-*` tokens and checked in both modes, never per-theme.

**The Tailwind Remap Rule.** In light mode the console remaps Tailwind's gray, slate, blue, green, red, amber and yellow scales onto Cloudscape's ramps, so legacy utility classes land on console colours. New console markup does not rely on that remap: it uses kit classes, or a token utility such as `text-(--cs-text-muted)` when one is truly needed. Light-mode gray-400 is lifted to #71717a so legacy meta text stays AA.

### Typography

**Font:** Open Sans, self-hosted (variable 300–800, normal and italic woff2, `font-display: swap`, preloaded by the admin layout only), falling back to Helvetica Neue, Roboto, Arial. **Mono:** Monaco, Menlo, Consolas for `code`, `kbd`, `pre` and copy-to-clipboard values.

**Character:** Cloudscape's: one family, bold for structure, regular for data. Numbers in tables and key-value values are tabular.

**Hierarchy**
- **Page title** (700, 24px/30px): one per page, in the page header.
- **Modal title** (700, 20px/24px).
- **Container title** (700, 18px/22px): also the side-nav header.
- **Sub-heading and card title** (700, 16px/20px).
- **Body** (400, 14px/20px): table cells, values, descriptions, menu items, nav links.
- **Label** (700, 14px/20px): form labels, key-value keys, table headers, buttons, tabs.
- **Small** (12px/16px): field hints, descriptions under labels, step details, menu group labels (700).
- **Counter value** (300, 32px/40px, -0.01em): the big number in a key-value metric. Light weight is Cloudscape's; it is the one place size, not weight, carries emphasis.

**Named Rules**

**The Sentence Case Rule.** Headings, buttons, labels and tabs are sentence case ("Add staff member"). Table headers are never uppercase; the legacy adapter strips `uppercase tracking-wider` from old markup.

**The Counter Rule.** A count beside a title is a muted, regular-weight `(12)` after the title, never a badge.

### Layout

The Cloudscape app layout. A sticky 52px top navigation spans the page; below it, at `lg` (1024px), a 280px sticky side navigation sits left of the content. The side nav collapses to a 48px rail holding only its reopen button; the state is stored in `localStorage` and applied to `<html>` before first paint. Below `lg` the side nav becomes an overlay drawer (min(280px, 86vw)) opened from a hamburger in the top bar, and on phones the event switcher moves into the top of the drawer.

Content padding is 20px 16px on phones, 24px at `sm`, 40px at `lg`; breadcrumbs and the flashbar share that gutter. Inside a page, regions stack with a 20px gap (`cs-stack`), column layouts are 1 → 2/3 up at 768px, 4-up at 1024px (2-up between), and form fields stack 16px apart in a 2-up field grid from 768px.

**The One Page Width Rule.** Every console page shares one content area, left-aligned against the side nav and capped at 1680px. Any top-level `max-w-*` wrapper a view brings is released to that cap and stripped of its own horizontal gutter and top padding; the content area's padding is the only page gutter. A page that needs a narrower measure constrains its inner content (the wizard caps at 960px), not its outer wrapper.

**The Two-Up Counters Rule.** Key-value grids of counters (`cs-kv-3` holding counter values, and every `cs-kv-4`/`cs-kv-5`) go two-up below 768px instead of collapsing to one long column. Five-up is 3-up at tablet width and 5-up from 1024px.

**The Thumb Rule.** Cloudscape's 32px controls are a desktop density. Below 640px buttons, link and inline-icon buttons, inputs and selects grow to a 40px minimum, nav links, menu items, tabs and segments gain 10px vertical padding, calendar days grow, and inputs move to 16px text so iOS doesn't zoom.

**The Full-Width Action Rule.** On phones a form's actions go full width (`cs-btn-full`, and the wizard's action row stacks in reverse so the primary sits on top); from 640px they size to content, right-aligned in the wizard.

### Elevation & Depth

Flat. Containers, cards, tables and the side nav are bordered and shadowless; the dark top bar is the only tonal layer. Shadows exist only for what floats:
- **Dropdown** (`0 4px 20px 1px rgba(0,7,22,0.10)`): menus, the calendar, popovers.
- **Modal** (`0 4px 20px 1px rgba(0,7,22,0.18)`): modals, the command palette, the mobile drawer.
- **Sticky** (`0 4px 8px 1px rgba(0,7,22,0.10)`): a container pinned under the top bar while content scrolls past.

Dark mode uses the same geometry at full-opacity near-black (`rgba(0,4,12,1)`). Overlays dim the page with #0f141a at 60% (drawer) or 70% (modal). The legacy adapter strips `shadow`/`shadow-sm` from old cards.

### Shapes

Cloudscape's visual-refresh radii, held as tokens: **16px** for containers, cards, modals, the command palette and container-style expandables; **20px** for buttons, the segmented control and the file-picker button; **12px** for flashes and alerts; **8px** for inputs, dropdown menus, menu items, tiles, tokens, the calendar and its days; **4px** for badges, the side-nav count, pagination items and `kbd`. Full-round is for icon-only circular controls (side-nav toggle, calendar nav, modal close, app links) and avatars.

Borders are 1px hairlines for structure, and **2px** in the accent for normal buttons, the selected tile, and alerts (in their status colour). An invalid input keeps its 1px border in error red and thickens the left edge to 4px.

**The Visual Refresh Radii Rule.** 16 containers, 20 buttons, 12 alerts, 8 fields and menus, 4 badges. The Clipboard's 6/8/full scale does not apply inside the console.

### Components

Components are Cloudscape's, translated to `cs-*` classes; each block in console.css names its Cloudscape counterpart. The durable rules are below.

**Buttons**
- **Normal** (`cs-btn`): white fill, 2px accent border, accent label at 14px/700, 20px radius, 32px minimum height, 4px 20px padding. Hover takes the selection wash and the hover accent; press takes the pressed wash. Transitions are 90ms linear on colour only.
- **Primary** (`cs-btn-primary`): accent fill, `--cs-accent-on` label; at most one per view region.
- **Link** (`cs-btn-link`): borderless, transparent, 12px side padding; the tertiary action (Cancel, exit a wizard).
- **Icon** (`cs-btn-icon`) needs an `aria-label`; **inline icon** (`cs-btn-inline-icon`) sits inside text (copy, edit).
- **Dropdown**: a normal button with a trailing caret opening a `cs-menu`.
- **Disabled**: input-border outline and disabled text on normal buttons; disabled fill on primary.

**Status indicator** (`cs_status(type, label)`): a 16px stroked icon plus the word, both in the status colour: success, error, warning, info, in progress, pending, stopped. Unknown types fall back to info. The word always carries the meaning.

**Badges** (`cs_badge(label, color)`): 4px-radius chips at 12px/400, light text on grey (default), green, blue or red, ink on yellow. Severity badges (`cs_severity_badge`) use the severity ramp. Prefer a status indicator over a badge for any lifecycle state.

**Containers** (`cs-container`): 1px container border, 16px radius, header 12px 20px with an 18px title, optional description and right-aligned actions; body 12px 20px 20px; footer above a hairline. A table or list sits flush under a divided header with no body padding.

**Key-value pairs** (`cs-kv`): bold key over regular value, 16px × 32px gaps, 2/3/4/5-up from 768px, optional hairline between columns. Counter tiles use the 32px light counter value (linked counters in accent) instead of icon-in-circle stat cards.

**Tables** (`cs-table`): bold secondary-ink headers over a divider rule, short vertical rules between header cells, 10px 20px cells (6px vertical when compact) with secondary hairlines between rows and a hover wash. Sortable headers carry a 12px sort icon that darkens when active. Expandable row groups use a caret button with `aria-expanded` and the `hidden` attribute on grouped rows, server-rendered in agreement. Filter bars (search field with leading icon, content-width selects) sit under the container header. Empty states are centred, muted, with a bold title and centred actions.

**Inputs / fields** (`cs-field`, `cs-input`, `cs-select`): bold label, optional 12px description and hint, 32px input with 1px input border and 8px radius, italic muted placeholder. Focus is an accent border plus a 1px accent ring (fields never also wear the global 2px outline). Errors are a 12px bold error line with its icon, plus the 4px left edge on the field. Every `date`/`datetime-local` field in the content area gets Cloudscape's calendar (238px grid, 6px gutters, accent selected day, neutral today chip). Checkboxes and radios use accent colour with a label and 12px description; toggles are a 24×16 track; tiles are selectable 8px cards that take a 2px accent border and wash when checked.

**Navigation**
- **Top navigation**: dark bar with the Hack Club flag and "Attend", a search field that opens the command palette (with a `⌘K` hint, hidden below 640px for an icon button), the event switcher (the console's region selector, bold event name with a muted label), and the user menu with a 24px accent avatar. Utilities are 36px tall, 8px radius, hover to the topnav hover tone.
- **Side navigation**: 280px, white, 18px/700 header (the current event) over a divider, 14px/700 section titles, 14px secondary-ink links, collapsible groups with a rotating caret, red count chips. The active link is accent and bold with `aria-current="page"` and a 3px × full-height accent rail at its left; that rail is the console's Hack Club gesture.
- **Breadcrumbs** (`cs_breadcrumbs`): accent links separated by thin chevrons, the current page as muted text.
- **Tabs**: bold secondary-ink labels with short dividers; the selected tab is accent with a 4px accent bar on the bottom rule. **Segmented control**: a 20px-radius outlined group whose selected segment is accent-filled.

**Feedback**
- **Flashbar**: 12px-radius solid bars (info blue, success green, error red, warning yellow with ink text) with a dismiss button, above the page.
- **Alerts** (`cs-alert`): 2px status-colour border, tinted background, 12px radius, status icon, optional bold title.
- **Modals** (`cs-modal`): 600px (820px large), 16px radius, modal shadow, header / body / footer with the footer actions right-aligned (link-style Cancel, then primary).
- **Confirmation**: every `data-turbo-confirm` inside the console opens a Cloudscape alert dialog instead of the browser's `confirm()`: "Confirm" title, the message, link-style Cancel and a primary button labelled with the triggering control's own text. Cancel takes focus first, Escape and backdrop click cancel, Tab is trapped.
- **Progress** (4px bar, accent fill or status fill), **spinner** (16px, slowed under reduced motion), **steps** (a status-icon timeline joined by a hairline), **wizard** (200px step list from `lg`, "Step N of M" over the title, exit / Previous / Next).

**Legacy pattern adapter.** Pages not yet hand-converted are restyled in place by unlayered rules under `:root.cs-console .cs-main`: Tailwind card patterns become 16px bordered containers, table heads lose uppercase and gain the divider, bare inputs take the field treatment, `bg-[#d42f46]`/`bg-[#ec3750]` buttons become primary, grey-bordered buttons become normal buttons, small `rounded-full` status pills become 4px badges, and the Clipboard's literal greys map to console text tokens. It exists so unconverted pages read as Cloudscape; new console work uses the kit, not the patterns the adapter catches.

**Named Rules**

**The Components Layer Rule.** Every `cs-*` kit component is declared inside Tailwind's `@layer components` (order pinned as `theme, base, components, utilities`), so it beats preflight and loses to utilities: `hidden`, `sm:block` and friends work on kit elements, which Stimulus controllers rely on. Only rules that must beat utilities on purpose stay unlayered: the tokens, the legacy-pattern adapter, field focus, the one page width, links in prose, and the console's dark-mode overrides (which need `:root.cs-console`'s extra specificity to beat `themes.css`).

**The Shell Boundary Rule.** The admin layout carries a tracked `<meta name="attend-shell" content="console" data-turbo-track="reload">`. Turbo swaps `<body>` but not `<html>`'s class and `data-theme`, so any visit that crosses between the console and another layout does a full page load. Don't remove the meta or add it to another layout.

**The Confirm-Don't-Colour Rule.** A destructive action on a console page is a normal button (or a link-style button), never primary and never a red fill, and it carries `turbo_confirm`. The confirmation modal is where the action becomes primary: its confirm button is the one primary in the dialog and is labelled with the action, not "OK".

**The Underlined Prose Link Rule.** Links inside running text are underlined: any non-button link inside a paragraph, alert, description, field hint, setting description or empty state is underlined automatically. A link in running text outside a paragraph (a key-value line, a table cell) takes `cs-link-inline`. Standalone links (`cs-link`), breadcrumbs, nav and link-style buttons stay un-underlined until hover. In dark mode the accent sits at 1.86:1 against body text, so colour alone cannot mark a link.

**The Admin-Only Marker Rule.** Inside the console, the project's dashed orange outline (`border-2 border-dashed border-orange-400`) marks an admin-only control or panel on a page other roles can also see. It is never used to wrap a page, or a section of a page, that only global admins can reach; there it marks nothing.

**The Button-Not-Input Rule.** Console forms submit with `f.button` / `button_tag`, never `f.submit`: `themes.css` paints `<input>` backgrounds under dark themes, which breaks the button styling.

### Do's and Don'ts

**Do:**
- **Do** build console pages from the kit: page header, containers, key-value pairs, tables, `cs_status`, `cs_badge`, `cs_breadcrumbs`.
- **Do** write console colour as `--cs-*` tokens and check both modes.
- **Do** show state as a status indicator (icon + word); keep badges for labels and counts.
- **Do** keep one primary button per view region.
- **Do** put destructive actions on normal buttons with `turbo_confirm` and let the confirmation modal carry the primary.
- **Do** underline links in running text; use `cs-link-inline` outside paragraphs.
- **Do** let every page use the one content width; constrain inner content, not the page wrapper.
- **Do** use `f.button` / `button_tag` for form submits.
- **Do** use sentence case for headings, buttons, labels and tabs.

**Don't:**
- **Don't** use red for errors, or Cloudscape blue for actions; accent is interaction, status colours are state.
- **Don't** add per-theme console styling; the console has two modes.
- **Don't** add new Tailwind colour utilities (`bg-gray-50`, `text-blue-800`, `bg-[#…]`) to console markup; the light-mode remap is for legacy pages.
- **Don't** declare a kit component outside `@layer components`, or it will override `hidden`.
- **Don't** add a top-level `max-w-*` page wrapper expecting it to narrow the page.
- **Don't** make a destructive action primary or red-filled on the page.
- **Don't** use uppercase table headers or full-round status pills in new console markup.
- **Don't** wrap global-admin-only pages or sections in the dashed orange admin marker.
- **Don't** use Open Sans, `cs-*` classes or console tokens on a Clipboard surface.
