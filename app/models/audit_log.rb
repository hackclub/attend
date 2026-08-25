class AuditLog < ApplicationRecord
  self.implicit_order_column = "created_at"

  belongs_to :actor, class_name: "User", foreign_key: "actor_user_id", optional: true
  belongs_to :event, optional: true
  belongs_to :record, polymorphic: true, optional: true

  enum :action, {
    record_create: "create",
    record_update: "update",
    record_destroy: "destroy",
    export: "export",
    api_call: "api_call",
    login: "login",
    view: "view",
    send_invite: "send_invite",
    slack_blast: "slack_blast",
    impersonate: "impersonate",
    update_integrations: "update_integrations",
    update_travel: "update_travel",
    resend_guardian_invite: "resend_guardian_invite",
    event_select: "select",
    reset_waiver: "reset_waiver",
    reset_freedom_waiver: "reset_freedom_waiver",
    send_travel_update_reminder: "send_travel_update_reminder",
    approve_um: "approve_um",
    reject_um: "reject_um",
    um_proof: "um_proof",
    withdraw: "withdraw",
    unwithdraw: "unwithdraw",
    resend_waiver_completion_email: "resend_waiver_completion_email",
    resend_custom_document: "resend_custom_document",
    reset_custom_document: "reset_custom_document",
    update_medical: "update_medical",
    undo_check_in: "undo_check_in",
    update_safeguarding: "update_safeguarding",
    invite_to_slack_channel: "invite_to_slack_channel",
    merge_duplicate: "merge_duplicate",
    update_accommodation: "update_accommodation",
    nfc_badge_assigned: "nfc_badge_assigned",
    nfc_badge_reset: "nfc_badge_reset",
    confirm_nfc_badge: "confirm_nfc_badge",
    reset_nfc_badge: "reset_nfc_badge",
    passport_pair: "passport_pair",
    passport_revoke: "passport_revoke",
    regenerate_api_key: "regenerate_api_key",
    attach_image: "attach_image",
    update_groups: "update_groups",
    use_default_docuseal_template: "use_default",
    sync_docuseal_template: "sync",
    save_docuseal_template: "save",
    update_docuseal_mappings: "update_mappings",
    refresh_flight_leg: "refresh_flight_leg",
    update_setup_schedule: "update_schedule",
    update_setup_modules: "update_modules",
    update_setup_waivers: "update_waivers",
    add_team_member: "add_team_member",
    remove_team_member: "remove_team_member",
    complete_setup: "complete",
    sync_slack_channel: "sync_slack_channel",
    ticket_close: "close",
    ticket_reopen: "reopen",
    ticket_assign: "assign",
    ticket_set_event: "set_event",
    ticket_set_subject: "set_subject",
    toggle_support_sms: "toggle_support_sms",
    update_support_sms_numbers: "update_support_sms_numbers",
    trigger_airtable_sync: "trigger_airtable_sync",
    create_vote_event: "create_vote_event",
    dismiss_pickup: "dismiss_pickup",
    refresh_all: "refresh_all",
    revoke: "revoke",
    reinstate: "reinstate",
    rotate_api_token: "rotate",
    reorder_groups: "reorder",
    unassign: "unassign",
    cancel: "cancel",
    confirm: "confirm",
    send_to_slack: "send_to_slack",
    send_now: "send_now",
    retry_delivery: "retry_delivery",
    retry_failed: "retry_failed",
    retry_recipient: "retry_recipient",
    link_guardian: "link_guardian",
    refresh_flight_tracking: "refresh_flight_tracking",
    resync_airtable: "resync_airtable",
    revoke_invite: "revoke_invite",
    destroy_avatar: "destroy_avatar",
    toggle_maintenance: "toggle_maintenance",
    toggle_twilio: "toggle_twilio",
    toggle_waiver_sending: "toggle_waiver_sending",
    update_twilio_from_number: "update_twilio_from_number"
  }

  validates :record_type, presence: true
  validates :record_id, presence: true
  validates :action, presence: true

  scope :for_record, ->(record) { where(record_type: record.class.name, record_id: record.id) }
  scope :by_actor, ->(user) { where(actor_user_id: user.id) }
  scope :recent, -> { order(created_at: :desc).limit(100) }

  def self.log!(action:, record:, actor: nil, event: nil, changed_fields: {}, metadata: {})
    create!(
      action: action,
      record: record,
      actor: actor,
      event: event,
      changed_fields: changed_fields,
      metadata: metadata
    )
  end

  def readonly?
    persisted?
  end
end
