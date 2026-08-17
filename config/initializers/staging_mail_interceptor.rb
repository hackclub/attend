if Rails.env.staging?
  ActiveSupport.on_load(:action_mailer) do
    register_interceptor StagingMailInterceptor
  end
end
