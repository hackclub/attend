# One message to participants across many events in a series, such as
# "everyone still incomplete at every upcoming event".
#
# It is a template rather than a message of its own: sending it creates an
# ordinary Message on each event it reaches (Message#series_broadcast) and
# sends that through the per-event pipeline, so deliveries, participant
# inboxes, read tracking, retries and each event's messages page all work as
# they do for any other message. {{event_name}} fills in per event.
#
# Sending is two background steps (see SeriesBroadcastJob): the fan-out
# creates one draft copy per event that has anyone in the audience, then each
# copy is sent by its own SeriesBroadcastMessageJob. Both are safe to run
# again: a copy is unique per event, and Message#send! only sends a draft.
#
# Screened once, here, rather than once per event; the copies are created
# already cleared (see #build_message).
class SeriesBroadcast < ApplicationRecord
  include ScreenedBroadcast
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event_series
  belongs_to :sent_by_user, class_name: "User"
  has_many :messages, dependent: :restrict_with_error

  # Message's audiences that mean the same thing at every event. Picking
  # people or groups is per event, so those stay on each event's own page.
  AUDIENCES = Message::AUDIENCES.except(:specific_participants, :attendees_in_groups).freeze

  EVENT_SCOPES = {
    "upcoming" => "Upcoming and running events",
    "all" => "Every event in the series",
    "selected" => "Events you pick"
  }.freeze

  # A copy that is still on its way out keeps the broadcast sending.
  UNSETTLED_MESSAGE_STATUSES = %w[draft scheduled pending_review sending].freeze

  # What BroadcastScreener judges a series broadcast against, in place of one
  # event: the series and the span of the events it is going to.
  ScreeningContext = Data.define(:id, :name, :event_series, :starts_at, :ends_at, :venue_name)

  enum :status, {
    draft: "draft",
    scheduled: "scheduled",
    # Held by BroadcastScreener until a global admin or another series owner
    # approves it.
    pending_review: "pending_review",
    sending: "sending",
    completed: "completed",
    cancelled: "cancelled"
  }

  validates :audience, inclusion: { in: AUDIENCES.keys.map(&:to_s), message: "isn't one that works across a series" }
  validates :event_scope, inclusion: { in: EVENT_SCOPES.keys }
  validates :channels, presence: true
  validate :channels_are_valid
  validate :selected_events_are_in_series
  validate :message_content_is_valid, if: -> { will_save_change_to_body? || will_save_change_to_subject? || will_save_change_to_audience? }
  validate :has_no_images, if: :will_save_change_to_body?

  scope :recent, -> { order(created_at: :desc) }
  scope :pending_scheduled, -> { scheduled.where(scheduled_at: ..Time.current) }

  def audience_label
    AUDIENCES[audience.to_s.to_sym] || audience.to_s.titleize
  end

  def channel_labels
    channels.map { |c| Message::CHANNELS[c.to_sym] || c.titleize }.join(", ")
  end

  def event_scope_label
    EVENT_SCOPES.fetch(event_scope, event_scope.to_s.humanize)
  end

  def guardian_audience?
    audience.to_s.in?(%w[all_guardians guardians_of_confirmed guardians_pending])
  end

  # The events it goes to. "upcoming" includes events under way, so a
  # broadcast on the first morning of an event still reaches it.
  def target_events
    events = event_series.events
    case event_scope
    when "upcoming" then events.not_ended
    when "selected" then events.where(id: selected_event_ids)
    else events
    end
  end

  # An unsaved Message carrying this broadcast's content: the per-event copy
  # when given an event, otherwise a probe for rendering and validation.
  # Copies are marked as already screened, since the broadcast was.
  def build_message(event: nil)
    message = Message.new(
      event: event,
      subject: subject,
      body: body,
      channels: channels,
      audience: audience,
      audience_filters: {},
      sent_by_user: sent_by_user,
      status: :draft
    )
    message.screened_digest = message.content_digest if event
    message
  end

  # Everyone the audience matches at each target event, as
  # { event_id => count }: one grouped query, not one per event.
  def recipient_counts_by_event
    audience_probe.recipient_counts_by_event
  end

  def recipient_count_estimate
    recipient_counts_by_event.values.sum
  end

  # A sample of the audience across every target event, for the preview.
  def preview_recipients(limit: 20)
    scope = audience_probe.recipients.limit(limit)
    guardian_audience? ? scope : scope.preload(:participant, :event)
  end

  # Renders through a Message so a broadcast reads exactly as its copies
  # will. With an event, {{event_name}} is filled in for it.
  def body_as_html(recipient: nil, event: nil, images_as_links: false)
    build_message(event: event).body_as_html(recipient: recipient, images_as_links: images_as_links)
  end

  def body_as_plain(recipient: nil, event: nil)
    build_message(event: event).body_as_plain(recipient: recipient)
  end

  def subject_for(recipient, event: nil)
    build_message(event: event).subject_for(recipient)
  end

  def uses_placeholders?
    build_message.uses_placeholders?
  end

  # First send of a draft or scheduled broadcast: screens it, then hands the
  # fan-out to a job. Returns false if it didn't go out: it already had, or
  # the screener held it (now #pending_review?), or it holds content that may
  # never be sent (reasons in #errors).
  def send!(sender: sent_by_user, trust_sender: true)
    return false unless draft? || scheduled?
    return false if refuse_blocked_content!

    flagged = screen_for_review(sender: sender, trust_sender: trust_sender)
    sent = with_lock do
      next false unless draft? || scheduled?

      if flagged
        hold_for_review!(flagged, sender: sender)
        next false
      end

      update!(status: :sending, sent_at: Time.current)
      true
    end
    SeriesBroadcastJob.perform_later(series_broadcast_id: id) if sent
    sent
  end

  # Schedules a draft, screening it now so a held broadcast is reviewed
  # before its send time rather than at it. Returns false if held.
  def schedule!(sender:)
    return false if refuse_blocked_content!

    flagged = screen_for_review(sender: sender)
    with_lock do
      if flagged
        hold_for_review!(flagged, sender: sender)
        next false
      end

      update!(status: :scheduled)
      true
    end
  end

  # Cancels a scheduled broadcast, or withdraws one waiting for review.
  # Once sending, each event's copy is its own message.
  def cancel!
    with_lock do
      next false unless scheduled? || pending_review?

      pending_broadcast_review&.withdraw!
      update!(status: :cancelled)
      true
    end
  end

  # Creates the per-event copies and queues each one's send. Events where
  # nobody matches the audience are skipped (and remembered), so they don't
  # each get an empty message on their page. Safe to run again: existing
  # copies are reused, and a copy that has already gone out isn't re-queued.
  def fan_out!
    return unless sending?

    existing = messages.pluck(:event_id, :id).to_h
    counts = recipient_counts_by_event
    skipped = []

    target_events.find_each do |event|
      if !existing.key?(event.id) && counts[event.id].to_i.zero?
        skipped << event.id
        next
      end

      message = message_for(event)
      SeriesBroadcastMessageJob.perform_later(message_id: message.id) if message.draft?
    end

    update!(skipped_event_ids: skipped, fanned_out_at: Time.current)
    settle!
  end

  # Done once the fan-out has run and every copy has settled. Called as each
  # copy settles (see Message#settle_series_broadcast).
  def settle!
    return unless sending? && fanned_out_at
    return if messages.where(status: UNSETTLED_MESSAGE_STATUSES).exists?

    with_lock { update!(status: :completed) if sending? }
  end

  # Totals across a set of broadcasts' copies, as
  # { id => { events:, recipients:, delivered:, failed: } }, in one query.
  def self.totals_for(ids)
    Message.where(series_broadcast_id: ids).group(:series_broadcast_id)
      .pluck(:series_broadcast_id, Arel.sql("COUNT(*)"), Arel.sql("COALESCE(SUM(recipient_count), 0)"),
        Arel.sql("COALESCE(SUM(sent_count), 0)"), Arel.sql("COALESCE(SUM(failed_count), 0)"))
      .to_h { |id, events, recipients, delivered, failed| [ id, { events: events, recipients: recipients, delivered: delivered, failed: failed } ] }
  end

  def totals
    self.class.totals_for([ id ]).fetch(id, { events: 0, recipients: 0, delivered: 0, failed: 0 })
  end

  # ScreenedBroadcast: an admin approved it. Back on its schedule if it has
  # one still ahead, otherwise out now.
  def release_after_review!(by:)
    if scheduled_at.present? && scheduled_at > Time.current
      update!(status: :scheduled)
    else
      update!(status: :draft)
      send!(sender: by)
    end
  end

  # ScreenedBroadcast: an admin rejected it. Back to its author as a draft.
  def return_after_rejection!
    update!(status: :draft)
  end

  def screening_subject
    subject
  end

  def screening_text
    body_as_plain
  end

  def blocked_content_sources
    [ body ]
  end

  def screening_event
    events = target_events
    ScreeningContext.new(
      id: id,
      name: "#{event_scope_label} in #{event_series.name} (#{events.count} events, one message each)",
      event_series: event_series,
      starts_at: events.minimum(:starts_at),
      ends_at: events.maximum(:ends_at),
      venue_name: nil
    )
  end

  def broadcast_review_owner
    { event_series: event_series }
  end

  def refuse_blocked_content!
    reasons = blocked_content_reasons
    return false if reasons.empty?

    reasons.each { |reason| errors.add(:base, reason) }
    update_columns(status: "draft") if scheduled?
    true
  end

  # As Message: on every edit, and again on the way out.
  def check_blocked_content?
    will_save_change_to_body? || will_save_change_to_subject? ||
      (will_save_change_to_status? && (scheduled? || sending? || pending_review?))
  end

  private

  # A Message whose audience spans every target event, for counting and
  # sampling across them without a query per event.
  def audience_probe
    build_message.tap { |message| message.audience_event_ids = target_events.select(:id) }
  end

  def message_for(event)
    messages.find_by(event: event) || messages.create!(copy_attributes(event))
  rescue ActiveRecord::RecordNotUnique
    # Another run of the fan-out created it first.
    messages.find_by!(event: event)
  end

  def copy_attributes(event)
    build_message(event: event).attributes
      .slice("event_id", "subject", "body", "channels", "audience", "audience_filters", "sent_by_user_id", "status", "screened_digest")
  end

  def channels_are_valid
    invalid = channels.to_a - Message::CHANNELS.keys.map(&:to_s)
    errors.add(:channels, "contains invalid channels: #{invalid.join(", ")}") if invalid.any?
  end

  def selected_events_are_in_series
    return unless event_scope == "selected"

    if selected_event_ids.blank?
      errors.add(:selected_event_ids, "needs at least one event")
    elsif event_series && event_series.events.where(id: selected_event_ids).count != selected_event_ids.uniq.size
      errors.add(:selected_event_ids, "includes an event that isn't in this series")
    end
  end

  # Placeholders, unfinished uploads and the like are checked by Message
  # itself, on a copy, so the two can't drift apart. Blocked content is
  # ScreenedBroadcast's job here, so it isn't reported twice.
  def message_content_is_valid
    probe = build_message
    probe.validate
    blocked = probe.blocked_content_reasons
    probe.errors.each do |error|
      next unless error.attribute.in?(%i[base body subject])
      next if blocked.include?(error.message)

      errors.add(error.attribute, error.message)
    end
  end

  # An uploaded image is attached to the message it was uploaded for, so a
  # copy on another event couldn't show it: it would silently go missing.
  def has_no_images
    return unless body.to_s.include?("<img")
    return if Nokogiri::HTML5.fragment(body).css("img").empty?

    errors.add(:body, "can't include images in a series broadcast. Link to the image instead.")
  end
end
