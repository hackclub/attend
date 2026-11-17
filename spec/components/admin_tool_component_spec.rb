require "rails_helper"

RSpec.describe AdminToolComponent, type: :component do
  it "renders the dashed orange panel" do
    render_inline(described_class.new) { "Admin only" }

    # The trailing space is what admin_tool has always emitted for no extra classes.
    expect(rendered_content).to eq('<div class="border-2 border-dashed border-orange-400 bg-yellow-100 rounded-lg p-2 ">Admin only</div>')
  end

  it "takes extra classes, another element and attributes" do
    render_inline(described_class.new("mt-4", "section", id: "tools")) { "Admin only" }

    expect(rendered_content).to eq('<section class="border-2 border-dashed border-orange-400 bg-yellow-100 rounded-lg p-2 mt-4" id="tools">Admin only</section>')
  end

  it "renders only the marker when it isn't a panel" do
    render_inline(described_class.new("rounded px-4 py-4", panel: false)) { "Admin only" }
    expect(rendered_content).to eq('<div class="border-2 border-dashed border-orange-400 rounded px-4 py-4">Admin only</div>')

    render_inline(described_class.new("", "span", panel: false)) { "Admin only" }
    expect(rendered_content).to eq('<span class="border-2 border-dashed border-orange-400">Admin only</span>')
  end

  describe "the admin_tool helper" do
    let(:view) { kit }

    def admin_tool_output(user, *args, **options)
      view.define_singleton_method(:current_user) { user }
      view.capture { view.admin_tool(*args, **options) { "Admin only" } }
    end

    it "matches what it emitted before the component layer" do
      admin = instance_double(User, admin?: true)

      [ [ [], {} ], [ [ "mt-4" ], {} ], [ [ "inline-block", "span" ], { id: "tools", data: { testid: "x" } } ] ].each do |args, options|
        expect(admin_tool_output(admin, *args, **options)).to eq(view.legacy_admin_tool(*args, **options) { "Admin only" })
      end
    end

    it "renders nothing for everyone else" do
      expect(admin_tool_output(instance_double(User, admin?: false))).to be_blank
      expect(admin_tool_output(nil)).to be_blank
    end
  end

  describe "the admin_tool_marker helper" do
    it "matches the hand-written wrappers it replaced" do
      expect(kit.admin_tool_marker("rounded px-4 py-4") { "x" })
        .to eq('<div class="border-2 border-dashed border-orange-400 rounded px-4 py-4">x</div>')
      expect(kit.admin_tool_marker("rounded", "span") { "x" })
        .to eq('<span class="border-2 border-dashed border-orange-400 rounded">x</span>')
      expect(kit.admin_tool_marker("rounded-md p-1") { "x" })
        .to eq('<div class="border-2 border-dashed border-orange-400 rounded-md p-1">x</div>')
    end
  end
end
