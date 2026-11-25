module Console
  # One Cloudscape form field: label (with a lighter "- optional" marker),
  # description, the control, the first error (or a warning) and constraint
  # text. Behind `cs_field` and, through it, `cs_form_field`.
  #
  # The control is the component's content. It needs the aria attributes the
  # field works out (aria-invalid, aria-describedby), so read
  # `control_attributes` before rendering and splat it onto the control; the
  # helpers do this by handing the hash to their block.
  #
  # `bare: true` skips the label, for a checkbox or radio that carries its own
  # (cs-option); `group: true` renders a fieldset with a legend.
  class FieldComponent < ApplicationComponent
    def initialize(id:, label:, optional: false, description: nil, constraint: nil, errors: [], warning: nil,
      group: false, label_class: nil, hide_label: false, bare: false, **wrapper_options)
      @id = id
      @label = label
      @optional = optional
      @description = description
      @constraint = constraint
      @errors = Array(errors).compact_blank
      @warning = warning
      @group = group
      @label_class = label_class
      @hide_label = hide_label
      @bare = bare
      @wrapper_options = wrapper_options
    end

    def control_attributes
      describedby = [
        (error_id if @errors.any?),
        (warning_id if warning?),
        (description_id if @description.present?),
        (constraint_id if @constraint.present?)
      ].compact
      { aria: { invalid: (true if @errors.any?), describedby: describedby.join(" ").presence }.compact }
    end

    def call
      wrapper_options = @wrapper_options.dup
      data = { cs_field: true, cs_label: @label, cs_error_id: error_id }.merge(wrapper_options.delete(:data) || {})
      classes = [ "cs-field", wrapper_options.delete(:class) ].compact.join(" ")

      content_tag(@group ? :fieldset : :div, class: classes, data: data, **wrapper_options) do
        safe_join([
          label_tag_markup,
          (content_tag(:p, @description, class: "cs-field-description", id: description_id) if @description.present?),
          content,
          (render(FieldMessageComponent.new(:error, @errors.first, id: error_id, data: { cs_server_error: true })) if @errors.any?),
          (render(FieldMessageComponent.new(:warning, @warning, id: warning_id, data: { cs_server_warning: true })) if warning?),
          (content_tag(:p, @constraint, class: "cs-field-hint", id: constraint_id) if @constraint.present?)
        ].compact)
      end
    end

    private

    def label_tag_markup
      return if @bare

      classes = [ "cs-field-label", @label_class, ("sr-only" if @hide_label) ].compact.join(" ")
      markup = safe_join([ @label, (content_tag(:span, " - optional", class: "cs-field-optional") if @optional) ].compact)
      @group ? content_tag(:legend, markup, class: classes) : content_tag(:label, markup, for: @id, class: classes)
    end

    # A warning only shows when there is no error to show instead.
    def warning?
      @warning.present? && @errors.empty?
    end

    def error_id = "#{@id}-error"
    def warning_id = "#{@id}-warning"
    def description_id = "#{@id}-description"
    def constraint_id = "#{@id}-constraint"
  end
end
