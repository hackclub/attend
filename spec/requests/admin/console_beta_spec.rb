require "rails_helper"

RSpec.describe "Admin console beta switch", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:staff) { User.create!(email: "beta-staff@example.com", name: "Pat Placeholder", global_role: "global_admin") }
  let(:referer) { "http://www.example.com/admin/audit_logs" }

  def html_tag
    response.body[/<html[^>]*>/]
  end

  def toggle(enabled, headers: { "HTTP_REFERER" => referer })
    patch admin_console_beta_path, params: { enabled: enabled }, headers: headers
  end

  before { sign_in staff }

  it "is off by default" do
    expect(User.new.admin_console_beta).to be(false)
  end

  it "shows the original admin with a way into the beta" do
    get admin_root_path

    expect(response).to have_http_status(:ok)
    expect(html_tag).not_to include("cs-console")
    expect(response.body).to include("Try the new admin")
    expect(response.body).to include(%(action="#{admin_console_beta_path}"))
    expect(response.body).not_to include("cs-beta-bar")
  end

  it "opts in, redirects back to the page, and serves the console from then on" do
    expect { toggle("true") }.to change { staff.reload.admin_console_beta }.from(false).to(true)
    expect(response).to redirect_to(referer)
    expect(response).to have_http_status(:see_other)

    get admin_root_path

    expect(html_tag).to include("cs-console")
    expect(response.body).to include("attend-shell")
    expect(response.body).to include("You're testing the new admin.")
    expect(response.body).to include("mailto:attend@hackclub.com?")
    expect(response.body).to include("subject=New%20admin%20feedback")
    expect(response.body).to include("body=Page%3A%20%2Fadmin%0A%0A")
    expect(response.body).to include("Switch back")
    expect(response.body).not_to include("Try the new admin")
  end

  it "opts back out" do
    staff.update!(admin_console_beta: true)

    expect { toggle("false") }.to change { staff.reload.admin_console_beta }.from(true).to(false)
    expect(response).to redirect_to(referer)

    get admin_root_path
    expect(html_tag).not_to include("cs-console")
  end

  it "audit-logs the change on the user's own record" do
    expect { toggle("true") }.to change(AuditLog, :count).by(1)

    log = AuditLog.order(:created_at).last
    expect(log.record).to eq(staff)
    expect(log.actor).to eq(staff)
    expect(log.changed_fields).to eq("admin_console_beta" => [ false, true ])
  end

  it "falls back to the admin root without a same-origin referer" do
    toggle("true", headers: { "HTTP_REFERER" => "https://elsewhere.example/phish" })
    expect(response).to redirect_to(admin_root_path)

    toggle("false", headers: {})
    expect(response).to redirect_to(admin_root_path)
  end

  it "lets event-level staff opt themselves in" do
    ops = User.create!(email: "beta-ops@example.com", name: "Robin Example")
    EventRoleAssignment.create!(user: ops, event: create(:event), role: "ops")
    sign_in ops

    expect { toggle("true") }.to change { ops.reload.admin_console_beta }.to(true)
    expect(staff.reload.admin_console_beta).to be(false)
  end

  it "turns non-staff away" do
    participant_user = User.create!(email: "beta-participant@example.com", name: "Sam Sample")
    sign_in participant_user

    toggle("true")

    expect(response).to redirect_to(root_path)
    expect(participant_user.reload.admin_console_beta).to be(false)
  end
end
