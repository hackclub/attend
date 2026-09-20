module HealthSectionResponse
  extend ActiveSupport::Concern

  included do
    enum :section_response, {
      details: "details",
      nothing_to_add: "nothing_to_add",
      private: "private"
    }, prefix: true

    validate :nothing_to_add_has_no_details
  end

  class_methods do
    def health_section_detail_fields
      @health_section_detail_fields ||= attribute_names.map(&:to_sym).reject do |field|
        %i[id participant_event_id created_at updated_at section_response last_updated_by_user_id].include?(field)
      end
    end

    def health_section_boolean_fields
      @health_section_boolean_fields ||= health_section_detail_fields.select do |field|
        type_for_attribute(field.to_s).type == :boolean
      end
    end
  end

  def effective_section_response
    return "details" if section_response.nil? && health_section_has_details?

    section_response
  end

  def health_section_answered?
    section_response.present? || health_section_has_details?
  end

  private

  def nothing_to_add_has_no_details
    return unless section_response == "nothing_to_add" && health_section_has_details?

    errors.add(:section_response, "cannot be Nothing to add while details are present")
  end
end
