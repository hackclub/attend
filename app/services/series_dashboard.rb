# frozen_string_literal: true

# Aggregates a whole event series into the figures its dashboard reads: a
# completion funnel, a per-stage "who is stalled here" chase list, per-event
# totals, and map markers.
#
# Every stage figure comes from ParticipantEvent#onboarding_progress — the same
# method the participant list and the participant's own dashboard read — rather
# than a parallel SQL reimplementation. Parts of that logic cannot be expressed
# in SQL at all (CustomDocument#applies_to? and Participant#minor_on? both
# branch in Ruby), so a SQL twin would drift, and a series total that disagrees
# with the rows behind it is worse than a slower page. The cost is one
# preloaded pass over the series' participant_events; the controller wraps this
# in a short-lived cache so a reload of an active series is cheap.
class SeriesDashboard
  Stage = Struct.new(:key, :label, :chase, :filter, keyword_init: true)

  # The funnel spine, in the order a participant actually clears it. This
  # mirrors ParticipantEvent#compute_onboarding_progress; STEP_TO_STAGE maps its
  # step names on. Guardian details and an adult's emergency contacts are the
  # same question — who do we call — asked of two populations, so they share one
  # stage and the funnel stays readable across a mixed-age series.
  #
  # Nine stages are defined, but stage_rows drops any with nothing applicable, so
  # a typical series renders eight: `documents` only appears once an event has a
  # custom document that applies to someone, and `accommodation` and
  # `freedom_waiver` likewise depend on the event's own settings.
  #
  # `filter` is the query string that opens the matching participant list for a
  # single event. Every stage uses the same param —
  # `blocked_on=<stage key>`, handled by Admin::ParticipantsController#index —
  # because that is the only filter that selects exactly the people this stage
  # counted: a stage's tally is "whose *first* uncleared step is this one", which
  # no status or missing-record filter can express (several stages share one
  # display status, and a missing travel row also counts people still stuck on
  # their profile). One param, one meaning, and the two screens cannot drift.
  STAGES = [
    Stage.new(key: :profile, label: "Profile", chase: "haven't finished their own details",
              filter: { blocked_on: "profile" }),
    Stage.new(key: :travel, label: "Travel", chase: "haven't given us both travel legs",
              filter: { blocked_on: "travel" }),
    Stage.new(key: :accommodation, label: "Accommodation", chase: "haven't answered accommodation",
              filter: { blocked_on: "accommodation" }),
    Stage.new(key: :health, label: "Health & dietary", chase: "are missing health, dietary, or access needs",
              filter: { blocked_on: "health" }),
    Stage.new(key: :contacts, label: "Guardian & contacts", chase: "haven't named a guardian or emergency contact",
              filter: { blocked_on: "contacts" }),
    Stage.new(key: :guardian_portal, label: "Guardian portal", chase: "are waiting on a guardian to finish their portal",
              filter: { blocked_on: "guardian_portal" }),
    Stage.new(key: :waiver, label: "Waiver", chase: "have an unsigned waiver",
              filter: { blocked_on: "waiver" }),
    Stage.new(key: :freedom_waiver, label: "Freedom waiver", chase: "have an unsigned freedom waiver",
              filter: { blocked_on: "freedom_waiver" }),
    Stage.new(key: :documents, label: "Documents", chase: "have documents left to sign",
              filter: { blocked_on: "documents" })
  ].freeze

  # Not a blocking step — these people have cleared onboarding — so `blocked_on`
  # treats this key as its one special case rather than a plain `checked_in=no`,
  # which would also drag in everyone still mid-onboarding.
  ARRIVAL_STAGE = Stage.new(key: :checked_in, label: "Checked in",
                            chase: "have arrived but not been checked in",
                            filter: { blocked_on: "checked_in" }).freeze

  STEP_TO_STAGE = {
    "profile" => :profile,
    "travel" => :travel,
    "accommodation" => :accommodation,
    "health" => :health,
    "guardian_details" => :contacts,
    "emergency_contacts" => :contacts,
    "guardian_portal" => :guardian_portal,
    "waiver" => :waiver,
    "freedom_waiver" => :freedom_waiver,
    "custom_documents" => :documents
  }.freeze

  STAGE_INDEX = STAGES.each_with_index.to_h { |stage, i| [ stage.key, i ] }.freeze

  # Onboarding is done with these; they are not people anyone chases.
  INACTIVE_STATUSES = %w[withdrawn rejected].freeze

  # The order a series lead needs to read the events in: the one running right
  # now, then the one they are about to run, then undated drafts, then history
  # newest-first. `starts_at DESC NULLS LAST` buries a live event under every
  # future one. Sorted in Ruby because "live" turns on Event#completed?, which
  # compares ends_at as a date and has no SQL twin worth keeping in step.
  def self.order_events(events)
    events.sort_by do |event|
      starts_at = event.starts_at

      if starts_at.blank?
        [ 2, 0.0, event.name.to_s ]
      elsif event.completed?
        [ 3, -starts_at.to_f, event.name.to_s ]
      elsif starts_at.future?
        [ 1, starts_at.to_f, event.name.to_s ]
      else
        [ 0, starts_at.to_f, event.name.to_s ]
      end
    end
  end

  # Only events that have started and can actually record a check-in. Public and
  # on the class because the participant list needs the same test to answer
  # `blocked_on=checked_in` with the same population this dashboard counted.
  def self.arrivals_expected?(event)
    return false if event.starts_at.blank? || event.starts_at.future?

    event.scan_contexts.any?(&:checks_in?)
  end

  def initialize(series, events:, user:)
    @series = series
    @events = events
    @user = user
  end

  attr_reader :series, :events, :user

  # ── Funnel ────────────────────────────────────────────────────────────────
  #
  # A participant's blocking step is the *first* one they haven't cleared, so
  # "cleared stage i" and "stalled at stage i" partition the people who reached
  # it: cleared[i] == cleared[i-1] - stalled[i], exactly. That makes the drop
  # between two bars the same number as the chase count on the lower one —
  # one figure doing both jobs, with no rounding to reconcile.
  def stage_rows
    load!
    @stage_rows ||= begin
      remaining = active_total
      reached_percent = 100
      STAGES.filter_map do |stage|
        stalled = @stalled_totals[stage.key].to_i
        applicable = @applicable_totals[stage.key].to_i
        next if applicable.zero?

        remaining -= stalled
        cleared_percent = percent(remaining, active_total)
        # The hatch spans from this stage's fill to the previous stage's, so the
        # two rows line up exactly and the pair can never total over 100% the
        # way independently-rounded figures would.
        stalled_percent = reached_percent - cleared_percent
        row = {
          stage: stage,
          cleared: remaining,
          stalled: stalled,
          applicable: applicable,
          percent: cleared_percent,
          stalled_percent: stalled_percent,
          # A stage only some events run ("2 of 5 events") needs saying, or the
          # bar looks like a hole in the funnel.
          partial_events: applicable < active_total ? @stage_event_counts[stage.key].to_i : nil,
          by_event: stalled_by_event(stage.key)
        }
        reached_percent = cleared_percent
        row
      end
    end
  end

  # Check-in sits after the funnel rather than inside it: it only applies to
  # participants whose event has started and has a check-in context, so folding
  # it into the cumulative arithmetic would count everyone at a future event as
  # "checked in".
  def arrival_row
    load!
    return nil if @arrival_applicable.zero?

    {
      stage: ARRIVAL_STAGE,
      cleared: @arrival_cleared,
      stalled: @arrival_applicable - @arrival_cleared,
      applicable: @arrival_applicable,
      percent: percent(@arrival_cleared, @arrival_applicable),
      by_event: stalled_by_event(ARRIVAL_STAGE.key)
    }
  end

  # The chase list: every stage anyone is stuck on, worst first. Ties break on
  # funnel order so the earliest blocker wins — clearing it unblocks the rest.
  def chase_rows
    (stage_rows + [ arrival_row ].compact)
      .select { |row| row[:stalled].positive? }
      .sort_by { |row| [ -row[:stalled], STAGE_INDEX.fetch(row[:stage].key, STAGES.length) ] }
  end

  # ── Per-event ─────────────────────────────────────────────────────────────

  def event_rows
    load!
    events.map do |event|
      active = @active_by_event[event.id].to_i
      cleared = @cleared_by_event[event.id].to_i
      {
        event: event,
        active: active,
        cleared: cleared,
        percent: percent(cleared, active),
        inactive: @inactive_by_event[event.id].to_i,
        pending_invitations: pending_invitations[event.id].to_i,
        open_incidents: open_incidents[event.id],
        # The single biggest blocker on this event, which is what a series lead
        # actually wants off a row: "this one is stuck on guardians".
        top_blocker: top_blocker_for(event)
      }
    end
  end

  def totals
    load!
    {
      events: events.length,
      active: active_total,
      inactive: @inactive_by_event.values.sum,
      cleared: @cleared_by_event.values.sum,
      percent: percent(@cleared_by_event.values.sum, active_total),
      blocked: active_total - @cleared_by_event.values.sum,
      pending_invitations: pending_invitations.values.sum,
      open_incidents: open_incidents.values.compact.sum,
      incidents_visible: open_incidents.values.any? { |v| !v.nil? }
    }
  end

  def active_total
    load!
    @active_by_event.values.sum
  end

  def next_event
    @next_event ||= events.select { |e| e.starts_at.present? && e.starts_at.future? }.min_by(&:starts_at)
  end

  def live_events
    @live_events ||= events.select { |e| e.starts_at.present? && !e.starts_at.future? && !e.completed? }
  end

  # ── Map ───────────────────────────────────────────────────────────────────

  def mappable_events
    @mappable_events ||= events.select { |e| e.venue_coordinates.present? }
  end

  def unmapped_events
    @unmapped_events ||= events - mappable_events
  end

  # ── Invitations & incidents ───────────────────────────────────────────────

  def pending_invitations
    @pending_invitations ||= Invitation.where(event_id: event_ids).pending.group(:event_id).count
  end

  # Series membership does not by itself grant incident visibility — IncidentPolicy
  # keys off event_role_assignments and each incident's own visible_to_roles. So
  # this counts per event with that policy's own rules and returns nil (not zero)
  # for an event the viewer can't see incidents on, keeping "none open" and "not
  # yours to see" distinct all the way to the view.
  def open_incidents
    @open_incidents ||= events.index_by(&:id).transform_values do |event|
      if user.global_admin?
        event.incidents.open_incidents.count
      else
        roles = incident_roles_by_event[event.id]
        roles.present? ? event.incidents.open_incidents.for_roles(roles).count : nil
      end
    end
  end

  private

  def event_ids
    @event_ids ||= events.map(&:id)
  end

  def incident_roles_by_event
    @incident_roles_by_event ||= user.event_role_assignments
      .where(event_id: event_ids)
      .pluck(:event_id, :role)
      .group_by(&:first)
      .transform_values { |pairs| pairs.map(&:last) }
  end

  def percent(part, whole)
    return 0 if whole.to_i.zero?
    ((part.to_f / whole) * 100).round
  end

  def stalled_by_event(stage_key)
    counts = @stalled_by_event[stage_key] || {}
    events.filter_map do |event|
      count = counts[event.id].to_i
      next if count.zero?
      { event: event, count: count }
    end.sort_by { |row| -row[:count] }
  end

  def top_blocker_for(event)
    best = nil
    @stalled_by_event.each do |stage_key, counts|
      count = counts[event.id].to_i
      next if count.zero?
      index = STAGE_INDEX.fetch(stage_key, STAGES.length)
      best = { key: stage_key, count: count, index: index } if best.nil? || count > best[:count] ||
        (count == best[:count] && index < best[:index])
    end
    return nil if best.nil?

    stage = STAGES.find { |s| s.key == best[:key] } || ARRIVAL_STAGE
    { stage: stage, count: best[:count] }
  end

  # One pass over the series. Everything above reads the tallies it fills in.
  def load!
    return if @loaded

    @active_by_event = Hash.new(0)
    @inactive_by_event = Hash.new(0)
    @cleared_by_event = Hash.new(0)
    @stalled_totals = Hash.new(0)
    @applicable_totals = Hash.new(0)
    @stalled_by_event = {}
    @stage_event_counts = Hash.new(0)
    @arrival_applicable = 0
    @arrival_cleared = 0

    checked_in_ids = checked_in_participant_event_ids

    events.each do |event|
      arrivals_expected = arrivals_expected?(event)
      stages_seen_here = Set.new

      participant_events_for(event).each do |pe|
        if INACTIVE_STATUSES.include?(pe.status)
          @inactive_by_event[event.id] += 1
          next
        end

        @active_by_event[event.id] += 1

        progress = pe.onboarding_progress
        applicable = progress[:steps].filter_map { |step| STEP_TO_STAGE[step[:name]] }.uniq
        applicable.each do |key|
          @applicable_totals[key] += 1
          stages_seen_here << key
        end

        blocking = progress[:blocking_step] && STEP_TO_STAGE[progress[:blocking_step]]

        if blocking
          @stalled_totals[blocking] += 1
          (@stalled_by_event[blocking] ||= Hash.new(0))[event.id] += 1
          next
        end

        # Onboarding-complete. Whether they've walked through the door is the
        # arrival stage's business, not the funnel's.
        @cleared_by_event[event.id] += 1
        next unless arrivals_expected

        @arrival_applicable += 1
        if checked_in_ids.include?(pe.id)
          @arrival_cleared += 1
        else
          (@stalled_by_event[ARRIVAL_STAGE.key] ||= Hash.new(0))[event.id] += 1
        end
      end

      stages_seen_here.each { |key| @stage_event_counts[key] += 1 }
    end

    @loaded = true
  end

  def participant_events_for(event)
    scope = event.participant_events.preload(
      :participant, :travel_inbound, :travel_outbound, :accommodation, :medical,
      :dietary, :accessibility, :consents, :emergency_contacts,
      guardian_participant_events: :emergency_contacts
    )

    scope.to_a.each do |pe|
      # onboarding_progress reads pe.event for the accommodation, freedom-waiver
      # and custom-document branches. Pointing every row at the event instance we
      # already hold keeps active_custom_documents memoized once per event
      # instead of re-querying per participant.
      pe.association(:event).target = event
    end
  end

  def arrivals_expected?(event)
    self.class.arrivals_expected?(event)
  end

  def checked_in_participant_event_ids
    @checked_in_participant_event_ids ||= Scan.for_check_in
      .joins(:participant_event)
      .where(participant_events: { event_id: event_ids })
      .distinct
      .pluck(:participant_event_id)
      .to_set
  end
end
