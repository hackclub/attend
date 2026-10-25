# support travel plans that are not ready yet

priority: medium. evidence: source review; anticipated attendee friction rather than measured abandonment.

travel appears early in the wizard. both travel modes are required and there is no explicit not-booked-yet choice. later steps are locked until the current step is completed. an attendee with unresolved plans may guess, choose other, or stop before completing unrelated information.

proposed behavior:

- add an explicit "i haven't arranged this yet" state for arrival and departure independently.
- allow completion of independent tasks while travel remains outstanding.
- distinguish an intended mode from confirmed booking details.
- show the deadline for updating travel and provide a direct return action from the event dashboard.
- separate registration progress from travel readiness so incomplete plans remain visible after forms are submitted.
- avoid using default midnight timestamps as if they were attendee-confirmed arrival times.

acceptance criteria:

- an attendee can complete health and guardian details without inventing travel information.
- staff can distinguish unknown, provisional, and confirmed travel information.
- returning to travel preserves previously entered details.
- incomplete arrival or departure plans remain actionable on the dashboard until resolved.

code references: [travel form](../app/views/onboarding/travel.html.erb), [wizard gating](../app/controllers/onboarding_controller.rb), [travel model](../app/models/travel.rb).
