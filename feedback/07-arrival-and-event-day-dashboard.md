# make the dashboard useful for arrival and event day

priority: medium. evidence: source review.

the event page provides passes, wallet support, a pdf, and an excuse letter. its prominent event context is a city, dates, and countdown. attendees also need the exact meeting location, arrival window, what to bring, and whom to contact if plans change. logistics can otherwise become information they have to recover from messages farther down the page.

there is a concrete date issue: the event page describes an event as ended when its start date is before today, including during a multiday event.

proposed behavior:

- add a dedicated arrival section with the venue or meeting point, directions, arrival window and timezone, essentials to bring, and event support contact.
- make unavailable logistics explicit, including when attendees should expect an update.
- prioritize remaining tasks before the event, entry information during arrival, and useful event information after check-in.
- distinguish upcoming, happening now, and ended using both start and end timestamps.
- preserve passes and relevant records after the event, while replacing obsolete countdown and registration prompts where appropriate.
- keep messages available without making them the only way to find essential arrival instructions.

acceptance criteria:

- an attendee can find where and when to arrive without searching message history.
- day two of a multiday event is shown as in progress, not ended.
- arrival times have an explicit timezone.
- the entry ticket is easy to retrieve on a phone; see [ticket recognition](09-qr-code-entry-ticket.md).

code references: [event dashboard](../app/views/dashboard/show.html.erb), [dashboard overview](../app/views/dashboard/index.html.erb), [dashboard data](../app/controllers/dashboard_controller.rb).
