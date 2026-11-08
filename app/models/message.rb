class Message < ApplicationRecord
  include EventLocalTimes
  include DecodableImageAttachment
  self.implicit_order_column = "created_at"

  has_paper_trail

  belongs_to :event
  belongs_to :sent_by_user, class_name: "User"
  has_many :message_deliveries, dependent: :destroy
  # Pictures in the body. Staff upload them from the editor before the message
  # is saved (see Admin::MessagesController#upload_image), and saving the body
  # attaches the ones it shows (see #attach_images_in_body).
  has_many_attached :images

  AUDIENCES = {
    all_attendees: "All Attendees",
    all_attendees_and_held: "All Attendees + Held Invitations",
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

  # Where each channel finds its address on a Participant or Guardian, and the
  # delivery column it is copied into. Push has no address: it needs an Expo
  # token on the participant's user (see #push_user_ids and #reachable).
  CHANNEL_FIELDS = {
    "email" => [ :email, :recipient_email ],
    "sms" => [ :phone, :recipient_phone ],
    "slack" => [ :slack_user_id, :recipient_slack_id ]
  }.freeze

  DELIVERY_INSERT_BATCH = 500

  # Tokens staff can write in a subject or body, filled in for each recipient
  # when the message is rendered for them (see #personalize).
  # participant_first_name names a guardian's children, so it only works for
  # guardian audiences.
  PLACEHOLDERS = %w[first_name participant_first_name event_name].freeze
  GUARDIAN_ONLY_PLACEHOLDERS = %w[participant_first_name].freeze
  PLACEHOLDER_PATTERN = /\{\{\s*(\w+)\s*\}\}/

  # What {{first_name}} and {{participant_first_name}} become when we have no
  # name to use, e.g. someone invited without one.
  FIRST_NAME_FALLBACK = "there"
  PARTICIPANT_FIRST_NAME_FALLBACK = "your child"

  IMAGE_CONTENT_TYPES = %w[image/jpeg image/png image/gif image/webp].freeze
  MAX_IMAGE_SIZE = 10.megabytes
  # Where an uploaded image is metadata-tagged with its event, so a body can
  # only show pictures staff uploaded for that event's messages.
  IMAGE_EVENT_KEY = "message_image_event_id"
  # The address the editor writes for an upload: Active Storage's blob route,
  # proxy or redirect depending on the environment, with or without a host.
  IMAGE_SRC_PATTERN = %r{\A(?:https?://[^/]+)?/rails/active_storage/blobs/(?:proxy|redirect)/([^/]+)/}
  # Recipients get a copy no wider than this, so a photo straight off a phone
  # isn't downloaded at full size by everyone the message goes to.
  IMAGE_VARIANT = { resize_to_limit: [ 1200, nil ] }.freeze
  # The email layout's content width, which is also the widest an image is
  # shown: Outlook ignores max-width, so the width attribute does the job.
  IMAGE_DISPLAY_WIDTH = 560

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
  # Only when the content or audience changes, so a status update on an older
  # message with stray braces in it can't start failing.
  validate :placeholders_are_valid,
    if: -> { will_save_change_to_body? || will_save_change_to_subject? || will_save_change_to_audience? }

  # Typed on the event's clock (see EventLocalTimes).
  event_local_times :scheduled_at

  after_save :attach_images_in_body, if: :saved_change_to_body?

  scope :recent, -> { order(created_at: :desc) }
  scope :pending_scheduled, -> { scheduled.where("scheduled_at <= ?", Time.current) }

  def local_scheduled_at
    local_time(:scheduled_at)
  end

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
      # Everyone who has at least opened the wizard, plus invitees who have
      # been told the event exists. Held invitations are deliberately excluded:
      # their recipient has not been contacted yet (see
      # ParticipantEvent#onboarding_held?), so broadcasting event detail to
      # them is precisely what the hold exists to prevent.
      event.participant_events
        .where(status: %w[in_progress awaiting_guardian complete])
        .or(event.participant_events.where(id: notified_invitee_ids))
    when :all_attendees_and_held
      # The same audience plus held invitees, for when staff decide a message
      # should reach people before their invitation has gone out.
      event.participant_events
        .where(status: %w[in_progress awaiting_guardian complete])
        .or(event.participant_events.where(id: notified_invitee_ids))
        .or(event.participant_events.where(id: held_invitee_ids))
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
    when :all_guardians, :guardians_of_confirmed, :guardians_pending
      Guardian.where(id: guardian_links.select(:guardian_id))
    else
      ParticipantEvent.none
    end
  end

  # Invited registrations whose invitation has actually gone out. Matched on
  # email rather than a foreign key because that is the only link between the
  # two — an Invitation belongs to an event and an address, not to a person.
  def notified_invitee_ids
    invitee_ids_with(Invitation.sent)
  end

  # Invited registrations whose invitation is still held (see Invitation.held).
  def held_invitee_ids
    invitee_ids_with(Invitation.held)
  end

  # `invitations` is an Invitation scope, correlated with each registration
  # as an EXISTS subquery.
  def invitee_ids_with(invitations)
    matching = invitations
      .where("invitations.event_id = participant_events.event_id")
      .where("LOWER(invitations.email) = LOWER(participants.email)")

    event.participant_events
      .invited
      .joins(:participant)
      .where(matching.arel.exists)
      .select(:id)
  end

  # The guardian-registration links a guardian audience covers, group filter
  # included: a guardian is in the audience through the children listed here,
  # which is also who {{participant_first_name}} names.
  def guardian_links
    links = GuardianParticipantEvent.joins(:participant_event).where(participant_events: { event_id: event_id })
    links = case audience.to_sym
    when :guardians_of_confirmed then links.where(participant_events: { status: "complete" })
    when :guardians_pending then links.where.not(status: "completed").or(links.where(status: nil))
    else links
    end

    group_ids = filter_group_ids
    return links if group_ids.empty?

    links.where(participant_event_id: GroupMembership.where(group_id: group_ids).select(:participant_event_id))
  end

  # Optional group filter applied on top of the base audience.
  # `attendees_in_groups` already filters by group, and guardian audiences
  # apply it in #guardian_links, so we skip those.
  def apply_group_filter(scope)
    return scope if audience.to_s == "attendees_in_groups" || guardian_audience?

    group_ids = filter_group_ids
    return scope if group_ids.empty?

    scope.where(id: GroupMembership.where(group_id: group_ids).select(:participant_event_id))
  end

  def filter_group_ids
    (audience_filters["group_ids"] || []).reject(&:blank?)
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

  # Everyone the audience matches now who has no delivery for this message on
  # any channel: people who joined the audience after it went out, plus anyone
  # who had no reachable channel at the time. Keyed on the person rather than
  # the channel, so someone who has since linked Slack isn't messaged twice.
  # Only people reachable on one of the message's channels count, so the
  # number staff see is the number a send would add.
  #
  # "Person" here means the registration (participant_event) or guardian, not
  # the human: a registration removed and re-created after the send carries no
  # deliveries (ParticipantEvent destroys them), so it counts as new and gets
  # the message again. That is the simplest rule that is correct for the data
  # we keep; matching on address instead would have nothing to match against.
  #
  # The nil filter matters: NOT IN against a subquery holding a NULL matches
  # nothing, and guardian deliveries have no participant_event_id.
  def new_recipients
    column = guardian_audience? ? :guardian_id : :participant_event_id
    reachable(recipients).where.not(id: message_deliveries.where.not(column => nil).select(column))
  end

  # First send of a draft or scheduled message. Returns false if it had
  # already gone out, e.g. a double-clicked Send Now.
  def send!
    sent = with_lock do
      next false unless draft? || scheduled?

      update!(status: :sending, sent_at: Time.current)
      create_deliveries_for(recipients)
      true
    end
    MessageDeliveryJob.perform_later(message_id: id) if sent
    sent
  end

  # A catch-up send only makes sense once the original send has gone out and
  # settled: not for drafts, not while the first batch is still draining.
  def can_send_to_new_recipients?
    sent_at.present? && (completed? || failed?)
  end

  # Sends an already-sent message to #new_recipients. Leaves status alone:
  # SingleDeliveryJob settles it once the new deliveries drain. Returns the
  # number of people added, 0 when there is nobody new or the message is not
  # in a state that allows it (checked under the row lock, so two staff
  # clicking at once can't both add the same people).
  def send_to_new_recipients!
    added, delivery_ids = with_lock do
      next [ 0, [] ] unless can_send_to_new_recipients?

      create_deliveries_for(new_recipients, catch_up: true)
    end
    MessageDeliveryJob.perform_later(message_id: id, delivery_ids: delivery_ids) if delivery_ids.any?
    added
  end

  def update_counts!
    update!(
      sent_count: message_deliveries.where(status: "delivered").count,
      failed_count: message_deliveries.where(status: "failed").count
    )
  end

  # The rendering methods take the person the message is going to (a
  # Participant or Guardian) and fill in its placeholders for them. Without
  # one the tokens are left as written, which is what staff see on the
  # message's own page.
  # `images_as_links` shows each image as a link to it, the way Slack gets it,
  # for the Slack preview.
  def body_as_html(recipient: nil, images_as_links: false)
    # Sanitized after filling in, so nothing a recipient put in their name can
    # survive as markup.
    html = sanitize_html(personalize(body.to_s, recipient) { |value| ERB::Util.html_escape(value) })
    with_image_urls(html, as_links: images_as_links)
  end

  def body_as_slack(recipient: nil)
    personalize(html_to_slack_markdown(body.to_s), recipient) { |value| InlineMarkup.escape(value) }
  end

  # Plain text for SMS, push and the text part of emails. Parsing the body
  # (rather than strip_tags + CGI.unescapeHTML) decodes every entity the editor
  # writes, including named ones like &nbsp; and &hellip;, so "Q&A" doesn't go
  # out as "Q&amp;A" and a double space doesn't go out as "&nbsp;".
  #
  # Keeps the structure organizers wrote — paragraphs, line breaks and list
  # bullets — instead of flattening everything onto one line.
  def body_as_plain(recipient: nil)
    personalize(html_to_plain(body.to_s), recipient)
  end

  def subject_for(recipient)
    personalize(subject.to_s, recipient).presence
  end

  # The person behind one of #recipients (a Participant or Guardian), which is
  # what the rendering methods take.
  def person_for(audience_member)
    guardian_audience? ? audience_member : audience_member&.participant
  end

  # Whether rendering for a recipient changes anything: only the tokens
  # #personalize knows count, so an unknown {{token}} on an old message
  # doesn't claim the text was filled in.
  def uses_placeholders?
    placeholder_tokens.intersect?(PLACEHOLDERS)
  end

  # The resized copy of an uploaded image recipients get, or nil to send the
  # original. GIFs go as they are, since a variant would lose the animation.
  def self.image_variant(blob)
    blob.variant(IMAGE_VARIANT) if blob.variable? && blob.content_type != "image/gif"
  end

  # Why `upload` can't go in a message body, or nil when it can. Run on a
  # throwaway message before the file is stored, the way onboarding checks a
  # staged headshot.
  def image_upload_error(upload)
    return "Choose a JPEG, PNG, GIF, or WebP image." unless upload.content_type.in?(IMAGE_CONTENT_TYPES)
    return "Images must be less than 10MB." if upload.size > MAX_IMAGE_SIZE

    "That image could not be read. Please re-save it as a JPEG, PNG, or WebP and upload it again." unless decodable_image?(upload)
  end

  def reload(...)
    @placeholder_values = nil
    @image_blobs = nil
    super
  end

  private

  # Creates a pending delivery per reachable channel for everyone in `scope`,
  # in batches so a large audience doesn't hold the message lock for one
  # validated INSERT per row. Returns [people_added, delivery_ids] so callers
  # can enqueue exactly the rows they created. Every row carries a
  # participant_event or guardian (the scope is one or the other) and an
  # address or push target the channel can use, which is what
  # MessageDelivery's validations would otherwise check.
  def create_deliveries_for(scope, catch_up: false)
    scope = scope.preload(:participant) unless guardian_audience?
    push_users = push_user_ids(scope)
    now = Time.current
    added = 0
    delivery_ids = []
    rows = []

    flush = lambda do
      next if rows.empty?

      result = MessageDelivery.insert_all(rows, returning: [ :id ])
      delivery_ids.concat(result.map { |row| row["id"] })
      rows.clear
    end

    scope.find_each do |recipient|
      reachable = channels.select { |channel| deliverable?(recipient, channel, push_users) }
      next if reachable.empty?

      attributes = delivery_attributes(recipient).merge(
        message_id: id, status: "pending", catch_up: catch_up, created_at: now, updated_at: now
      )
      reachable.each { |channel| rows << attributes.merge(channel: channel) }
      added += 1
      flush.call if rows.size >= DELIVERY_INSERT_BATCH
    end
    flush.call

    update!(recipient_count: message_deliveries.distinct.count(Arel.sql("COALESCE(participant_event_id, guardian_id)")))
    [ added, delivery_ids ]
  end

  # Copies every address we have onto the delivery, not just the one its
  # channel uses, so the delivery row stands on its own in the admin UI.
  def delivery_attributes(recipient)
    if guardian_audience?
      { guardian_id: recipient.id, recipient_email: recipient.email, recipient_phone: recipient.phone }
    else
      participant = recipient.participant
      { participant_event_id: recipient.id }.merge(
        CHANNEL_FIELDS.to_h { |_channel, (source, column)| [ column, participant.public_send(source) ] }
      )
    end
  end

  # Channels this audience can be reached on. Guardians have no Slack link or
  # app account, so they only get email and SMS.
  def channel_fields
    guardian_audience? ? CHANNEL_FIELDS.slice("email", "sms") : CHANNEL_FIELDS
  end

  # Users in `scope` with a device that can take a push, computed once per
  # send so #deliverable? doesn't query per recipient.
  def push_user_ids(scope)
    return Set.new if guardian_audience? || channels.exclude?("push")

    participants = Participant.where(id: scope.select(:participant_id))
    PushToken.expo_tokens.where(user_id: participants.select(:user_id)).distinct.pluck(:user_id).to_set
  end

  # Whether `recipient` can get this message on `channel`. The SQL counterpart
  # is #reachable; both read CHANNEL_FIELDS, so a new channel goes there.
  def deliverable?(recipient, channel, push_users)
    owner = guardian_audience? ? recipient : recipient.participant
    if channel.to_s == "push"
      !guardian_audience? && push_users.include?(owner.user_id)
    elsif (source, _column = channel_fields[channel.to_s])
      owner.public_send(source).present?
    else
      false
    end
  end

  # SQL counterpart of #deliverable?. Built as subqueries on Participant and
  # Guardian so the deterministic encryption on phone can rewrite the
  # blank-string comparison.
  def reachable(scope)
    owner = guardian_audience? ? Guardian : Participant
    conditions = channels.filter_map do |channel|
      if channel.to_s == "push"
        owner.where(user_id: PushToken.expo_tokens.select(:user_id)) unless guardian_audience?
      elsif (source, _column = channel_fields[channel.to_s])
        owner.where.not(source => [ nil, "" ])
      end
    end
    return scope.none if conditions.empty?

    reachable_ids = conditions.reduce(:or).select(:id)
    guardian_audience? ? scope.where(id: reachable_ids) : scope.where(participant_id: reachable_ids)
  end

  def html_to_plain(html)
    return "" if html.blank?

    text = convert_node_to_plain(Nokogiri::HTML5.fragment(html))
    # Collapsed source whitespace between block tags leaves a single stray
    # space at line starts; nested-list indents are two spaces, so they stay.
    text.lines.map { |line| line.rstrip.sub(/\A (?=\S)/, "") }.join("\n")
        .gsub(/\n{3,}/, "\n\n").strip
  end

  def convert_node_to_plain(node, depth: 0, preformatted: false)
    node.children.map do |child|
      if child.text?
        preformatted ? child.text : child.text.gsub(/[[:space:]]+/, " ")
      elsif child.element?
        convert_element_to_plain(child, depth: depth, preformatted: preformatted)
      else
        ""
      end
    end.join
  end

  def convert_element_to_plain(element, depth:, preformatted:)
    case element.name.downcase
    when "br"
      "\n"
    when "p", "div", "blockquote", "h1", "h2", "h3", "h4"
      "\n\n#{convert_node_to_plain(element, depth: depth).strip}\n\n"
    when "pre"
      "\n\n#{convert_node_to_plain(element, depth: depth, preformatted: true).strip}\n\n"
    when "ul", "ol"
      convert_list_to_plain(element, ordered: element.name.downcase == "ol", depth: depth)
    when "a"
      label = convert_node_to_plain(element, depth: depth, preformatted: preformatted).strip
      href = element["href"].to_s.strip
      if href.blank? || label == href || label == href.delete_prefix("mailto:")
        label.presence || href
      else
        "#{label} (#{href})"
      end
    else
      convert_node_to_plain(element, depth: depth, preformatted: preformatted)
    end
  end

  def convert_list_to_plain(list, ordered:, depth:)
    indent = "  " * depth
    items = list.element_children.select { |c| c.name.downcase == "li" }
    lines = items.each_with_index.map do |item, index|
      marker = ordered ? "#{index + 1}." : "•"
      content = convert_node_to_plain(item, depth: depth + 1).strip.gsub(/\n{2,}/, "\n")
      "#{indent}#{marker} #{content}"
    end

    depth.zero? ? "\n\n#{lines.join("\n")}\n\n" : "\n#{lines.join("\n")}"
  end

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
    when "img"
      url = image_url(element["src"])
      url ? "<#{url}|#{element["alt"].presence || "Image"}>\n" : ""
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
      tags: %w[p br strong b em i u s strike a ul ol li blockquote code pre img],
      attributes: %w[href target src alt]
    )
  end

  # Points each <img> at the copy recipients should load, sized for email, and
  # drops any that isn't one of this message's uploads: a link to an outside
  # image (a tracking pixel, say) or to some other record's file.
  def with_image_urls(html, as_links: false)
    return html unless html.include?("<img")

    doc = Nokogiri::HTML5.fragment(html)
    doc.css("img").each do |img|
      blob = image_blob_for(img["src"])
      next img.remove unless blob

      if as_links
        link = doc.document.create_element("a", img["alt"].presence || "Image", href: blob_image_url(blob), target: "_blank")
        next img.replace(link)
      end

      img["src"] = blob_image_url(blob)
      img["alt"] ||= ""
      width = blob.metadata["width"]
      img["width"] = [ width, IMAGE_DISPLAY_WIDTH ].min.to_s if width
      img["style"] = "max-width: 100%; height: auto;"
    end
    doc.to_html.html_safe
  end

  # The absolute address recipients load an image in the body from, or nil
  # when `src` isn't one of this message's uploads.
  def image_url(src)
    blob = image_blob_for(src)
    blob_image_url(blob) if blob
  end

  def blob_image_url(blob)
    helpers = Rails.application.routes.url_helpers
    options = Rails.application.config.action_mailer.default_url_options
    variant = self.class.image_variant(blob)
    variant ? helpers.rails_representation_url(variant, **options) : helpers.rails_blob_url(blob, **options)
  end

  def image_blob_for(src)
    signed_id = src.to_s[IMAGE_SRC_PATTERN, 1]
    return unless signed_id

    @image_blobs ||= images.blobs.index_by(&:id)
    blob = ActiveStorage::Blob.find_signed(Rack::Utils.unescape_path(signed_id))
    @image_blobs[blob.id] if blob
  end

  # Attaches every upload the body shows that isn't attached yet. Only images
  # uploaded for this event count, so pasting the address of some other file
  # (a participant's headshot, say) can't pull it into a message. Images taken
  # back out of a draft stay attached until the message is deleted.
  def attach_images_in_body
    srcs = Nokogiri::HTML5.fragment(body.to_s).css("img").filter_map { |img| img["src"] }
    signed_ids = srcs.filter_map { |src| src[IMAGE_SRC_PATTERN, 1] }.uniq
    return if signed_ids.empty?

    attached = images_attachments.pluck(:blob_id)
    signed_ids.each do |signed_id|
      blob = ActiveStorage::Blob.find_signed(Rack::Utils.unescape_path(signed_id))
      next unless blob && blob.metadata[IMAGE_EVENT_KEY] == event_id
      next if attached.include?(blob.id)

      images_attachments.create!(blob: blob)
      attached << blob.id
    end
    @image_blobs = nil
  end

  # Replaces each known placeholder in `text` with its value for `recipient`,
  # passed through the block when the output format needs escaping. Unknown
  # tokens, and every token when there is no recipient, are left untouched.
  def personalize(text, recipient)
    text = String.new(text.to_s)
    return text if recipient.nil?

    values = placeholder_values_for(recipient)
    text.gsub(PLACEHOLDER_PATTERN) do |token|
      name = Regexp.last_match(1)
      next token unless PLACEHOLDERS.include?(name)

      block_given? ? yield(values[name]) : values[name]
    end
  end

  # Values are computed on first use and kept per recipient, since one email
  # renders the subject, HTML and text parts and a guardian's children's
  # names take a query.
  # The audience is part of the key because {{participant_first_name}} names
  # the children who matched it, which changes if the audience is edited on
  # the same instance before it's rendered again.
  def placeholder_values_for(recipient)
    @placeholder_values ||= {}
    @placeholder_values[[ recipient.class.name, recipient.id, event_id, audience, audience_filters ]] ||=
      Hash.new { |hash, name| hash[name] = placeholder_value(name, recipient).to_s }
  end

  def placeholder_value(name, recipient)
    case name
    when "first_name"
      first_name_for(recipient) || FIRST_NAME_FALLBACK
    when "participant_first_name"
      participant_first_names_for(recipient) || PARTICIPANT_FIRST_NAME_FALLBACK
    when "event_name"
      event.name
    end
  end

  def first_name_for(recipient)
    recipient.is_a?(Guardian) ? recipient.legal_first_name.presence : recipient.greeting_name
  end

  # The children who put this guardian in the audience, as "Alex and Sam".
  # Falls back to all their children at the event, since a message viewed or
  # re-sent later may no longer match how the audience looked at send time.
  def participant_first_names_for(recipient)
    # A participant reading a message meant for guardians is still addressed
    # as themselves, never as "your child".
    return first_name_for(recipient) || FIRST_NAME_FALLBACK unless recipient.is_a?(Guardian)

    all_links = GuardianParticipantEvent.joins(:participant_event)
      .where(guardian: recipient, participant_events: { event_id: event_id })
    [ guardian_links.where(guardian: recipient), all_links ].each do |links|
      names = links.includes(participant_event: :participant).order("participant_events.created_at")
        .filter_map { |link| link.participant_event.participant.greeting_name }.uniq
      return names.to_sentence if names.any?
    end
    nil
  end

  def placeholder_tokens
    [ subject, body ].flat_map { |text| text.to_s.scan(PLACEHOLDER_PATTERN).flatten }.uniq
  end

  def placeholders_are_valid
    tokens = placeholder_tokens
    # Most saves (every autosave keystroke) have no tokens at all, so skip
    # parsing the body for them.
    return if tokens.empty?

    unknown = tokens - PLACEHOLDERS
    if unknown.any?
      errors.add(:base, "Unknown placeholder #{unknown.map { |t| "{{#{t}}}" }.to_sentence}. " \
        "Available: #{PLACEHOLDERS.map { |t| "{{#{t}}}" }.join(", ")}.")
    end

    # A name isn't a safe or valid URL, so placeholders only go in text.
    in_attribute = Nokogiri::HTML.fragment(body.to_s).xpath(".//@*").any? { |attr| attr.value.match?(PLACEHOLDER_PATTERN) }
    errors.add(:base, "Placeholders can't go inside a link's address.") if in_attribute

    guardian_only = tokens & GUARDIAN_ONLY_PLACEHOLDERS
    if guardian_only.any? && !guardian_audience?
      errors.add(:base, "#{guardian_only.map { |t| "{{#{t}}}" }.to_sentence} only works when sending to guardians.")
    end
  end

  def channels_are_valid
    return if channels.blank?

    invalid = channels - CHANNELS.keys.map(&:to_s)
    if invalid.any?
      errors.add(:channels, "contains invalid channels: #{invalid.join(", ")}")
    end
  end
end
