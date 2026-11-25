module Console
  # Cloudscape's container: a bordered 16px box with a header (title,
  # optional counter, description and right-aligned actions), a body and an
  # optional footer. Behind `cs_container`.
  #
  #   <%= cs_container "Ban details" do %>…<% end %>
  #
  #   <%= cs_container "Bans", divided: true, flush: true do |box| %>
  #     <% box.with_actions do %><%= cs_button "New ban", href: new_admin_ban_path %><% end %>
  #     <table class="cs-table">…</table>
  #   <% end %>
  #
  # `flush: true` puts the content straight under the header with no body
  # padding, which is how tables, filter bars and empty states sit.
  class ContainerComponent < ApplicationComponent
    renders_one :actions
    renders_one :footer

    def initialize(title = nil, description: nil, counter: nil, divided: false, flush: false,
      tag: :section, heading: :h2, body_class: nil, footer_class: nil, class: nil, **attributes)
      @title = title
      @description = description
      @counter = counter
      @divided = divided
      @flush = flush
      @tag = tag
      @heading = heading
      @body_class = body_class
      @footer_class = footer_class
      @classes = class_list("cs-container", binding.local_variable_get(:class))
      @attributes = attributes
    end

    def call
      # Rendering content first lets a block register the slots.
      body = content
      content_tag(@tag, class: @classes, **@attributes) do
        safe_join([
          header,
          (@flush ? body : content_tag(:div, body, class: class_list("cs-container-body", @body_class))),
          (content_tag(:div, footer, class: class_list("cs-container-footer", @footer_class)) if footer?)
        ].compact)
      end
    end

    private

    # Actions with no title still get a header to sit in.
    def header
      return if @title.nil? && !actions?

      content_tag(:div, class: class_list("cs-container-header", ("cs-container-header-divided" if @divided))) do
        safe_join([ (heading_block unless @title.nil?), (content_tag(:div, actions, class: "cs-actions") if actions?) ].compact)
      end
    end

    # A lone title is a bare heading; a description needs the wrapper so the
    # two stack beside the actions.
    def heading_block
      title = content_tag(@heading, class: "cs-h2") do
        safe_join([ @title, (safe_join([ " ", content_tag(:span, "(#{@counter})", class: "cs-counter") ]) unless @counter.nil?) ].compact)
      end
      return title if @description.blank?

      content_tag(:div, title + content_tag(:p, @description, class: "cs-container-description"))
    end
  end
end
