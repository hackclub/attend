# In development, multiple checkouts of Attend (main + Claude worktrees) often
# run on different ports of 127.0.0.1 at the same time. Cookies ignore ports,
# so they all fight over the same "_attend_session" cookie and silently log
# each other out. Give each checkout its own cookie name instead.
if Rails.env.development?
  require "digest"
  Rails.application.config.session_store :cookie_store,
    key: "_attend_session_#{Digest::MD5.hexdigest(Rails.root.to_s)[0, 6]}"
end
