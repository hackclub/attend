require "rails_helper"

RSpec.describe "The staging frame", type: :request do
  it "is not rendered outside staging" do
    get root_path

    expect(response.body).not_to include("staging-frame")
  end

  it "is rendered on staging" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("staging"))

    get root_path

    expect(response.body).to include('class="staging-frame"')
  end
end
