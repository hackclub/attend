require "rails_helper"

# The Content-Security-Policy is enforced, not report-only, and script-src
# carries no `unsafe-inline`. That is what keeps injected markup inert if a
# template ever forgets to escape a participant's name — but it only holds
# while every page obeys two rules:
#
#   * no inline event handler (onclick=, onerror=, ...) anywhere, and
#   * every inline <script> carries the request's nonce.
#
# Break either and the page silently stops working in production, where
# nothing raises. So render the real pages and check the real HTML.
RSpec.describe "Content Security Policy", type: :request do
  include Devise::Test::IntegrationHelpers

  # Attributes the HTML spec treats as event handlers. Anything matching this
  # in rendered markup is blocked by the policy.
  INLINE_HANDLER = /\s(on[a-z]+)\s*=\s*["']/i

  SCRIPT_TAG = /<script\b([^>]*)>/im

  def script_attributes(html)
    html.scan(SCRIPT_TAG).flatten
  end

  def inline_script_attributes(html)
    script_attributes(html).reject { |attributes| attributes.match?(/\bsrc\s*=/i) }
  end

  def nonce_from(response)
    response.headers["Content-Security-Policy"].to_s[/'nonce-([^']+)'/, 1]
  end

  # Renders the page and asserts it obeys both rules.
  #
  # `inline_scripts:` is the point of the exercise: passing a route that
  # renders a *different* view than you meant would otherwise pass silently,
  # finding no handlers and no scripts. Naming the expected count makes the
  # spec fail loudly instead.
  def expect_csp_clean(path, inline_scripts: 0)
    get path
    expect(response).to have_http_status(:ok), "#{path} did not render"

    header = response.headers["Content-Security-Policy"]
    expect(header).to be_present, "#{path} sent no enforcing CSP header"
    expect(response.headers["Content-Security-Policy-Report-Only"]).to be_blank,
      "#{path} is still report-only"

    # Only script-src matters here — style-src allows unsafe-inline on purpose.
    script_src = header[/script-src[^;]*/]
    expect(script_src).to be_present, "#{path} sent no script-src"
    expect(script_src).not_to include("unsafe-inline"), "#{path} allows #{script_src}"

    expect(response.body.scan(INLINE_HANDLER).flatten.uniq).to be_empty,
      "#{path} renders inline event handlers, which the policy blocks"

    inline = inline_script_attributes(response.body)
    expect(inline.length).to eq(inline_scripts),
      "#{path} rendered #{inline.length} inline <script> tags, expected #{inline_scripts} — " \
      "if the page changed, update the count; if it dropped to 0, check the route still renders this view"

    nonce = nonce_from(response)
    unnonced = inline.reject { |attributes| attributes.include?(%(nonce="#{nonce}")) }
    expect(unnonced).to be_empty,
      "#{path} renders an inline <script> without the request nonce, which the policy blocks"
  end

  describe "the policy itself" do
    it "is enforced rather than report-only" do
      expect(Rails.application.config.content_security_policy_report_only).to be(false)
    end

    it "issues a different nonce on every response" do
      generator = Rails.application.config.content_security_policy_nonce_generator
      nonces = Array.new(5) { generator.call(nil) }

      expect(nonces.uniq.length).to eq(5)
      expect(nonces).to all(be_present)
    end
  end

  # The app layout renders four inline scripts of its own (theme, importmap,
  # module preloads, and the Mintlify assistant's init block), so that is the
  # floor for any page using it.
  LAYOUT_INLINE_SCRIPTS = 4

  describe "public pages" do
    it "the sign-in page is clean" do
      expect_csp_clean(root_path, inline_scripts: LAYOUT_INLINE_SCRIPTS)
    end

    # The sign-in button posts to /users/auth/hack_club, which redirects to
    # HCA. form-action is enforced across the redirect, so dropping the OAuth
    # host here blocks sign-in entirely with nothing on the server side to show
    # for it.
    it "allows the HCA OAuth host in form-action" do
      get root_path

      form_action = response.headers["Content-Security-Policy"][/form-action[^;]*/]
      expect(form_action).to include("https://auth.hackclub.com")
    end
  end

  describe "admin pages" do
    let(:event) { create(:event) }
    let(:admin) do
      User.create!(email: "csp-admin@example.com", name: "CSP Admin", global_role: "global_admin")
    end

    before { sign_in admin }

    it "the QR scanner is clean" do
      ScanContext.create!(event: event, name: "Main Door", checks_in: true, is_travel_pickup: false)

      expect_csp_clean(scanner_admin_event_scans_path(event), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end

    it "the scan history is clean" do
      expect_csp_clean(history_admin_event_scans_path(event), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end

    it "the event form is clean" do
      expect_csp_clean(edit_admin_event_path(event), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end

    it "the event setup schedule step is clean" do
      expect_csp_clean(admin_event_setup_schedule_path(event.slug), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end

    it "the participants table is clean" do
      expect_csp_clean(admin_event_participants_path(event), inline_scripts: LAYOUT_INLINE_SCRIPTS)
    end

    it "the dashboard is clean" do
      expect_csp_clean(admin_event_dashboard_path(event), inline_scripts: LAYOUT_INLINE_SCRIPTS)
    end

    # /docs uses its own bare layout rather than the app one, hence the count.
    # It is also the Scalar fallback: once MINTLIFY_DOCS_HOST is set the
    # response is Mintlify's HTML under Mintlify's own policy, and this stops
    # being ours to check.
    it "the API docs page is clean" do
      expect_csp_clean(docs_path, inline_scripts: 1)
    end

    # The assistant widget loads from Mintlify and talks to their API. Losing
    # any of these origins breaks it with nothing in the server logs.
    it "allows the Mintlify assistant's origins" do
      get root_path

      header = response.headers["Content-Security-Policy"]
      expect(header[/script-src[^;]*/]).to include("https://widget.mintlify.com")
      expect(header[/connect-src[^;]*/]).to include("https://api.mintlify.com", "https://ph.mintlify.com")
      expect(header[/frame-src[^;]*/]).to include("hcaptcha.com")
    end
  end

  # The rooming wizard carried most of the inline handlers, and its partials
  # (_room_card, _preference_links) render one script block per room and per
  # participant, so the counts here also pin that the delegated listeners
  # aren't being installed once per copy.
  describe "the rooming wizard" do
    let(:event) { create(:event) }
    let(:admin) do
      User.create!(email: "csp-rooming@example.com", name: "CSP Rooming", global_role: "global_admin")
    end

    before { sign_in admin }

    it "the setup step is clean" do
      expect_csp_clean(setup_admin_event_rooming_wizard_path(event.slug), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end

    it "the preferences step is clean, with one script per participant partial" do
      # The page joins accommodations, so a participant without one is skipped.
      create_list(:participant_event, 2, event: event).each do |pe|
        Accommodation.create!(participant_event: pe)
      end

      expect_csp_clean(
        preferences_admin_event_rooming_wizard_path(event.slug),
        inline_scripts: LAYOUT_INLINE_SCRIPTS + 1 + 2
      )
    end

    it "the assignments step is clean, with one script per room partial" do
      RoomingPlan.create!(event: event)
      2.times { |i| Room.create!(event: event, name: "Room #{i}", capacity: 2) }

      expect_csp_clean(
        assignments_admin_event_rooming_wizard_path(event.slug),
        inline_scripts: LAYOUT_INLINE_SCRIPTS + 1 + 2
      )
    end

    it "the finalize step is clean" do
      RoomingPlan.create!(event: event)

      expect_csp_clean(finalize_admin_event_rooming_wizard_path(event.slug), inline_scripts: LAYOUT_INLINE_SCRIPTS + 1)
    end
  end
end
