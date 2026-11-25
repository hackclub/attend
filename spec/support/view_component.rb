require "view_component/test_helpers"

# Component specs live in spec/components and are tagged `type: :component`.
# `render_inline(component)` returns a Nokogiri fragment and leaves the exact
# markup in `rendered_content`, which is what the kit specs pin.
RSpec.configure do |config|
  config.include ViewComponent::TestHelpers, type: :component
  config.include LegacyKitMarkup::SpecHelpers, type: :component
end
