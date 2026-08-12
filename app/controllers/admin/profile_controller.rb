module Admin
  class ProfileController < BaseController
    def edit
      @user = current_user
    end

    def update
      @user = current_user

      if @user.update(profile_params)
        redirect_to edit_admin_profile_path, notice: "Profile updated successfully."
      else
        flash.now[:alert] = @user.errors.full_messages.to_sentence
        render :edit, status: :unprocessable_entity
      end
    end

    def destroy_avatar
      @user = current_user
      @user.avatar.purge_later
      redirect_to edit_admin_profile_path, notice: "Profile picture removed."
    end

    private

    def profile_params
      params.require(:user).permit(:display_name, :avatar, :phone_number, :slack_user_id)
    end
  end
end
