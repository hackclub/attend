require "rails_helper"

# Crawlers ask HTML-only pages for JSON or XML. That's a 406 the app answers
# itself, not an exception for error tracking.
RSpec.describe "Requests for a format a page doesn't render", type: :request do
  it "answers the home page's JSON with 406 without raising", :raise_exceptions do
    get "/", headers: { "Accept" => "application/json" }

    expect(response).to have_http_status(:not_acceptable)
  end

  it "still renders the HTML page" do
    get "/"

    expect(response).to have_http_status(:ok)
  end

  it "still raises when an action has no HTML template at all" do
    controller = ApplicationController.new
    error = ActionController::MissingExactTemplate.new("missing", ApplicationController, "index")

    expect { controller.send(:handle_unknown_format, error) }.to raise_error(ActionController::MissingExactTemplate)
  end
end
