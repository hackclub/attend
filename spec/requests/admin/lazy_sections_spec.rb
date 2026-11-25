require "rails_helper"

# Slow sections that load into their page after it renders (LazyFrameHelper).
# Each page answers with a frame and a skeleton; the section's own endpoint
# answers with the matching frame and no layout. Both admin UIs.
RSpec.describe "Lazy-loaded admin sections", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:user, global_role: "global_admin") }

  before { sign_in admin }

  def frame(id)
    Nokogiri::HTML(response.body).at_css("turbo-frame##{id}")
  end

  [ true ].each do |console|
    context(console ? "with the admin console beta" : "in the original admin") do
      describe "a training course's invitations and learners" do
        let(:course) { create(:training_course, :with_lessons) }
        let(:learner) { create(:user, name: "Ada Fictional") }

        before { create(:training_enrollment, course: course, user: learner) }

        it "loads into the course page" do
          get admin_training_course_path(course)

          expect(response).to have_http_status(:ok)
          expect(frame("course_people")["src"]).to eq(people_admin_training_course_path(course))
          expect(frame("course_people").at_css(".skeleton")).to be_present
          expect(response.body).not_to include("Ada Fictional")

          get people_admin_training_course_path(course), headers: { "Turbo-Frame" => "course_people" }

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include("<html")
          expect(frame("course_people").text).to include("Invitations", "Learners", "Ada Fictional", "0 of 2 lessons")
        end

        it "still offers to delete a draft nobody has started" do
          draft = create(:training_course)

          get admin_training_course_path(draft)

          expect(response.body).to include("Delete")
        end
      end

      describe "rooming setup's suggested sibling groups" do
        let(:event) { create(:event) }

        before do
          event.main_rooming_context.create_rooming_plan!(event: event, created_by_user: admin, room_capacity: 2, status: :draft)
          %w[Ada Grace].each do |first|
            create(:participant_event, event: event, participant: create(:participant, legal_first_name: first, legal_last_name: "Fictionalson"))
          end
        end

        it "loads into the setup step" do
          get setup_admin_event_rooming_wizard_path(event.slug)

          expect(response).to have_http_status(:ok)
          expect(frame("suggested_siblings")["src"]).to eq(suggested_siblings_admin_event_rooming_wizard_path(event.slug))
          expect(response.body).not_to include("Suggested")

          get suggested_siblings_admin_event_rooming_wizard_path(event.slug), headers: { "Turbo-Frame" => "suggested_siblings" }

          expect(response).to have_http_status(:ok)
          expect(response.body).not_to include("<html")
          expect(frame("suggested_siblings").text).to include("Fictionalson")
        end
      end
    end
  end

  describe "the shared page skeleton" do
    it "is in every admin page, hidden until a visit is in flight" do
      get admin_series_index_path

      skeleton = Nokogiri::HTML(response.body).at_css("[data-page-content] > .page-loading")
      expect(skeleton).to be_present
      expect(skeleton["hidden"]).not_to be_nil
    end
  end
end
