class Message < ApplicationRecord
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :sent_by_user, class_name: "User"
  has_many :message_deliveries, dependent: :destroy

  AUDIENCES = {
    all_attendees: "All Attendees",
    confirmed_attendees: "Confirmed Attendees",
    attendees_with_flights: "Attendees with Flights",
    attendees_incomplete: "Incomplete Onboarding",
    specific_participants: "Specific Participants",
    attendees_in_groups: "Attendees in Groups",
    all_guardians: "All Guardians",
    guardians_of_confirmed: "Guardians of Confirmed Attendees",
    guardians_pending: "Guardians with Pending Tasks"
  }.freeze

  CHANNELS = {
    slack: "Slack DM",
    email: "Email",
    sms: "SMS (Twilio)",
    push: "App Push"
  }.freeze

  enum :status, {
    draft: "draft",
    scheduled: "scheduled",
    sending: "sending",
    completed: "completed",
    failed: "failed",
    cancelled: "cancelled"
  }

  validates :audience, presence: true
  validates :channels, presence: true
  validate :channels_are_valid

  scope :recent, -> { order(created_at: :desc) }
  scope :pending_scheduled, -> { scheduled.where("scheduled_at <= ?", Time.current) }

  def audience_label
    AUDIENCES[audience.to_sym] || audience.titleize
  end

  def channel_labels
    channels.map { |c| CHANNELS[c.to_sym] || c.titleize }.join(", ")
  end

  def recipients
    base = base_recipients
    apply_group_filter(base)
  end

  def base_recipients
    case audience.to_sym
    when :all_attendees
      event.participant_events.where(status: %w[in_progress awaiting_guardian complete])
    when :confirmed_attendees
      event.participant_events.complete
    when :attendees_with_flights
      event.participant_events.complete
        .joins("INNER JOIN travels ON travels.participant_event_id = participant_events.id")
        .joins("INNER JOIN travel_legs ON travel_legs.travel_id = travels.id")
        .distinct
    when :attendees_incomplete
      event.participant_events.where(status: %w[invited in_progress awaiting_guardian])
    when :specific_participants
      ids = audience_filters["participant_event_ids"] || []
      event.participant_events.where(id: ids)
    when :attendees_in_groups
      group_ids = audience_filters["group_ids"] || []
      return ParticipantEvent.none if group_ids.empty?
      event.participant_events
        .where(status: %w[in_progress awaiting_guardian complete])
        .joins(:group_memberships)
        .where(group_memberships: { group_id: group_ids })
        .distinct
    when :all_guardians
      Guardian.joins(guardian_participant_events: :participant_event)
        .where(participant_events: { event_id: event.id })
        .distinct
    when :guardians_of_confirmed
      Guardian.joins(guardian_participant_events: :participant_event)
        .where(participant_events: { event_id: event.id, status: "complete" })
        .distinct
    when :guardians_pending
      Guardian.joins(:guardian_participant_events)
        .joins("INNER JOIN participant_events ON guardian_participant_events.participant_event_id = participant_events.id")
        .where(participant_events: { event_id: event.id })
        .where.not(guardian_participant_events: { status: "complete" })
        .distinct
    else
      ParticipantEvent.none
    end
  end

  # Optional group filter applied on top of the base audience.
  # `attendees_in_groups` already filters by group, so we skip there.
  def apply_group_filter(scope)
    return scope if audience.to_s == "attendees_in_groups"

    group_ids = (audience_filters["group_ids"] || []).reject(&:blank?)
    return scope if group_ids.empty?

    member_pe_ids = GroupMembership.where(group_id: group_ids).select(:participant_event_id)

    if guardian_audience?
      scope.joins(:guardian_participant_events)
           .where(guardian_participant_events: { participant_event_id: member_pe_ids })
           .distinct
    else
      scope.where(id: member_pe_ids)
    end
  end

  def guardian_audience?
    audience.to_s.in?(%w[all_guardians guardians_of_confirmed guardians_pending])
  end

  def preview_recipients(limit: 10)
    recipients.limit(limit)
  end

  def recipient_count_estimate
    recipients.count
  end

  def update_counts!
    update!(
      sent_count: message_deliveries.where(status: "delivered").count,
      failed_count: message_deliveries.where(status: "failed").count
    )
  end

  def body_as_html
    sanitize_html(body.to_s)
  end

  def body_as_slack
    html_to_slack_markdown(body.to_s)
  end

  def body_as_slack_preview_html
    sanitize_html(body.to_s)
  end

  def body_as_plain
    ActionController::Base.helpers.strip_tags(body.to_s).gsub(/\s+/, " ").strip
  end

  private

  def html_to_slack_markdown(html)
    return "" if html.blank?

    doc = Nokogiri::HTML.fragment(html)
    convert_node_to_slack(doc).strip
  end

  def convert_node_to_slack(node)
    result = ""

    node.children.each do |child|
      case child.type
      when Nokogiri::XML::Node::TEXT_NODE
        result += child.text
      when Nokogiri::XML::Node::ELEMENT_NODE
        result += convert_element_to_slack(child)
      end
    end

    result
  end

  def convert_element_to_slack(element)
    inner = convert_node_to_slack(element)

    case element.name.downcase
    when "strong", "b"
      "*#{inner.strip}*"
    when "em", "i"
      "_#{inner.strip}_"
    when "s", "strike", "del"
      "~#{inner.strip}~"
    when "code"
      "`#{inner.strip}`"
    when "pre"
      "```\n#{inner.strip}\n```"
    when "a"
      href = element["href"]
      if href.present?
        "<#{href}|#{inner.strip}>"
      else
        inner
      end
    when "br"
      "\n"
    when "p"
      "#{inner.strip}\n\n"
    when "ul"
      convert_list_to_slack(element, ordered: false)
    when "ol"
      convert_list_to_slack(element, ordered: true)
    when "li"
      inner
    when "blockquote"
      inner.strip.lines.map { |line| "> #{line}" }.join
    else
      inner
    end
  end

  def convert_list_to_slack(list_element, ordered:)
    result = ""
    index = 1

    list_element.children.each do |child|
      next unless child.element? && child.name.downcase == "li"

      inner = convert_node_to_slack(child).strip
      if ordered
        result += "#{index}. #{inner}\n"
        index += 1
      else
        result += "• #{inner}\n"
      end
    end

    result + "\n"
  end

  def sanitize_html(html)
    ActionController::Base.helpers.sanitize(
      html,
      tags: %w[p br strong b em i u s strike a ul ol li blockquote code pre],
      attributes: %w[href target]
    )
  end

  def channels_are_valid
    return if channels.blank?

    invalid = channels - CHANNELS.keys.map(&:to_s)
    if invalid.any?
      errors.add(:channels, "contains invalid channels: #{invalid.join(", ")}")
    end
  end
end
