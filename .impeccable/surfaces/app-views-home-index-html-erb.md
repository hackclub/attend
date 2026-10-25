---
version: 1
slug: "app-views-home-index-html-erb"
primary_target: "app/views/home/index.html.erb"
related_targets: ["app/controllers/home_controller.rb","app/services/landing_stats.rb","app/javascript/controllers/landing_map_controller.js"]
---

# Landing page (`/`, signed-out)

Scope: the signed-out front door. Mode: Persuade. Audience: Hack Club staff (sign in with Hack Club), guardians arriving from invite emails, incident reporters on phones. Action: "Continue with Hack Club"; the guardian and incident doors must stay visible at every width, and the "Need help?" mailto door carries over from the previous landing page (support address attend@hackclub.com is product truth, not an addition). Proof: live numbers from the database (events that have started, students on them excluding withdrawn/rejected, distinct countries of residence) and a map of every set-up event with coordinates; upcoming events render quieter than past ones. Constraint: no event-specific code, no new webfont, every colour through a theme token, works in all nine themes, hourly cache so the page never queries live on every hit. Unresolved: 52 past events on prod have no coordinates until `events:geocode_missing` is run with APPLY=1.

## Direction contract

THESIS: The sentence is the page. "Attend has run N hackathons across the world, supporting N students from N countries" is set at display size and the sixty-five countries are listed beneath it as a roll-call with their counts, so the proof is the students, not a hero with a map on the right. Refused: split hero with product peek, centred headline over cards, stat tiles.

OWN-WORLD: Attend's clipboard. Paper ground (`--bg-app`), card white, ink headings, hairline rules, system sans; the three numbers in Hack Club red are the only red besides the one primary button. Tabular numerals everywhere a count appears. The map is an OpenStreetMap inset in a hairline frame with solid red dots for past events, hollow grey ghost dots for upcoming, a live dot pulsing once.

STORY: A visitor reads one sentence and knows what Attend is and how much it has carried; the roll makes "65 countries" concrete; hovering or focusing a country lights the events its students went to. Staff click Continue; guardians and reporters find their door under the sentence.

FIRST VIEWPORT (1440×900): 64px header band, wordmark left, Continue with Hack Club right. Below, a two-column hero: left column the sentence at ~60px/700/-0.03em with red tabular numbers, then the doors row ("Not staff?" + Parent or guardian → + Report an incident →); right column a 320px-wide, 300px-tall map inset, sticky as the roll scrolls. Under a hairline, the roll begins inside the first viewport: country at 600, count tabular at 500 in muted ink, five columns at desktop, two on a phone, hairline between rows. Signature interaction: hover/focus on a country row highlights that country's events on the map (dots grow and the others fade), and the map popup names the event, city, dates, headcount. Motion grammar: one authored moment, the dots appearing in date order on first paint (≤600ms, exponential ease-out), nothing else animates except colour transitions. Phone: the map inset moves under the sentence at full width, 220px tall, not sticky; the roll follows as two columns.

FORM: The Country Roll, candidate 7 of 7 on the ordered list, dealt by seed 9a2b0c2f (surface scope, persuade; the concept-seed run printed `SURFACE CONCEPT SEED (key: 9a2b0c2f)` and dealt indices 4, 3, 7), locked by the user on the decision page; code-led.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## As built (documented 2026-10-24)

Page-level decisions that live here, not in DESIGN.md. They are used on this surface only and are not a system ramp step or component for other surfaces to inherit.

- Landing sentence: `clamp(2rem, 1.1rem + 3.4vw, 3.75rem)` / 700 / -0.03em / line-height 1.04, `text-wrap: balance`, 18ch cap, ink on paper. This sits above DESIGN.md's Display step (1.875rem); it is the one display-size sentence on the one persuade surface outside the app shell. Do not reuse it inside the shell.
- The three numbers in the sentence are `--accent` with tabular numerals; the Continue button is the only other red. One Voice Rule holds.
- Map pins: solid red dot (15px, 2px white ring, soft drop) for events that happened; hollow 10px ghost (paper fill, 1.5px grey ring) for upcoming; the live event gets one pulse after the 300ms staggered date-order entrance (reduced-motion: no animation). Pin colours are literal hex because they sit on OpenStreetMap tiles; this is the same exception the series and public profile maps use and is now recorded in DESIGN.md's No Literal Hex Rule.
- Country roll: ordered list of `<button aria-pressed>` rows, country at 600 ink, count tabular at 500 soft, hairline row rules, CSS columns (2 / 3 / 3 across sm / lg), hover and pressed state use `--accent-soft` wash with accent text. Hover/focus previews, click toggles a sticky selection.
- Build vs contract: the roll is three columns at desktop (contract said five) so long country names stay on one line beside a half-width map; the map inset is half-width and 26rem tall at lg (contract said 320x300) and 14rem on phones (contract said 220px). Doors row carries a fourth door, "Need help?", from the previous landing page.
- Carried defects, not design: the development-only sign-in panel uses `text-[#ffffff]` on `--bg-dark` (dev-only, never ships); Leaflet's CSS is loaded from a CDN link in `content_for :head`.
