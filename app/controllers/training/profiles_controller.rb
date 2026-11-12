module Training
  # The contact details everyone gives before training (TrainingProfile):
  # asked on the way into /training, and editable afterwards.
  class ProfilesController < BaseController
    skip_before_action :require_training_profile

    def edit
      @profile = current_user.training_profile || current_user.build_training_profile(TrainingProfile.prefill_for(current_user))
      @prefilled_from_hack_club = @profile.new_record? && current_user.hack_club_account_id.present?
    end

    def update
      @profile = current_user.training_profile || current_user.build_training_profile
      first_time = @profile.new_record?
      @profile.assign_attributes(profile_params)

      if @profile.save
        return_to = session.delete(:training_return_to)
        destination = first_time ? (safe_training_path(return_to) || training_path) : edit_training_profile_path
        redirect_to destination, notice: first_time ? "Thanks — your details are saved." : "Your details are updated."
      else
        render :edit, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotUnique
      # A second tab saved first; update that one instead.
      current_user.reload
      retry
    end

    private

    def profile_params
      params.require(:training_profile).permit(
        :full_name, :connection_type, :connection_detail, :phone_number,
        :address_line_1, :address_line_2, :city, :state, :postal_code, :country
      )
    end

    def safe_training_path(location)
      path = url_from(location.to_s)
      path if path&.start_with?("/training") && !path.start_with?(edit_training_profile_path)
    end
  end
end
