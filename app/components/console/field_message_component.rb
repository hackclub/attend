module Console
  # Inline error or warning text under a control: the status icon and the
  # message. Behind `cs_field_message(type, message, id:)`.
  class FieldMessageComponent < ApplicationComponent
    def initialize(type, message, id:, **attributes)
      @type = type
      @message = message
      @id = id
      @attributes = attributes
    end

    def call
      content_tag(:p, class: "cs-field-#{@type}", id: @id, **@attributes) do
        render(StatusIconComponent.new(@type)) + content_tag(:span, @message)
      end
    end
  end
end
