# The kit helpers exactly as they were written before the component layer
# (app/components) took over their markup, kept so the component specs can
# check new output against old, byte for byte. Nothing in the app uses this.
#
# Frozen on purpose: when a component's markup is changed deliberately, update
# the literal markup pinned in its spec and delete the matching method here
# rather than editing it to agree.
module LegacyKitMarkup
  STATUS_ICONS = {
    success: '<circle cx="8" cy="8" r="7"/><path d="M4.5 8.2l2.3 2.3 4.7-4.9"/>',
    error: '<circle cx="8" cy="8" r="7"/><path d="M5.5 5.5l5 5m0-5l-5 5"/>',
    warning: '<path d="M8 1.5l7 12.5H1z"/><path d="M8 6v4m0 1.8v.2"/>',
    info: '<circle cx="8" cy="8" r="7"/><path d="M8 7v4.5m0-6.8v.3"/>',
    pending: '<circle cx="8" cy="8" r="7"/><path d="M8 4.5V8l2.5 1.8"/>',
    in_progress: '<circle cx="8" cy="8" r="7" stroke-dasharray="3 2.5"/><circle cx="8" cy="8" r="1.4" fill="currentColor" stroke="none"/>',
    stopped: '<circle cx="8" cy="8" r="7"/><path d="M5 8h6"/>'
  }.freeze

  SEVERITY_BADGES = %w[critical high medium low neutral].freeze

  def legacy_cs_status(type, label)
    type = type.to_s.to_sym
    type = :info unless STATUS_ICONS.key?(type)
    content_tag(:span, class: "cs-status cs-status-#{type.to_s.dasherize}") do
      legacy_cs_status_icon(type) + content_tag(:span, label)
    end
  end

  def legacy_cs_status_icon(type)
    content_tag(:svg, STATUS_ICONS.fetch(type.to_sym).html_safe,
      viewBox: "0 0 16 16", fill: "none", stroke: "currentColor",
      "stroke-width": "2", "stroke-linecap": "round", "stroke-linejoin": "round",
      "aria-hidden": "true")
  end

  def legacy_cs_badge(label, color = nil)
    classes = [ "cs-badge" ]
    classes << "cs-badge-#{color}" if color
    content_tag(:span, label, class: classes.join(" "))
  end

  def legacy_cs_severity_badge(severity, label = nil)
    level = SEVERITY_BADGES.include?(severity.to_s) ? severity.to_s : "neutral"
    content_tag(:span, label || severity.to_s.humanize, class: "cs-badge cs-badge-severity-#{level}")
  end

  def legacy_cs_no_match(clear_href: nil, **options)
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

  def legacy_cs_field(id:, label:, optional: false, description: nil, constraint: nil, errors: [], warning: nil,
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
        (legacy_cs_field_message(:error, errors.first, id: error_id, data: { cs_server_error: true }) if errors.any?),
        (legacy_cs_field_message(:warning, warning, id: warning_id, data: { cs_server_warning: true }) if warning.present? && errors.empty?),
        (content_tag(:p, constraint, class: "cs-field-hint", id: constraint_id) if constraint.present?)
      ].compact)
    end
  end

  def legacy_cs_field_message(type, message, id:, **options)
    content_tag(:p, class: "cs-field-#{type}", id: id, **options) do
      legacy_cs_status_icon(type) + content_tag(:span, message)
    end
  end

  def legacy_cs_form_alert(messages, title: nil)
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
      legacy_cs_status_icon(:error) + content_tag(:div, body)
    end
  end

  # admin_tool without its `current_user.admin?` gate and its `concat`.
  def legacy_admin_tool(class_name = "", element = "div", **options, &block)
    content_tag(element, class: "border-2 border-dashed border-orange-400 bg-yellow-100 rounded-lg p-2 #{class_name}", **options, &block)
  end

  module SpecHelpers
    # A view context that answers both the current helpers and the legacy_* ones.
    def kit
      @kit ||= vc_test_controller.view_context.extend(LegacyKitMarkup)
    end

    # Parsed markup with attributes sorted, for comparing against hand-written
    # HTML whose attribute order is the author's rather than Rails'.
    def dom(html)
      fragment = Nokogiri::HTML5.fragment(html.to_s)
      fragment.traverse do |node|
        next unless node.element?

        attributes = node.attribute_nodes.map { |a| [ a.name, a.value ] }.sort
        node.attribute_nodes.each(&:remove)
        attributes.each { |name, value| node[name] = value }
      end
      fragment.to_html
    end
  end
end
