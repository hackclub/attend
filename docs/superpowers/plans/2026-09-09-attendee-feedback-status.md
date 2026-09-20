# attendee feedback implementation status

last updated: 2026-09-11.

implementation resumed on 2026-09-10. agents are working again after intermittent credit errors. autosave review found a guardian identity-boundary issue now being fixed. completion presentation and invitation/account entry are being implemented with separate file ownership.

branch: `codex/attendee-flow-feedback`. changes are uncommitted. nothing was deployed or sent to attendees.

## progress

| feedback | status |
| --- | --- |
| 01 reliable autosave | implemented; focused tests and independent review pass |
| 02 corrections after submission | implementation in progress |
| 03 consistent completion states | implementation in progress |
| 04 sensitive information visibility | not started |
| 05 travel not ready yet | read-only implementation preflight complete |
| 06 invitation and account entry | implementation in progress |
| 07 arrival and event-day dashboard | not started |
| 08 guardian signing awareness | not started |
| 09 qr code entry ticket | not started |
| 10 condense health and normalize n/a | read-only implementation preflight complete |

## partial autosave changes

- return persistence outcomes and useful errors instead of unconditional success.
- validate and save multi-record updates together.
- identify new flight legs awaiting explicit submission.
- add visible retry, dirty-state tracking, selected-file warnings, and beforeunload handling.
- preserve the shared admin message form's existing save-status element.
- add request and javascript regression coverage.

the coordinator fixed an interrupted implementation error: nested `ActionController::Parameters` does not provide `any?`; flight-leg detection now uses its values collection.

this is not a completed or reviewed fix. remaining review must cover all feedback 01 acceptance criteria, especially turbo/back navigation, explicit submission during an in-flight autosave, notify-only emergency forms, unsaved/new/deleted flight-leg detection, shared admin-message behavior, and transactional error handling. do not infer full coverage from focused test results.

## validation

- `bundle exec rspec spec/requests/onboarding_profile_autosave_spec.rb spec/requests/onboarding_travel_autosave_spec.rb spec/requests/guardian_email_conflict_spec.rb spec/requests/onboarding_documents_step_spec.rb`: 29 examples, 0 failures. existing Rack deprecation warnings remain.
- `mise exec node@22.22.3 -- node --test spec/javascript/autosave_controller_test.mjs`: 3 tests passed.
- focused rubocop: 4 files inspected, no offenses.
- the initial full-suite run overlapped work in progress and cannot serve as a clean baseline. it ran 1705 examples, with 3 failures and 3 pending; the two autosave failures were subsequently addressed.
- the unrelated failure at `spec/requests/api/v1/webhooks_spec.rb:247` reproduces independently. its missing-secret setup stubs legacy configuration while the controller also reads `Docuseal::HostConfig.webhook_secrets`; expected 503, actual 401. no production authentication changes were made.

## resume

complete and independently review feedback 01 before continuing shared-file changes. follow the execution order in [the implementation plan](2026-09-09-attendee-feedback.md).

local working notes and snapshots are in `.superpowers/sdd/2026-09-09-attendee-feedback/` (git-ignored). `task-2-preflight.md` describes completion presentation; `task-3-preflight.md` describes corrections. the ten documents in `feedback/` remain the requirements. do not mark a feedback item complete merely because a preflight exists.
