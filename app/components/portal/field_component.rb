module Portal
  # One portal form field: the label (with the red asterisk when required),
  # optional hint text, then the control, which is the component's content.
  # Behind `portal_field`.
  #
  #   <%= portal_field "Full Name", for: ec.field_id(:name), required: true do %>
  #     <%= ec.text_field :name, class: "portal-input", required: true %>
  #   <% end %>
  #
  # The hint sits between the label and the control, where the portal forms
  # put it. `wrapper: false` drops the surrounding <div> for a field that sits
  # directly in its form.
  class FieldComponent < ApplicationComponent
    HINT_CLASS = "portal-hint text-sm mb-3".freeze

    def initialize(label, for:, required: false, hint: nil, hint_class: HINT_CLASS, wrapper: true, class: nil, **attributes)
      @label = label
      @for = binding.local_variable_get(:for)
      @required = required
      @hint = hint
      @hint_class = hint_class
      @wrapper = wrapper
      @classes = binding.local_variable_get(:class)
      @attributes = attributes
    end

    def call
      parts = safe_join([
        content_tag(:label, label_markup, class: "portal-label", for: @for),
        (content_tag(:p, @hint, class: @hint_class) if @hint.present?),
        content
      ].compact)
      return parts unless @wrapper

      content_tag(:div, parts, class: @classes.presence, **@attributes)
    end

    private

    # The same marker `label_text(text, required: true)` has always appended.
    def label_markup
      return @label unless @required

      safe_join([ @label, content_tag(:span, "*", class: "text-red-500 ml-0.5") ])
    end
  end
end
