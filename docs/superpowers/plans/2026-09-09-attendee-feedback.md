# attendee journey feedback implementation plan

> **for agentic workers:** execute one feedback item per implementer, with task-scoped review and a final integration review.

**goal:** implement all ten approved attendee journey feedback briefs.

**architecture:** preserve rails/pundit/active record patterns; share completion presentation, keep correction handling focused, and retain consent boundaries. implementation runs serially because multiple tasks touch the onboarding controller and dashboard.

**tech stack:** rails 8.1, postgresql, hotwire/stimulus, tailwind, rspec.

**spec:** the ten documents in `feedback/`.

## global constraints

- Work in /Users/leo/Code/attend on codex/attendee-flow-feedback. Do not commit, push, deploy, or send real messages.
- You are not alone in the codebase. Preserve other edits and adjust to existing changes. Do not spawn subagents.
- Implement the full feedback brief; report any gaps explicitly. Prefer existing models/services and small focused abstractions.
- Follow AGENTS.md, Omakase Ruby, UUID conventions, and Pundit authorization. Never silently carry consent to a new guardian.
- Use meaningful regression tests for persistence/state/authorization; no tests solely mirroring trivial copy. Run focused specs then report exact results. Root runs the combined suite.
- Test database commands need sandbox escalation. Use bundle exec rspec with require_escalated if the socket is blocked; authorization prefix is already approved.
- No invented event logistics, deadlines, private audience promises, or measured usability claims.
- Run no historical data cleanup. Migrations must be additive and compatible with existing records.

### Task 1: feedback 01

**requirements:** read `feedback/01-reliable-autosave.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own autosave endpoint and shared autosave JS. Return checked persistence outcomes, aggregate useful errors, preserve unsaved files/new legs with explicit status and navigation handling; avoid duplicate flight legs. Cover actual failed persistence and reload. Do not normalize health placeholders yet (task 5).

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-1-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 2: feedback 03

**requirements:** read `feedback/03-consistent-completion-states.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own completion presentation and a focused shared presenter/helper if needed. Derive owner-specific task states using existing consents, participant portions, paused state, submitted status, and eligibility. Correct guardian confirmation and dashboard. Avoid changing who must sign. Preserve legitimate attendee access to event details while signatures are outstanding.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-2-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 3: feedback 02

**requirements:** read `feedback/02-corrections-after-submission.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own correction routes/controller/forms and request workflow. Prefer a focused correction controller and reuse onboarding partials where practical. Routine health/contact changes can be direct; signed identity and guardian changes should create a tracked staff request rather than silently replacing consent. Use existing support ticket machinery if suitable. Include authorization and audit checks. No external messages during execution.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-3-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 4: feedback 05

**requirements:** read `feedback/05-travel-not-ready-yet.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own provisional travel representation/form/controller and progress readiness. Add explicit not-arranged state independently inbound/outbound. Permit later sections with that state; retain registration completion rules but display unresolved travel separately from registration. Do not invent deadlines; use configured values or explicit no-deadline copy. Avoid fake default midnight times. Include dashboard action.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-4-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 5: feedback 10

**requirements:** read `feedback/10-condense-health-and-normalize-na.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own health simplification, model-level exact placeholder normalization, explicit section responses (migration if needed), health stimulus, attendee/guardian summaries. Preserve structured existing clinical/support fields and disclosures. Exact allowed placeholders n/a, na, not applicable after trim/case folding; no substring deletion. Do not run retrospective cleanup. Track unanswered/nothing/details/private separately without inferring no needs from blank. Use existing staff support route for private conversations.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-5-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 6: feedback 04

**requirements:** read `feedback/04-sensitive-information-visibility.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own precise privacy copy and private discussion affordances in profile/health/accommodation, backed by actual policies and guardian views. Reuse task 3 correction/support request route and task 5 health structure. Do not fabricate accommodation approval state; represent recorded requests honestly and provide contact for confirmation. Do not alter access permissions merely to match copy.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-6-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 7: feedback 06

**requirements:** read `feedback/06-invitation-and-account-entry.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own invitation mailer/templates, event context at account entry, invalid/expired/mismatched invitation recovery. No invented effort estimate or deadline; state requirements and resume availability without an unmeasured number. Preserve invitation context across auth and allow switch-account recovery. Show guardian requirements conditionally for known ages, conditional language for unknown ages.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-7-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 8: feedback 08

**requirements:** read `feedback/08-guardian-signing-awareness.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own guardian awareness across intro/guardian/review/dashboard and confirmation notification. Reuse task 2 completion state helper and task 3 corrections. Honor event-age requirement, lock/paused invitations, delivery status. Add actual idempotent ticket-ready notification using existing mailer/job patterns if absent. Do not send any real notifications while implementing/testing.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-8-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 9: feedback 09

**requirements:** read `feedback/09-qr-code-entry-ticket.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own entry-ticket presentation, wallet/pdf terminology, QR instructions and access CTA. Keep QR payload semantics and pass eligibility intact; ensure pending blockers are explicit using task 2 helper. Show checked-in state. Preserve scannability and accessibility.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-9-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.

### Task 10: feedback 07

**requirements:** read `feedback/07-arrival-and-event-day-dashboard.md` in full. This document and the global constraints are binding.

**ownership and interfaces:** Own arrival/event phase dashboard and event logistics configuration if fields missing. Use real venue/timezone/support settings; provide useful not-published fallback and config path rather than inventing location. Determine upcoming/live/ended from starts_at and ends_at. Arrival essentials prominent, documents/pass and useful records retained after event.

- [ ] inspect the relevant sources, existing tests, and predecessor report if an interface is needed.
- [ ] add meaningful failing regressions for changed behavior and run them before implementation.
- [ ] implement the complete feedback behavior with the smallest maintainable changes.
- [ ] run focused tests, relevant lint, and self-review for omitted acceptance criteria.
- [ ] write `.superpowers/sdd/2026-09-09-attendee-feedback/task-10-report.md` with files, tests/red-green evidence, coverage of each acceptance criterion, and limitations. Do not change the feedback brief to claim away unimplemented work.
