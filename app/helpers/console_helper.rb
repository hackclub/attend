# Helpers for the admin console, the Cloudscape-based /admin shell. Styles
# live in app/assets/stylesheets/console.css.
module ConsoleHelper
  # The console has Cloudscape's two modes rather than the nine app themes.
  # Light-ground themes land on light, everything else on dark.
  LIGHT_THEMES = %w[light catppuccin-latte].freeze

  CONSOLE_THEME_COLOR = "#0f141a".freeze

  STATUS_ICONS = {
    success: '<circle cx="8" cy="8" r="7"/><path d="M4.5 8.2l2.3 2.3 4.7-4.9"/>',
    error: '<circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5m0-5l-5 5"/>',
    warning: '<path d="M8 1.5l7 12.5H1z"/><path d="M8 6v4m0 1.8v.2"/>',
    info: '<circle cx="8" cy="8" r="7"/><path d="M8 7v4.5m0-6.8v.3"/>',
    pending: '<circle cx="8" cy="8" r="7"/><path d="M8 4.5V8l2.5 1.8"/>',
    in_progress: '<circle cx="8" cy="8" r="7" stroke-dasharray="3 2.5"/><circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none"/>',
    stopped: '<circle cx="8" cy="8" r="7"/><path d="M5 8h6"/>'
  }.freeze

  # True when this request renders the +console template variant. Helpers
  # shared by both admin UIs branch on it, so the original templates keep
  # their Tailwind markup and the console gets cs-* markup.
  def console_ui?
    respond_to?(:request) && request.present? && Array(request.variant).include?(:console)
  end

  SYSTEM_THEME = "system".freeze

  # The console's theme setting: "light", "dark" or "system". Any of the
  # nine app themes collapses to light or dark; "system" follows the OS.
  def admin_console_theme_mode
    raw = (current_user.respond_to?(:theme) && current_user&.theme.presence) || cookies[:attend_theme].presence
    return SYSTEM_THEME if raw == SYSTEM_THEME

    LIGHT_THEMES.include?(current_theme) ? "light" : "dark"
  end

  # What the server renders into data-theme. "system" can only be resolved
  # in the browser, so it renders light and the layout's pre-paint script
  # switches to dark when the OS asks for it.
  def admin_console_theme
    mode = admin_console_theme_mode
    mode == SYSTEM_THEME ? "light" : mode
  end

  # Cloudscape's status indicator: an icon plus a coloured word. The word
  # always carries the meaning; the colour and icon only reinforce it.
  def cs_status(type, label)
    type = type.to_s.to_sym
    type = :info unless STATUS_ICONS.key?(type)
    content_tag(:span, class: "cs-status cs-status-#{type.to_s.dasherize}") do
      cs_status_icon(type) + content_tag(:span, label)
    end
  end

  def cs_status_icon(type)
    content_tag(:svg, STATUS_ICONS.fetch(type.to_sym).html_safe,
      viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
      "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
      "aria-hidden": "true")
  end

  def cs_badge(label, color = nil)
    classes = [ "cs-badge" ]
    classes << "cs-badge-#{color}" if color
    content_tag(:span, label, class: classes.join(" "))
  end

  # Cloudscape's breadcrumb group. Pass [label, path] pairs; the last one is
  # the current page and renders as text.
  #   content_for :breadcrumbs, cs_breadcrumbs([ "Events", admin_root_path ], [ @event.name, nil ])
  def cs_breadcrumbs(*crumbs)
    content_tag(:nav, "aria-label": "Breadcrumbs") do
      content_tag(:ol, class: "cs-breadcrumb-group") do
        safe_join(crumbs.each_with_index.map do |(label, path), index|
          last = index == crumbs.size - 1
          content_tag(:li) do
            if last || path.nil?
              content_tag(:span, label, "aria-current": ("page" if last))
            else
              link_to(label, path)
            end
          end
        end)
      end
    end
  end

  # The trail for any page under an event: Events › {event} › *crumbs.
  # `event_name` lets a form page keep the saved name while an edit is invalid.
  #   content_for :breadcrumbs, cs_event_breadcrumbs([ "Incidents", admin_event_incidents_path(current_event) ], [ "New incident", nil ])
  def cs_event_breadcrumbs(*crumbs, event: current_event, event_name: event.name, event_slug: event.slug)
    cs_breadcrumbs([ "Events", admin_root_path ], [ event_name, admin_event_dashboard_path(event_slug) ], *crumbs)
  end

  # A crumb whose target is policy-gated: links only when the viewer passes
  # the gate, otherwise it renders as plain text so it never dead-ends.
  def cs_gated_crumb(label, path, allowed)
    [ label, (path if allowed) ]
  end

  # Cloudscape severity badge for incidents and other graded things.
  SEVERITY_BADGES = %w[critical high medium low neutral].freeze

  def cs_severity_badge(severity, label = nil)
    level = SEVERITY_BADGES.include?(severity.to_s) ? severity.to_s : "neutral"
    content_tag(:span, label || severity.to_s.humanize, class: "cs-badge cs-badge-severity-#{level}")
  end

  # aria-current for side navigation links, so the active state is exposed
  # to assistive tech rather than drawn in colour alone.
  def cs_current(active)
    active ? "page" : nil
  end

  # Cloudscape filter tokens: one dismissible token per applied filter, the
  # fixed "and"/"or" operation between them, and a "Clear filters" link
  # button after the last one. `tokens` is a list of hashes with :label (the
  # property, e.g. "Status"), :operator (e.g. "="), :value and :remove_href.
  # Removing a token is a plain link to the same page without that filter,
  # so the tokens work with or without JavaScript.
  def cs_filter_tokens(tokens, clear_href:, operation: "and", **options)
    return "".html_safe if tokens.empty?

    content_tag(:div, class: "cs-filter-tokens", **options) do
      list = content_tag(:ul, class: "cs-token-group", "aria-label": "Applied filters") do
        safe_join(tokens.each_with_index.map do |token, index|
          text = [ token[:label], token[:operator], token[:value] ].compact.join(" ")
          content_tag(:li, class: "cs-filter-token-item") do
            operation_tag = index.zero? ? "".html_safe : content_tag(:span, operation, class: "cs-filter-operation")
            operation_tag + content_tag(:span, class: "cs-token") do
              content_tag(:span, class: "cs-filter-token-text", title: text) do
                safe_join([ token[:label], " ", content_tag(:span, token[:operator], class: "cs-filter-token-operator"), (" " if token[:value]), (content_tag(:strong, token[:value]) if token[:value]) ].compact)
              end +
                link_to(token[:remove_href], "aria-label": "Remove filter #{text}", data: { cs_property_filter_remove: true }) do
                  '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>'.html_safe
                end
            end
          end
        end)
      end
      list + link_to("Clear filters", clear_href, class: "cs-btn cs-btn-link cs-filter-clear")
    end
  end

  # Cloudscape's count text for a filtered collection: "1 match", "12 matches".
  def cs_match_count(count)
    "#{count} #{count == 1 ? "match" : "matches"}"
  end

  # Cloudscape's no-match empty state, shown when filters leave nothing.
  def cs_no_match(clear_href: nil, **options)
    content_tag(:div, class: "cs-empty", **options) do
      button = if clear_href
        link_to("Clear filters", clear_href, class: "cs-btn")
      end
      safe_join([
        content_tag(:p, "No matches", class: "cs-empty-title"),
        content_tag(:p, "We can't find a match."),
        (content_tag(:div, button, class: "cs-actions") if button)
      ].compact)
    end
  end

  # Cloudscape timestamps (cloudscape.design/patterns/general/timestamps).
  #
  # Relative ("36 minutes ago", "In 2 days") for events where recency
  # matters, wrapped in <time> so hovering reveals the absolute time.
  # Absolute ("January 31, 2010, 14:32 (UTC+3:30)") where people need the
  # exact moment: schedules, event dates, travel, deadlines. ISO 8601 only
  # for code-level values.

  # Unit thresholds, in order: each unit is used while its whole count stays
  # within the upper bound, then the next takes over. Months and years are
  # counted on the calendar, so "12 months ago" is the same date last year.
  CS_RELATIVE_UNITS = [
    [ "minute", 1.minute.to_i, 59 ],
    [ "hour", 1.hour.to_i, 24 ],
    [ "day", 1.day.to_i, 31 ],
    [ "week", 1.week.to_i, 4 ]
  ].freeze

  # "Now", "1 minute ago", "In 3 hours", "2 years ago". Nil for nil.
  # `inline: true` lowercases the lead word for use mid-sentence
  # ("starts in 3 days", "updated now").
  def cs_relative_time_text(time, now: Time.current, inline: false)
    return nil if time.nil?

    time = cs_time_value(time)
    delta = (time - now).to_f
    seconds = delta.abs
    return inline ? "now" : "Now" if seconds < 60

    unit, count = CS_RELATIVE_UNITS.lazy
      .map { |name, size, max| [ name, (seconds / size).floor, max ] }
      .find { |_name, amount, max| amount <= max }
    if unit.nil?
      months = cs_calendar_months_between(*[ time, now.in_time_zone ].sort)
      unit, count = months <= 12 ? [ "month", months ] : [ "year", months / 12 ]
    end

    phrase = "#{count} #{count == 1 ? unit : unit.pluralize}"
    return "#{phrase} ago" if delta.negative?

    inline ? "in #{phrase}" : "In #{phrase}"
  end

  # The relative timestamp as markup: <time datetime="ISO 8601"
  # title="absolute">36 minutes ago</time>. The pattern puts the absolute
  # string in both attributes; datetime keeps a machine-readable ISO value
  # instead so the element stays valid HTML, and title carries the
  # human-readable absolute time that hover reveals.
  def cs_relative_time(time, now: Time.current, zone: nil, inline: false, **options)
    return nil if time.nil?

    content_tag(:time, cs_relative_time_text(time, now: now, inline: inline),
      datetime: cs_iso_time(time, zone: zone),
      title: cs_absolute_time(time, zone: zone),
      **options)
  end

  # "January 31, 2010, 14:32 (UTC+3:30)", or "January 31, 2010" with
  # date_only (or for a Date). `zone` is the time zone to show it in; nil
  # keeps the app's zone.
  def cs_absolute_time(time, zone: nil, date_only: false)
    return nil if time.nil?
    return cs_absolute_date(time) if cs_plain_date?(time)
    return cs_absolute_date(cs_time_value(time, zone: zone)) if date_only

    local = cs_time_value(time, zone: zone)
    "#{cs_absolute_date(local)}, #{local.strftime("%H:%M")} (#{cs_utc_offset(local)})"
  end

  # The absolute timestamp in a <time> element with an ISO 8601 datetime.
  def cs_absolute_time_tag(time, zone: nil, date_only: false, **options)
    return nil if time.nil?

    datetime = date_only || cs_plain_date?(time) ? time.to_date.iso8601 : cs_iso_time(time, zone: zone)
    content_tag(:time, cs_absolute_time(time, zone: zone, date_only: date_only), datetime: datetime, **options)
  end

  # "2010-01-31T14:32:35+03:00", for code-level values.
  def cs_iso_time(time, zone: nil)
    return nil if time.nil?
    return time.iso8601 if cs_plain_date?(time)

    cs_time_value(time, zone: zone).iso8601
  end

  # "UTC+3:30", "UTC-5:00", "UTC+0:00".
  def cs_utc_offset(time)
    offset = time.utc_offset
    sign = offset.negative? ? "-" : "+"
    hours, minutes = offset.abs.divmod(3600)
    format("UTC%s%d:%02d", sign, hours, minutes / 60)
  end

  # A date range with full month names: "October 10, 2026",
  # "October 10 – 17, 2026", "October 30 – November 2, 2026",
  # "December 30, 2026 – January 2, 2027". The console's counterpart to
  # event_date_range, which keeps abbreviated months for the original UI.
  def cs_date_range(starts_at, ends_at, zone: nil)
    start_date = starts_at && cs_local_date(starts_at, zone)
    end_date = ends_at && cs_local_date(ends_at, zone)

    return "Dates not set" if start_date.nil? && end_date.nil?
    return "Ends #{cs_absolute_date(end_date)}" if start_date.nil?
    return cs_absolute_date(start_date) if end_date.nil? || start_date == end_date

    if start_date.year != end_date.year
      "#{cs_absolute_date(start_date)} – #{cs_absolute_date(end_date)}"
    elsif start_date.month == end_date.month
      "#{start_date.strftime("%B %-d")} – #{end_date.strftime("%-d, %Y")}"
    else
      "#{start_date.strftime("%B %-d")} – #{cs_absolute_date(end_date)}"
    end
  end

  # Internals for the timestamp helpers above.
  def cs_absolute_date(time)
    time.strftime("%B %-d, %Y")
  end

  def cs_local_date(time, zone)
    return time if cs_plain_date?(time)

    cs_time_value(time, zone: zone).to_date
  end

  def cs_calendar_months_between(earlier, later)
    months = (later.year * 12 + later.month) - (earlier.year * 12 + earlier.month)
    months -= 1 if later < earlier.advance(months: months)
    [ months, 1 ].max
  end

  def cs_plain_date?(time)
    time.is_a?(Date) && !time.is_a?(DateTime)
  end

  def cs_time_value(time, zone: nil)
    time = time.in_time_zone if cs_plain_date?(time)
    time = Time.zone.parse(time) if time.is_a?(String)
    zone ? time.in_time_zone(zone) : time.in_time_zone
  end

  # ---------------------------------------------------------------------------
  # Forms (cloudscape.design/patterns/general/errors/validation)
  #
  # cs_form_field renders one Cloudscape form field: label (with a lighter
  # "- optional" marker), description, the control, the server-side error
  # for that attribute, and constraint text. It hands the block the aria
  # attributes the control needs (aria-invalid, aria-describedby):
  #
  #   <%= cs_form_field f, :slug, constraint: "Lowercase letters, numbers and hyphens (-) only." do |aria| %>
  #     <%= f.text_field :slug, class: "cs-input", pattern: "[a-z0-9-]+", **aria %>
  #   <% end %>
  #
  # Without a block it renders `as:` (a FormBuilder method, text_field by
  # default) with `input:` options. Model errors become Cloudscape wording
  # ("Name is required.", "This slug is already in use."); `messages:` maps an
  # error type (:blank, :taken, :invalid, ...) to replacement text, with
  # %{label}, %{thing} (the label mid-sentence), %{count} and %{length}.
  #
  # Every attribute rendered this way is remembered, so cs_form_errors(f) at
  # the end of the form shows only the errors no field claimed. Pair the form
  # with `novalidate: true, data: { controller: "cs-form-validation" }` for
  # the client-side timing (blur, then every keypress while in error, submit).
  # ---------------------------------------------------------------------------

  CS_ERROR_TEMPLATES = {
    blank: "%{label} is required.",
    required: "%{label} is required.",
    empty: "%{label} is required.",
    taken: "This %{thing} is already in use.",
    invalid: "Enter a valid %{thing}.",
    too_long: "The %{thing} has too many characters. Character count: %{length}/%{count}.",
    too_short: "The %{thing} has too few characters. Character count: %{length}/%{count}.",
    inclusion: "Select a valid %{thing}.",
    exclusion: "This %{thing} is reserved. Enter a different %{thing}.",
    not_a_number: "Enter a number.",
    not_an_integer: "Enter a whole number.",
    greater_than: "Enter a number greater than %{count}.",
    greater_than_or_equal_to: "Enter a number of %{count} or more.",
    less_than: "Enter a number less than %{count}.",
    less_than_or_equal_to: "Enter a number of %{count} or less.",
    accepted: "Select %{thing} to continue.",
    confirmation: "%{label} doesn't match."
  }.freeze

  def cs_form_field(form, attribute, label: nil, optional: false, description: nil, constraint: nil,
    id: nil, as: :text_field, input: {}, messages: {}, example: nil, error_keys: [], warning: nil,
    group: false, **wrapper_options, &block)
    object = form.object
    id ||= form.field_id(attribute)
    label ||= cs_attribute_label(object, attribute)
    keys = [ attribute, *error_keys ]
    errors = keys.flat_map { |key| cs_field_error_messages(object, key, label: label, messages: messages, example: example) }.uniq
    cs_claim_error_keys(object, keys)

    cs_field(id: id, label: label, optional: optional, description: description, constraint: constraint,
      errors: errors, warning: warning, group: group, **wrapper_options) do |aria|
      if block
        capture(aria, &block)
      else
        default_class = as.to_s.include?("select") ? "cs-select" : "cs-input"
        form.public_send(as, attribute, { class: default_class, id: id }.merge(input).merge(aria))
      end
    end
  end

  # The same field markup for controls that aren't on a form builder
  # (text_field_tag and friends). `errors` is a list of ready messages.
  # `bare: true` skips the label, for a checkbox or radio that carries its
  # own (cs-option); `group: true` renders a fieldset with a legend.
  def cs_field(id:, label:, optional: false, description: nil, constraint: nil, errors: [], warning: nil,
    group: false, label_class: nil, hide_label: false, bare: false, **wrapper_options, &block)
    errors = Array(errors).compact_blank
    error_id = "#{id}-error"
    warning_id = "#{id}-warning"
    description_id = "#{id}-description"
    constraint_id = "#{id}-constraint"
    describedby = [
      (error_id if errors.any?),
      (warning_id if warning.present? && errors.empty?),
      (description_id if description.present?),
      (constraint_id if constraint.present?)
    ].compact
    aria = { aria: { invalid: (true if errors.any?), describedby: describedby.join(" ").presence }.compact }

    data = { cs_field: true, cs_label: label, cs_error_id: error_id }.merge(wrapper_options.delete(:data) || {})
    classes = [ "cs-field", wrapper_options.delete(:class) ].compact.join(" ")

    content_tag(group ? :fieldset : :div, class: classes, data: data, **wrapper_options) do
      label_classes = [ "cs-field-label", label_class, ("sr-only" if hide_label) ].compact.join(" ")
      label_markup = safe_join([ label, (content_tag(:span, " - optional", class: "cs-field-optional") if optional) ].compact)
      safe_join([
        (group ? content_tag(:legend, label_markup, class: label_classes) : content_tag(:label, label_markup, for: id, class: label_classes) unless bare),
        (content_tag(:p, description, class: "cs-field-description", id: description_id) if description.present?),
        capture(aria, &block),
        (cs_field_message(:error, errors.first, id: error_id, data: { cs_server_error: true }) if errors.any?),
        (cs_field_message(:warning, warning, id: warning_id, data: { cs_server_warning: true }) if warning.present? && errors.empty?),
        (content_tag(:p, constraint, class: "cs-field-hint", id: constraint_id) if constraint.present?)
      ].compact)
    end
  end

  # Inline error or warning text under a control.
  def cs_field_message(type, message, id:, **options)
    content_tag(:p, class: "cs-field-#{type}", id: id, **options) do
      cs_status_icon(type) + content_tag(:span, message)
    end
  end

  # Marks attributes as shown inline, for errors rendered by hand (nested
  # rows, custom widgets), so cs_form_errors doesn't repeat them.
  def cs_claim_errors(object, *attributes)
    cs_claim_error_keys(object, attributes.flatten)
  end

  # The errors on `attribute` in Cloudscape wording, in the order the model
  # added them.
  def cs_field_error_messages(object, attribute, label: nil, messages: {}, example: nil)
    return [] unless object.respond_to?(:errors)

    label ||= cs_attribute_label(object, attribute)
    object.errors.where(attribute).map do |error|
      cs_error_sentence(object, error, label: label, messages: messages, example: example)
    end.uniq
  end

  # Errors that no cs_form_field on this form claimed (and anything on
  # :base), as a Cloudscape alert. Put it just before the form's actions.
  # `form_or_object` is a FormBuilder or a model; pass several to merge.
  def cs_form_errors(*forms_or_objects, labels: {}, except: [], title: nil)
    messages = forms_or_objects.compact.flat_map do |form_or_object|
      object = form_or_object.respond_to?(:object) ? form_or_object.object : form_or_object
      next [] unless object.respond_to?(:errors)

      claimed = cs_claimed_error_keys(object) + Array(except)
      object.errors.reject { |error| claimed.include?(error.attribute) }.map do |error|
        label = labels[error.attribute] || cs_attribute_label(object, error.attribute)
        cs_error_sentence(object, error, label: label)
      end
    end.uniq
    cs_form_alert(messages, title: title)
  end

  # A Cloudscape form-level error alert for ready messages. Renders nothing
  # for an empty list.
  def cs_form_alert(messages, title: nil)
    messages = Array(messages).compact_blank
    return "".html_safe if messages.empty?

    content_tag(:div, class: "cs-alert cs-alert-error cs-form-error", role: "alert", tabindex: "-1") do
      body = if messages.one? && title.nil?
        content_tag(:p, messages.first)
      else
        safe_join([
          (content_tag(:p, title, class: "cs-alert-title") if title),
          (messages.one? ? content_tag(:p, messages.first) : content_tag(:ul, safe_join(messages.map { |m| content_tag(:li, m) }), class: "cs-form-error-list"))
        ].compact)
      end
      cs_status_icon(:error) + content_tag(:div, body)
    end
  end

  # One ActiveModel::Error as a Cloudscape sentence. Precedence: the
  # caller's `messages` for that type, then a model's own custom message as
  # a full sentence, then the generic template.
  def cs_error_sentence(object, error, label:, messages: {}, example: nil)
    type = error.type
    key = type.is_a?(Symbol) ? type : nil
    values = cs_error_values(object, error, label)

    if key && messages.key?(key)
      return format(messages[key], **values)
    end

    custom = type.is_a?(String) || error.options[:message].present?
    if custom || key.nil? || !CS_ERROR_TEMPLATES.key?(key)
      # Rails-style messages are fragments ("must be after the start time");
      # one that starts with a capital is already a sentence.
      text = error.attribute == :base || error.message.match?(/\A[[:upper:]]/) ? error.message : "#{label} #{error.message}"
      return cs_sentence(text)
    end

    sentence = format(CS_ERROR_TEMPLATES[key], **values)
    sentence += " For example: #{example}" if example.present? && key == :invalid
    sentence
  end

  def cs_attribute_label(object, attribute)
    return "This" if attribute.to_sym == :base

    if object.class.respond_to?(:human_attribute_name)
      object.class.human_attribute_name(attribute)
    else
      attribute.to_s.humanize
    end
  end

  # The label mid-sentence: "Support email" -> "support email", but
  # "URL" and "API token" keep their capitals.
  def cs_label_in_sentence(label)
    text = label.to_s
    return text if text.length > 1 && text[1] =~ /[[:upper:]]/

    text.sub(/\A[[:upper:]]/) { |c| c.downcase }
  end

  def cs_sentence(text)
    text = text.to_s.strip.upcase_first
    text.match?(/[.?]\z/) ? text : "#{text}."
  end

  private

  def cs_error_values(object, error, label)
    value = object.respond_to?(:read_attribute_for_validation) && error.attribute != :base ? object.read_attribute_for_validation(error.attribute) : nil
    {
      label: label,
      thing: cs_label_in_sentence(label),
      count: error.options[:count],
      length: value.to_s.length
    }
  end

  def cs_claim_error_keys(object, keys)
    return unless object

    (@cs_claimed_error_keys ||= {})[object.object_id] ||= []
    @cs_claimed_error_keys[object.object_id].concat(keys.map(&:to_sym))
  end

  def cs_claimed_error_keys(object)
    (@cs_claimed_error_keys || {}).fetch(object.object_id, [])
  end
end
