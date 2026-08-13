# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Three distinct audiences, each with its own surfaces. When their needs conflict, **each surface is designed for its own audience** — there is no global tiebreaker.

- **Participants** — under-18 attendees of in-person Hack Club events. They pass through the multi-step onboarding wizard once (profile, travel, accommodation, health, guardian info), then live in a lightweight dashboard: their status, ticket/wallet pass, travel details, messages, documents to sign. Mostly on phones.
- **Guardians** — parents or legal guardians, typically non-technical, arriving via a magic link (email or SMS) for a one-shot visit to complete consent forms, waivers, and emergency contact details. The hardest audience to convert; often on an old phone. A guardian portal center (`/guardian/portals`) lets them find their own portals by code.
- **Staff** — Global Admin, Event Admin, Ops Staff, and Safeguarding Lead. They live in `/admin` for the length of an event cycle: dashboards, participant tables, rooming plans, travel ops, messaging blasts, incidents, audit logs, integrations. Density and speed matter more here than expression.

## Product Purpose

Attend onboards under-18 participants for in-person Hack Club events, collecting everything needed for safeguarding, travel, accommodation, and on-site operations in one system. Success is a participant who arrives at an event fully cleared — consent signed by a guardian, travel and rooming known, medical and accessibility needs recorded and access-controlled — without the organisers chasing anyone through spreadsheets.

## Positioning

- **The whole journey in one place.** Replaces the sprawl of forms, spreadsheets, and email chains: onboarding, guardian consent, travel legs, rooming, check-in scanning, messaging, and incident reporting live in a single system with one status per participant.
- **Built for how Hack Club actually runs events.** Shaped around real HC event operations — Hack Club Auth, Slack, Twilio/Signal messaging, Apple and Google Wallet passes, QR check-in at the venue — rather than a generic event platform bent to fit.

Not positioned as a general self-hostable product for other youth organisations, even though the code is public at `hackclub/attend`.

## Operating Context

- **Event cycle**: an event is created and configured by admins → participants are invited or apply → onboarding wizard → guardian magic-link consent (DocuSeal e-signature, plus physically-signed documents with photo upload) → ops fill in travel, rooming, dietary → wallet pass issued → QR scan check-in on site → incidents and notes logged during the event.
- **Multi-event and series**: several events run concurrently, grouped into series; role assignments are scoped per event or per series.
- **Off-screen materials**: signed waivers, excuse letters for school, printed/scanned physical documents, wallet passes on a phone at a venue door.
- **Sideband channels**: email, SMS, and Slack all carry participants and guardians into the app; a link that 404s or a page that fails on an old phone is a dropped participant.
- **PWA**: installable, with service worker and manifest.

## Capabilities and Constraints

- Rails 8.1 / Ruby 3.4, PostgreSQL with UUID primary keys, Hotwire (Turbo + Stimulus), Tailwind CSS, Propshaft + Importmap. No React/Vue build step — design work happens in ERB, Tailwind, and Stimulus controllers.
- `app/assets/stylesheets/themes.css` carries the theme layer and, in places, overrides Tailwind (notably form inputs and `text-white`). Tailwind must be rebuilt before visual verification.
- Devise + OmniAuth (Hack Club Auth) for identity; Pundit for authorization. Six roles: Participant, Guardian, Global Admin, Event Admin, Ops Staff, Safeguarding Lead.
- Medical, accessibility, safeguarding, incident, and note records are encrypted at rest; access is role-scoped and every admin action is audit-logged (PaperTrail + console1984 + an `AuditLog` model).
- Integrations: DocuSeal (consent), Airtable sync, Slack (OAuth + blasts), Twilio/Signal (SMS), Apple/Google Wallet, S3/Cloudflare R2 via Active Storage, an MCP server (toolchest), and a public JSON API with per-event and global tokens.
- Public opt-in participant profiles at `/p/:slug` with deliberately conservative privacy defaults (checked-in past events only, noindex, photo opt-in).
- Background work runs on Solid Queue; caching on Solid Cache; real-time on Solid Cable.

## Brand Commitments

Hack Club's visual identity is binding — existing HC colours, logo, and voice. Attend does not get a separate brand of its own.

## Evidence on Hand

- Real product surfaces exist and are the incumbent design authority: onboarding wizard, guardian portal, participant dashboard, admin dashboards and tables, public profiles, docs page, incident report form.
- No testimonials, customer logos, pricing, benchmarks, or press exist. Do not fabricate them.
- Seed data and development test accounts exist for local verification (see README).

## Product Principles

1. **Design each surface for the person on it.** The guardian portal and the ops dashboard are different products wearing one brand; don't average them.
2. **A dropped guardian is a dropped participant.** Every guardian-facing path must survive an old phone, a bad connection, and a single visit with no second chance.
3. **Sensitive data is shown only to the role that needs it.** Medical, safeguarding, and incident information is never made ambient for the sake of a nicer layout.
4. **One status, everywhere.** A participant's readiness is a single truth surfaced consistently across participant, guardian, and staff views.
5. **Real event operations beat abstraction.** When a design choice and the way an event actually runs disagree, the event wins.

## Accessibility & Inclusion

- WCAG 2.1 AA is the floor on every surface. Participants disclose real accessibility needs through this product; the product itself must not be the barrier.
- Light and dark themes are both first-class — every surface must work in both, with `themes.css` as authority.
- Mobile-first for participant and guardian surfaces; staff surfaces may assume a larger screen but must not break on one.
