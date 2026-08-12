require "rails_helper"

RSpec.describe AuditLog, type: :model do
  # `log_admin_action` hands the raw `action_name` to `AuditLog.log!`, so an
  # admin action missing from this enum raises ArgumentError inside the
  # after_action. Production swallows it: the change lands, nothing is audited,
  # and Sentry gets an error on every request.
  describe "the action enum" do
    it "covers every non-GET admin action that log_admin_action fires on" do
      valid = described_class.actions.keys.map(&:to_s) | described_class.actions.values.map(&:to_s)

      missing = audited_admin_actions.reject { |_controller, action| valid.include?(action) }

      expect(missing).to be_empty, lambda {
        "These admin actions have no AuditLog action enum entry, so auditing " \
        "them raises ArgumentError:\n" +
          missing.map { |controller, action| "  #{action} (#{controller})" }.join("\n")
      }
    end
  end

  # [controller, action] for every routable non-GET admin action whose
  # controller still runs the log_admin_action after_action.
  def audited_admin_actions
    Rails.application.routes.routes.filter_map { |route|
      verbs = route.verb.to_s.split("|")
      next if verbs.empty? || verbs.all? { |verb| verb.in?(%w[GET HEAD]) }

      controller = route.defaults[:controller].to_s
      next unless controller.start_with?("admin/")
      next unless audit_logged?(controller)

      [ controller, route.defaults[:action].to_s ]
    }.uniq
  end

  def audit_logged?(controller)
    klass = "#{controller}_controller".camelize.safe_constantize
    return false unless klass.respond_to?(:_process_action_callbacks)

    klass._process_action_callbacks.any? do |callback|
      callback.kind == :after && callback.filter == :log_admin_action
    end
  end
end
