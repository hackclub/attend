module HealthSectionsHelper
  SECTION_LABELS = {
    medical: "Medical needs",
    dietary: "Food requirements",
    accessibility: "Accessibility or support needs"
  }.freeze

  def health_section_summary(record)
    response = record&.effective_section_response
    return "Not answered" if response.blank?
    return "Nothing to add" if response == "nothing_to_add"

    prefix = response == "private" ? "Prefer to discuss privately" : nil
    values = record.attributes.filter_map do |name, value|
      next if %w[id participant_event_id created_at updated_at section_response last_updated_by_user_id].include?(name)
      next if value == false || value.blank?

      label = name.humanize(capitalize: false)
      value == true ? label : "#{label}: #{value}"
    end
    details = values.presence || "Details selected; no details entered yet"
    [ prefix, details ].compact.join(". ")
  end

  def health_section_details_open?(record)
    record&.effective_section_response == "details" ||
      record&.effective_section_response == "private"
  end
end
