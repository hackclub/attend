# The dashed orange outline that marks an admin-only control or panel on a
# page other roles can also see (DESIGN.md, "The Admin-Only Marker Rule").
#
# Two shapes:
#   * the panel behind `admin_tool`: the marker plus a yellow wash, 8px radius
#     and 8px padding;
#   * the bare marker behind `admin_tool_marker` (`panel: false`): only the
#     outline, with radius and padding left to the caller.
#
# The component only draws the marker. Who gets to see what is inside is the
# caller's decision: `admin_tool` checks `current_user.admin?`, and the
# hand-converted wrappers keep the policy checks they already sat in.
class AdminToolComponent < ApplicationComponent
  MARKER = "border-2 border-dashed border-orange-400".freeze
  PANEL = "#{MARKER} bg-yellow-100 rounded-lg p-2".freeze

  def initialize(class_name = "", element = "div", panel: true, **attributes)
    @element = element
    @classes = panel ? "#{PANEL} #{class_name}" : [ MARKER, class_name.presence ].compact.join(" ")
    @attributes = attributes
  end

  def call
    content_tag(@element, content, class: @classes, **@attributes)
  end
end
