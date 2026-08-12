module OnboardingHelper
  def step_status_class(step_index, current_step_index, completed_step_index)
    if step_index < current_step_index
      "completed"
    elsif step_index == current_step_index
      "current"
    elsif step_index <= completed_step_index
      "available"
    else
      "locked"
    end
  end
end
