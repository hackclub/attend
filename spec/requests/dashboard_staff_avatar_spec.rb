require "rails_helper"

RSpec.describe "Dashboard staff avatar", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user, global_role: :global_admin) }

  before { sign_in user }

  it "attaches an uploaded avatar" do
    patch dashboard_staff_profile_path,
          params: { user: { display_name: "Sunbeam", avatar: fixture_file_upload("headshot.png", "image/png") } }

    expect(user.reload.avatar).to be_attached
  end

  it "won't attach someone else's photo from a signed id posted as the avatar" do
    someone = create(:user)
    someone.avatar.attach(io: Rails.root.join("spec/fixtures/files/headshot.png").open,
                          filename: "theirs.png", content_type: "image/png")

    patch dashboard_staff_profile_path,
          params: { user: { display_name: "Sunbeam", avatar: someone.avatar.blob.signed_id } }

    expect(user.reload.display_name).to eq("Sunbeam")
    expect(user.avatar).not_to be_attached
    expect(someone.reload.avatar).to be_attached
  end
end
