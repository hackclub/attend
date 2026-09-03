# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_03_130000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"

  create_table "accessibilities", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "communication_needs"
    t.datetime "created_at", null: false
    t.text "distance_limitations"
    t.boolean "has_adhd"
    t.boolean "has_autism"
    t.boolean "has_dyslexia"
    t.boolean "light_sensitivity", default: false
    t.text "mobility_needs"
    t.boolean "needs_captioning", default: false
    t.boolean "needs_large_print", default: false
    t.boolean "needs_sign_language", default: false
    t.text "neurodivergent_notes"
    t.boolean "noise_sensitivity", default: false
    t.text "other_needs"
    t.uuid "participant_event_id", null: false
    t.boolean "prayer_space_required", default: false
    t.text "religious_practices"
    t.boolean "requires_private_space", default: false
    t.text "sensory_needs"
    t.boolean "step_free_required", default: false
    t.boolean "strobe_sensitivity", default: false
    t.text "unavailable_times"
    t.datetime "updated_at", null: false
    t.boolean "uses_wheelchair", default: false
    t.index ["participant_event_id"], name: "index_accessibilities_on_participant_event_id"
  end

  create_table "accommodations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "accessibility_needs"
    t.string "airtable_record_id"
    t.string "assigned_room"
    t.date "check_in_date"
    t.date "check_out_date"
    t.datetime "created_at", null: false
    t.string "gender_identity"
    t.string "gender_identity_other"
    t.text "notes"
    t.uuid "participant_event_id", null: false
    t.text "preferred_roommate_genders", default: [], array: true
    t.boolean "quiet_room_preference", default: false
    t.string "room_type_preference"
    t.boolean "rooming_exempt", default: false, null: false
    t.text "roommate_exclusions"
    t.boolean "roommate_links_reviewed", default: false, null: false
    t.text "roommate_preferences"
    t.datetime "updated_at", null: false
    t.string "venue_name"
    t.index ["participant_event_id"], name: "index_accommodations_on_participant_event_id"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.string "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "audit_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "action", null: false
    t.uuid "actor_user_id"
    t.jsonb "changed_fields", default: {}
    t.datetime "created_at", null: false
    t.uuid "event_id"
    t.jsonb "metadata", default: {}
    t.uuid "record_id", null: false
    t.string "record_type", null: false
    t.index ["actor_user_id"], name: "index_audit_logs_on_actor_user_id"
    t.index ["created_at"], name: "index_audit_logs_on_created_at"
    t.index ["event_id"], name: "index_audit_logs_on_event_id"
    t.index ["record_id"], name: "index_audit_logs_on_record_id"
    t.index ["record_type", "record_id"], name: "index_audit_logs_on_record_type_and_record_id"
    t.index ["record_type"], name: "index_audit_logs_on_record_type"
  end

  create_table "audits1984_audits", force: :cascade do |t|
    t.bigint "auditor_id", null: false
    t.datetime "created_at", null: false
    t.text "notes"
    t.bigint "session_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["auditor_id"], name: "index_audits1984_audits_on_auditor_id"
    t.index ["session_id"], name: "index_audits1984_audits_on_session_id"
  end

  create_table "automated_sms_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "phone_number", null: false
    t.datetime "sent_at", null: false
    t.string "source"
    t.string "twilio_sid"
    t.datetime "updated_at", null: false
    t.index ["phone_number", "sent_at"], name: "index_automated_sms_logs_on_phone_number_and_sent_at"
    t.index ["twilio_sid"], name: "index_automated_sms_logs_on_twilio_sid", unique: true, where: "(twilio_sid IS NOT NULL)"
  end

  create_table "ban_emails", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "ban_id", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_ban_emails_on_lower_email", unique: true
    t.index ["ban_id"], name: "index_ban_emails_on_ban_id"
  end

  create_table "bans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.datetime "expires_at"
    t.text "reason"
    t.datetime "revoked_at"
    t.uuid "revoked_by_id"
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_bans_on_created_by_id"
    t.index ["expires_at"], name: "index_bans_on_expires_at"
    t.index ["revoked_at"], name: "index_bans_on_revoked_at"
    t.index ["revoked_by_id"], name: "index_bans_on_revoked_by_id"
  end

  create_table "blazer_audits", force: :cascade do |t|
    t.datetime "created_at"
    t.string "data_source"
    t.bigint "query_id"
    t.text "statement"
    t.bigint "user_id"
    t.index ["query_id"], name: "index_blazer_audits_on_query_id"
    t.index ["user_id"], name: "index_blazer_audits_on_user_id"
  end

  create_table "blazer_checks", force: :cascade do |t|
    t.string "check_type"
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.text "emails"
    t.datetime "last_run_at"
    t.text "message"
    t.bigint "query_id"
    t.string "schedule"
    t.text "slack_channels"
    t.string "state"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_checks_on_creator_id"
    t.index ["query_id"], name: "index_blazer_checks_on_query_id"
  end

  create_table "blazer_dashboard_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "dashboard_id"
    t.integer "position"
    t.bigint "query_id"
    t.datetime "updated_at", null: false
    t.index ["dashboard_id"], name: "index_blazer_dashboard_queries_on_dashboard_id"
    t.index ["query_id"], name: "index_blazer_dashboard_queries_on_query_id"
  end

  create_table "blazer_dashboards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_dashboards_on_creator_id"
  end

  create_table "blazer_queries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id"
    t.string "data_source"
    t.text "description"
    t.string "name"
    t.text "statement"
    t.string "status"
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_blazer_queries_on_creator_id"
  end

  create_table "consents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "consent_type", null: false
    t.datetime "created_at", null: false
    t.uuid "custom_document_id"
    t.string "document_url"
    t.string "docuseal_envelope_id"
    t.string "docuseal_guardian_slug"
    t.string "docuseal_host"
    t.string "docuseal_participant_slug"
    t.string "docuseal_template_id"
    t.string "failure_reason"
    t.uuid "guardian_participant_event_id"
    t.datetime "guardian_signed_at"
    t.datetime "opted_in_at"
    t.uuid "participant_event_id", null: false
    t.datetime "participant_signed_at"
    t.string "pending_on"
    t.jsonb "raw_metadata", default: {}
    t.datetime "sent_at"
    t.datetime "signed_at"
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.datetime "withdrawn_at"
    t.index ["custom_document_id"], name: "index_consents_on_custom_document_id"
    t.index ["docuseal_envelope_id"], name: "index_consents_on_docuseal_envelope_id"
    t.index ["guardian_participant_event_id"], name: "index_consents_on_guardian_participant_event_id"
    t.index ["participant_event_id", "custom_document_id"], name: "index_consents_on_pe_and_custom_document", unique: true, where: "(custom_document_id IS NOT NULL)"
    t.index ["participant_event_id"], name: "index_consents_on_participant_event_id"
  end

  create_table "console1984_commands", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "sensitive_access_id"
    t.bigint "session_id", null: false
    t.text "statements"
    t.datetime "updated_at", null: false
    t.index ["sensitive_access_id"], name: "index_console1984_commands_on_sensitive_access_id"
    t.index ["session_id", "created_at", "sensitive_access_id"], name: "on_session_and_sensitive_chronologically"
  end

  create_table "console1984_sensitive_accesses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "justification"
    t.bigint "session_id", null: false
    t.datetime "updated_at", null: false
    t.index ["session_id"], name: "index_console1984_sensitive_accesses_on_session_id"
  end

  create_table "console1984_sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "reason"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["created_at"], name: "index_console1984_sessions_on_created_at"
    t.index ["user_id", "created_at"], name: "index_console1984_sessions_on_user_id_and_created_at"
  end

  create_table "console1984_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["username"], name: "index_console1984_users_on_username"
  end

  create_table "custom_documents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "document_kind", default: "electronic", null: false
    t.string "docuseal_template_id"
    t.uuid "event_id", null: false
    t.string "name", null: false
    t.boolean "optional", default: false, null: false
    t.string "signer_type", default: "participant", null: false
    t.integer "template_page_count"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_custom_documents_on_event_id"
  end

  create_table "dietaries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "cross_contamination_risk", default: false
    t.string "diet_type"
    t.text "intolerances"
    t.text "life_threatening_allergies"
    t.text "notes"
    t.uuid "participant_event_id", null: false
    t.datetime "updated_at", null: false
    t.index ["participant_event_id"], name: "index_dietaries_on_participant_event_id"
  end

  create_table "email_log_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "email_log_id", null: false
    t.string "event_type", null: false
    t.jsonb "metadata", default: {}
    t.datetime "occurred_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email_log_id"], name: "index_email_log_events_on_email_log_id"
    t.index ["event_type"], name: "index_email_log_events_on_event_type"
    t.index ["occurred_at"], name: "index_email_log_events_on_occurred_at"
  end

  create_table "email_logs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body"
    t.text "bounce_description"
    t.string "bounce_type"
    t.datetime "bounced_at"
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.uuid "emailable_id"
    t.string "emailable_type"
    t.uuid "event_id"
    t.string "from_address", null: false
    t.string "mailer_action", null: false
    t.string "mailer_class", null: false
    t.datetime "opened_at"
    t.string "postmark_message_id"
    t.string "status", default: "sent", null: false
    t.string "subject", null: false
    t.string "to_address", null: false
    t.datetime "updated_at", null: false
    t.index ["emailable_type", "emailable_id"], name: "index_email_logs_on_emailable"
    t.index ["event_id"], name: "index_email_logs_on_event_id"
    t.index ["mailer_class"], name: "index_email_logs_on_mailer_class"
    t.index ["postmark_message_id"], name: "index_email_logs_on_postmark_message_id", unique: true, where: "(postmark_message_id IS NOT NULL)"
    t.index ["status"], name: "index_email_logs_on_status"
    t.index ["to_address"], name: "index_email_logs_on_to_address"
  end

  create_table "emergency_contacts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.uuid "guardian_participant_event_id"
    t.string "name", null: false
    t.uuid "participant_event_id"
    t.string "phone", null: false
    t.integer "priority", default: 1
    t.string "relationship"
    t.datetime "updated_at", null: false
    t.index ["guardian_participant_event_id"], name: "index_emergency_contacts_on_guardian_participant_event_id"
    t.index ["participant_event_id"], name: "index_emergency_contacts_on_participant_event_id"
  end

  create_table "event_api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["event_id", "revoked_at"], name: "index_event_api_tokens_on_event_id_and_revoked_at"
    t.index ["event_id"], name: "index_event_api_tokens_on_event_id"
    t.index ["token_digest"], name: "index_event_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_event_api_tokens_on_user_id"
  end

  create_table "event_role_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.boolean "hidden_from_public_profile", default: false, null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["event_id"], name: "index_event_role_assignments_on_event_id"
    t.index ["user_id", "event_id", "role"], name: "index_event_role_assignments_on_user_id_and_event_id_and_role", unique: true
    t.index ["user_id"], name: "index_event_role_assignments_on_user_id"
  end

  create_table "event_series", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "contact_email"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_event_series_on_slug", unique: true
  end

  create_table "events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "airtable_config_updated_by_id"
    t.text "airtable_sync_error"
    t.datetime "airtable_sync_error_at"
    t.datetime "airtable_sync_paused_at"
    t.string "airtable_sync_source_id"
    t.string "airtable_sync_table_id"
    t.datetime "airtable_synced_at"
    t.string "api_key_digest"
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.string "docuseal_adult_waiver_template_id"
    t.string "docuseal_consent_template_id"
    t.jsonb "docuseal_field_mappings", default: {}, null: false
    t.string "docuseal_freedom_waiver_template_id"
    t.string "docuseal_host"
    t.string "docuseal_minor_waiver_template_id"
    t.string "docuseal_participant_template_id"
    t.string "docuseal_waiver_template_id"
    t.datetime "ends_at"
    t.uuid "event_series_id"
    t.uuid "hotel_scan_context_id"
    t.datetime "last_slack_sync_at"
    t.string "location_address"
    t.string "location_city"
    t.string "location_country"
    t.decimal "location_latitude", precision: 10, scale: 6
    t.decimal "location_longitude", precision: 10, scale: 6
    t.string "name", null: false
    t.datetime "registration_close_at"
    t.datetime "registration_open_at"
    t.datetime "setup_completed_at"
    t.string "slack_channel_id"
    t.string "slug", null: false
    t.datetime "starts_at"
    t.string "support_email"
    t.string "timezone", default: "UTC"
    t.datetime "updated_at", null: false
    t.string "venue_name"
    t.index ["airtable_config_updated_by_id"], name: "index_events_on_airtable_config_updated_by_id"
    t.index ["event_series_id"], name: "index_events_on_event_series_id"
    t.index ["hotel_scan_context_id"], name: "index_events_on_hotel_scan_context_id"
    t.index ["slug"], name: "index_events_on_slug", unique: true
  end

  create_table "export_templates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "columns", default: [], null: false
    t.datetime "created_at", null: false
    t.uuid "created_by_id", null: false
    t.uuid "event_id", null: false
    t.jsonb "filters", default: [], null: false
    t.string "name", null: false
    t.string "row_mode", default: "participant", null: false
    t.datetime "updated_at", null: false
    t.index ["created_by_id"], name: "index_export_templates_on_created_by_id"
    t.index ["event_id", "name"], name: "index_export_templates_on_event_id_and_name", unique: true
    t.index ["event_id"], name: "index_export_templates_on_event_id"
  end

  create_table "flipper_features", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_flipper_features_on_key", unique: true
  end

  create_table "flipper_gates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "feature_key", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["feature_key", "key", "value"], name: "index_flipper_gates_on_feature_key_and_key_and_value", unique: true
  end

  create_table "global_api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["token_digest"], name: "index_global_api_tokens_on_token_digest", unique: true
    t.index ["user_id", "revoked_at"], name: "index_global_api_tokens_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_global_api_tokens_on_user_id"
  end

  create_table "group_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "group_id", null: false
    t.uuid "participant_event_id", null: false
    t.datetime "updated_at", null: false
    t.index ["group_id", "participant_event_id"], name: "idx_group_memberships_unique", unique: true
    t.index ["group_id"], name: "index_group_memberships_on_group_id"
    t.index ["participant_event_id"], name: "index_group_memberships_on_participant_event_id"
  end

  create_table "groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.text "description"
    t.uuid "event_id", null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "name"], name: "index_groups_on_event_id_and_name", unique: true
    t.index ["event_id", "position"], name: "index_groups_on_event_id_and_position"
    t.index ["event_id", "slug"], name: "index_groups_on_event_id_and_slug", unique: true
    t.index ["event_id"], name: "index_groups_on_event_id"
  end

  create_table "guardian_participant_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.string "airtable_record_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "emergency_contact_priority"
    t.boolean "emergency_medical_consent"
    t.uuid "guardian_id", null: false
    t.datetime "invite_last_used_at"
    t.string "invite_token_ciphertext"
    t.string "invite_token_digest"
    t.datetime "invite_token_sent_at"
    t.string "invited_via_email"
    t.boolean "is_primary_guardian", default: false
    t.boolean "media_permission"
    t.boolean "otc_medication_consent"
    t.uuid "participant_event_id", null: false
    t.datetime "participant_info_reviewed_at"
    t.string "phone_override"
    t.boolean "photo_permission"
    t.string "relationship"
    t.string "status", default: "pending"
    t.boolean "travel_permission"
    t.datetime "updated_at", null: false
    t.index ["guardian_id", "participant_event_id"], name: "index_guardian_participant_events_uniqueness", unique: true
    t.index ["guardian_id"], name: "index_guardian_participant_events_on_guardian_id"
    t.index ["invite_token_digest"], name: "index_guardian_participant_events_on_invite_token_digest"
    t.index ["participant_event_id"], name: "index_guardian_participant_events_on_participant_event_id"
  end

  create_table "guardians", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "address_line_1"
    t.text "address_line_2"
    t.text "city"
    t.text "country"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "email_undeliverable_at"
    t.string "legal_first_name", null: false
    t.string "legal_last_name", null: false
    t.text "phone"
    t.text "postal_code"
    t.string "relationship_default"
    t.text "state"
    t.string "time_zone", default: "UTC"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["email"], name: "index_guardians_on_email"
    t.index ["phone"], name: "index_guardians_on_phone", where: "(phone IS NOT NULL)"
    t.index ["user_id"], name: "index_guardians_on_user_id"
  end

  create_table "hospitality_acts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", null: false
    t.uuid "event_id", null: false
    t.uuid "participant_event_id"
    t.integer "points", default: 1, null: false
    t.string "source", default: "self_report", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["event_id"], name: "index_hospitality_acts_on_event_id"
    t.index ["participant_event_id"], name: "index_hospitality_acts_on_participant_event_id"
    t.index ["user_id"], name: "index_hospitality_acts_on_user_id"
  end

  create_table "hospitality_redemptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "fulfilled_at"
    t.uuid "fulfilled_by_user_id"
    t.uuid "hospitality_reward_id", null: false
    t.text "notes"
    t.integer "points_spent", null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["hospitality_reward_id"], name: "index_hospitality_redemptions_on_hospitality_reward_id"
    t.index ["user_id"], name: "index_hospitality_redemptions_on_user_id"
  end

  create_table "hospitality_rewards", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.integer "point_cost", null: false
    t.integer "stock"
    t.datetime "updated_at", null: false
  end

  create_table "import_batches", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "error_count", default: 0, null: false
    t.jsonb "errors_data", default: [], null: false
    t.uuid "event_id", null: false
    t.integer "imported_count", default: 0, null: false
    t.integer "invites_sent_count", default: 0, null: false
    t.jsonb "rows_data", default: [], null: false
    t.boolean "send_invitations", default: true, null: false
    t.integer "skipped_count", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_import_batches_on_event_id"
    t.index ["id"], name: "index_import_batches_on_id", unique: true
  end

  create_table "incident_comments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.uuid "incident_id", null: false
    t.string "new_status"
    t.string "slack_avatar_url"
    t.string "slack_channel_id"
    t.string "slack_display_name"
    t.string "slack_message_ts"
    t.string "slack_user_id"
    t.string "source"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["incident_id"], name: "index_incident_comments_on_incident_id"
    t.index ["user_id"], name: "index_incident_comments_on_user_id"
  end

  create_table "incident_helping_staff", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "incident_id", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["incident_id", "user_id"], name: "idx_incident_helping_staff_unique", unique: true
    t.index ["incident_id"], name: "index_incident_helping_staff_on_incident_id"
    t.index ["user_id"], name: "index_incident_helping_staff_on_user_id"
  end

  create_table "incident_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "incident_id", null: false
    t.uuid "participant_event_id", null: false
    t.datetime "updated_at", null: false
    t.index ["incident_id", "participant_event_id"], name: "idx_incident_participants_unique", unique: true
    t.index ["incident_id"], name: "index_incident_participants_on_incident_id"
    t.index ["participant_event_id"], name: "index_incident_participants_on_participant_event_id"
  end

  create_table "incident_report_comments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.uuid "incident_report_id", null: false
    t.string "new_status"
    t.string "slack_avatar_url"
    t.string "slack_channel_id"
    t.string "slack_display_name"
    t.string "slack_message_ts"
    t.string "slack_user_id"
    t.string "source"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["incident_report_id"], name: "index_incident_report_comments_on_incident_report_id"
    t.index ["user_id"], name: "index_incident_report_comments_on_user_id"
  end

  create_table "incident_reports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.jsonb "acknowledgements", default: [], null: false
    t.datetime "created_at", null: false
    t.string "custom_event_name"
    t.text "details", null: false
    t.boolean "emergency_services_called"
    t.uuid "event_id"
    t.string "incident_type", null: false
    t.string "priority", null: false
    t.string "reporter_email", null: false
    t.string "reporter_name", null: false
    t.string "reporter_phone", null: false
    t.string "reporter_role", null: false
    t.string "slack_channel_id"
    t.string "slack_message_ts"
    t.string "status", default: "open", null: false
    t.text "summary", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["created_at"], name: "index_incident_reports_on_created_at"
    t.index ["event_id"], name: "index_incident_reports_on_event_id"
    t.index ["priority"], name: "index_incident_reports_on_priority"
    t.index ["status"], name: "index_incident_reports_on_status"
    t.index ["user_id"], name: "index_incident_reports_on_user_id"
  end

  create_table "incidents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "actions_taken"
    t.string "category", null: false
    t.datetime "created_at", null: false
    t.text "details"
    t.uuid "event_id", null: false
    t.string "location"
    t.datetime "occurred_at"
    t.uuid "participant_event_id"
    t.uuid "reported_by_user_id", null: false
    t.string "severity", null: false
    t.string "slack_message_ts"
    t.string "status", default: "open", null: false
    t.text "summary"
    t.datetime "updated_at", null: false
    t.string "visible_to_roles", default: [], array: true
    t.index ["event_id"], name: "index_incidents_on_event_id"
    t.index ["participant_event_id"], name: "index_incidents_on_participant_event_id"
    t.index ["reported_by_user_id"], name: "index_incidents_on_reported_by_user_id"
  end

  create_table "invitations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.uuid "event_id", null: false
    t.datetime "expires_at", null: false
    t.uuid "group_ids", default: [], array: true
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["email", "event_id"], name: "index_invitations_on_email_and_event_id"
    t.index ["event_id"], name: "index_invitations_on_event_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "mcp_connection_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.uuid "mcp_connection_setting_id", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_mcp_connection_events_on_event_id"
    t.index ["mcp_connection_setting_id", "event_id"], name: "index_mcp_connection_events_on_setting_and_event", unique: true
  end

  create_table "mcp_connection_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "all_events", default: true, null: false
    t.boolean "anonymize", default: false, null: false
    t.datetime "anonymize_enabled_at"
    t.string "anonymize_enabled_by", comment: "consent | dashboard | mcp"
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.string "resource_owner_id", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id", "resource_owner_id"], name: "index_mcp_connection_settings_on_application_and_owner", unique: true
  end

  create_table "medicals", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "additional_notes"
    t.text "allergies"
    t.string "allergy_severity"
    t.datetime "created_at", null: false
    t.text "emergency_action_plan"
    t.boolean "has_anaphylaxis_risk", default: false
    t.uuid "last_updated_by_user_id"
    t.text "medical_conditions"
    t.text "medications"
    t.uuid "participant_event_id", null: false
    t.boolean "requires_refrigeration", default: false
    t.datetime "updated_at", null: false
    t.index ["last_updated_by_user_id"], name: "index_medicals_on_last_updated_by_user_id"
    t.index ["participant_event_id"], name: "index_medicals_on_participant_event_id"
  end

  create_table "message_deliveries", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.text "error_message"
    t.string "external_id"
    t.uuid "guardian_id"
    t.uuid "message_id", null: false
    t.uuid "participant_event_id"
    t.datetime "read_at"
    t.string "recipient_email"
    t.string "recipient_phone"
    t.string "recipient_slack_id"
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.index ["guardian_id"], name: "index_message_deliveries_on_guardian_id"
    t.index ["message_id", "channel"], name: "index_message_deliveries_on_message_id_and_channel"
    t.index ["message_id"], name: "index_message_deliveries_on_message_id"
    t.index ["participant_event_id"], name: "index_message_deliveries_on_participant_event_id"
    t.index ["status"], name: "index_message_deliveries_on_status"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "audience", null: false
    t.jsonb "audience_filters", default: {}
    t.text "body", null: false
    t.string "channels", default: [], array: true
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.integer "failed_count", default: 0
    t.integer "recipient_count", default: 0
    t.datetime "scheduled_at"
    t.datetime "sent_at"
    t.uuid "sent_by_user_id", null: false
    t.integer "sent_count", default: 0
    t.string "status", default: "draft"
    t.string "subject"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_messages_on_event_id"
    t.index ["scheduled_at"], name: "index_messages_on_scheduled_at"
    t.index ["sent_by_user_id"], name: "index_messages_on_sent_by_user_id"
    t.index ["status"], name: "index_messages_on_status"
  end

  create_table "mobile_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "device_name"
    t.datetime "expires_at", null: false
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["token_digest"], name: "index_mobile_tokens_on_token_digest", unique: true
    t.index ["user_id", "revoked_at"], name: "index_mobile_tokens_on_user_id_and_revoked_at"
    t.index ["user_id"], name: "index_mobile_tokens_on_user_id"
  end

  create_table "nfc_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "paired_at"
    t.uuid "paired_by_id"
    t.datetime "revoked_at"
    t.uuid "revoked_by_id"
    t.uuid "token", default: -> { "gen_random_uuid()" }, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["paired_by_id"], name: "index_nfc_tokens_on_paired_by_id"
    t.index ["revoked_by_id"], name: "index_nfc_tokens_on_revoked_by_id"
    t.index ["token"], name: "index_nfc_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_nfc_tokens_on_user_id"
  end

  create_table "notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "author_user_id", null: false
    t.text "body"
    t.datetime "created_at", null: false
    t.uuid "event_id"
    t.string "note_type"
    t.uuid "participant_event_id"
    t.string "sensitivity", default: "normal"
    t.uuid "ticket_id"
    t.datetime "updated_at", null: false
    t.string "visible_to_roles", default: [], array: true
    t.index ["author_user_id"], name: "index_notes_on_author_user_id"
    t.index ["event_id"], name: "index_notes_on_event_id"
    t.index ["participant_event_id"], name: "index_notes_on_participant_event_id"
    t.index ["ticket_id"], name: "index_notes_on_ticket_id"
  end

  create_table "participant_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "airtable_record_id"
    t.datetime "code_of_conduct_accepted_at"
    t.string "code_of_conduct_signature"
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.boolean "hidden_from_public_profile", default: false, null: false
    t.datetime "nfc_badge_assigned_at"
    t.uuid "nfc_badge_assigned_by_id"
    t.uuid "nfc_badge_token", default: -> { "gen_random_uuid()" }
    t.datetime "onboarding_completed_at"
    t.jsonb "onboarding_payload", default: {}
    t.integer "onboarding_step", default: 0
    t.uuid "participant_id", null: false
    t.string "slack_user_id"
    t.string "status", default: "invited", null: false
    t.string "totp_secret"
    t.datetime "um_guardian_confirmed_at"
    t.datetime "um_review_requested_at"
    t.string "um_status", default: "none", null: false
    t.datetime "um_verified_at"
    t.uuid "um_verified_by_id"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_participant_events_on_event_id"
    t.index ["nfc_badge_token"], name: "index_participant_events_on_nfc_badge_token", unique: true
    t.index ["participant_id", "event_id"], name: "index_participant_events_on_participant_id_and_event_id", unique: true
    t.index ["participant_id"], name: "index_participant_events_on_participant_id"
    t.index ["status"], name: "index_participant_events_on_status"
    t.index ["totp_secret"], name: "index_participant_events_on_totp_secret", unique: true
    t.index ["um_status"], name: "index_participant_events_on_um_status"
    t.index ["um_verified_by_id"], name: "index_participant_events_on_um_verified_by_id"
  end

  create_table "participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "address_line_1"
    t.string "address_line_2"
    t.string "city"
    t.string "country_of_residence"
    t.datetime "created_at", null: false
    t.date "date_of_birth"
    t.string "email", null: false
    t.datetime "email_undeliverable_at"
    t.text "engagement_notes"
    t.string "engagement_preference"
    t.string "legal_first_name", null: false
    t.string "legal_last_name", null: false
    t.string "phone"
    t.string "postal_code"
    t.string "preferred_name"
    t.string "pronouns"
    t.text "public_profile_bio"
    t.string "public_profile_bluesky"
    t.boolean "public_profile_enabled", default: false, null: false
    t.string "public_profile_github"
    t.string "public_profile_linkedin"
    t.string "public_profile_location"
    t.string "public_profile_mastodon"
    t.boolean "public_profile_show_photo", default: false, null: false
    t.string "public_profile_slug"
    t.string "public_profile_twitter"
    t.string "public_profile_website"
    t.string "slack_user_id"
    t.string "state"
    t.string "tshirt_size"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["email"], name: "index_participants_on_email"
    t.index ["email"], name: "index_participants_on_email_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["legal_first_name"], name: "index_participants_on_legal_first_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["legal_last_name"], name: "index_participants_on_legal_last_name"
    t.index ["legal_last_name"], name: "index_participants_on_legal_last_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["phone"], name: "index_participants_on_phone", where: "(phone IS NOT NULL)"
    t.index ["preferred_name"], name: "index_participants_on_preferred_name_trgm", opclass: :gin_trgm_ops, using: :gin
    t.index ["public_profile_slug"], name: "index_participants_on_public_profile_slug", unique: true
    t.index ["user_id"], name: "index_participants_on_user_id"
  end

  create_table "passkit_devices", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "identifier"
    t.string "push_token"
    t.datetime "updated_at", null: false
    t.index ["identifier"], name: "index_passkit_devices_on_identifier", unique: true
  end

  create_table "passkit_logs", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "passkit_passes", force: :cascade do |t|
    t.string "authentication_token"
    t.datetime "created_at", null: false
    t.json "data"
    t.uuid "generator_id"
    t.string "generator_type"
    t.string "klass"
    t.string "serial_number"
    t.datetime "updated_at", null: false
    t.integer "version"
    t.index ["generator_type", "generator_id"], name: "index_passkit_passes_on_generator"
  end

  create_table "passkit_registrations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "passkit_device_id"
    t.bigint "passkit_pass_id"
    t.datetime "updated_at", null: false
    t.index ["passkit_device_id"], name: "index_passkit_registrations_on_passkit_device_id"
    t.index ["passkit_pass_id"], name: "index_passkit_registrations_on_passkit_pass_id"
  end

  create_table "passports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "paired_at"
    t.uuid "paired_by_id"
    t.datetime "revoked_at"
    t.uuid "revoked_by_id"
    t.string "serial_number", null: false
    t.uuid "token", default: -> { "gen_random_uuid()" }, null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["paired_by_id"], name: "index_passports_on_paired_by_id"
    t.index ["revoked_by_id"], name: "index_passports_on_revoked_by_id"
    t.index ["serial_number"], name: "index_passports_on_serial_number", unique: true
    t.index ["token"], name: "index_passports_on_token", unique: true
    t.index ["user_id"], name: "index_passports_on_user_id"
  end

  create_table "push_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "platform"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["token"], name: "index_push_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_push_tokens_on_user_id"
  end

  create_table "room_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "flags", default: {}, null: false
    t.uuid "participant_event_id", null: false
    t.uuid "room_id", null: false
    t.boolean "staff_override", default: false, null: false
    t.text "staff_override_notes"
    t.boolean "trans_nb_acknowledged", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["participant_event_id"], name: "index_room_assignments_on_participant_event_id", unique: true
    t.index ["room_id"], name: "index_room_assignments_on_room_id"
  end

  create_table "rooming_plans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "created_by_user_id"
    t.uuid "event_id", null: false
    t.datetime "finalized_at"
    t.uuid "finalized_by_user_id"
    t.boolean "locked", default: false, null: false
    t.integer "room_capacity", default: 2, null: false
    t.jsonb "settings", default: {}, null: false
    t.string "status", default: "draft", null: false
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_rooming_plans_on_event_id", unique: true
  end

  create_table "roommate_exclusions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "admin_confirmed", default: false, null: false
    t.datetime "created_at", null: false
    t.uuid "excluded_participant_event_id", null: false
    t.uuid "participant_event_id", null: false
    t.datetime "updated_at", null: false
    t.index ["participant_event_id", "excluded_participant_event_id"], name: "idx_roommate_exclusions_unique_pair", unique: true
  end

  create_table "roommate_preferences", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "admin_confirmed", default: false, null: false
    t.datetime "created_at", null: false
    t.uuid "participant_event_id", null: false
    t.uuid "preferred_participant_event_id", null: false
    t.integer "rank"
    t.datetime "updated_at", null: false
    t.index ["participant_event_id", "preferred_participant_event_id"], name: "idx_roommate_prefs_unique_pair", unique: true
  end

  create_table "rooms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "capacity", default: 2, null: false
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.string "gender_label"
    t.string "name"
    t.text "notes"
    t.integer "position"
    t.text "staff_names"
    t.boolean "staff_only", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["event_id", "name"], name: "index_rooms_on_event_id_and_name", unique: true, where: "(name IS NOT NULL)"
    t.index ["event_id", "position"], name: "index_rooms_on_event_id_and_position"
    t.index ["event_id"], name: "index_rooms_on_event_id"
  end

  create_table "safeguarding_infos", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "authorized_pickup_adults"
    t.boolean "can_leave_unaccompanied", default: false
    t.datetime "created_at", null: false
    t.boolean "freedom_waiver_granted", default: false
    t.boolean "high_support_flag", default: false
    t.text "high_support_notes"
    t.text "other_instructions"
    t.uuid "participant_event_id", null: false
    t.datetime "updated_at", null: false
    t.index ["participant_event_id"], name: "index_safeguarding_infos_on_participant_event_id"
  end

  create_table "scan_contexts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "checks_in", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "ends_at"
    t.uuid "event_id", null: false
    t.boolean "is_airport", default: false, null: false
    t.boolean "is_travel_pickup", default: false, null: false
    t.string "name", null: false
    t.integer "position", default: 0, null: false
    t.datetime "starts_at"
    t.datetime "updated_at", null: false
    t.index ["event_id", "position"], name: "index_scan_contexts_on_event_id_and_position"
    t.index ["event_id"], name: "index_scan_contexts_on_event_id"
  end

  create_table "scans", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "client_scan_id"
    t.datetime "created_at", null: false
    t.uuid "participant_event_id", null: false
    t.uuid "scan_context_id"
    t.datetime "scanned_at", null: false
    t.string "source", default: "qr"
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["client_scan_id"], name: "index_scans_on_client_scan_id", unique: true, where: "(client_scan_id IS NOT NULL)"
    t.index ["id"], name: "index_scans_on_id", unique: true
    t.index ["participant_event_id", "scanned_at"], name: "index_scans_on_participant_event_id_and_scanned_at"
    t.index ["participant_event_id"], name: "index_scans_on_participant_event_id"
    t.index ["scan_context_id"], name: "index_scans_on_scan_context_id"
    t.index ["user_id"], name: "index_scans_on_user_id"
  end

  create_table "series_api_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_series_id", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["event_series_id", "revoked_at"], name: "index_series_api_tokens_on_event_series_id_and_revoked_at"
    t.index ["event_series_id"], name: "index_series_api_tokens_on_event_series_id"
    t.index ["token_digest"], name: "index_series_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_series_api_tokens_on_user_id"
  end

  create_table "series_role_assignments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_series_id", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.uuid "user_id", null: false
    t.index ["event_series_id"], name: "index_series_role_assignments_on_event_series_id"
    t.index ["user_id", "event_series_id"], name: "index_series_role_assignments_on_user_id_and_event_series_id", unique: true
    t.index ["user_id"], name: "index_series_role_assignments_on_user_id"
  end

  create_table "settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["key"], name: "index_settings_on_key", unique: true
  end

  create_table "sibling_groups", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label"
    t.datetime "updated_at", null: false
  end

  create_table "sibling_memberships", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "participant_id", null: false
    t.uuid "sibling_group_id", null: false
    t.datetime "updated_at", null: false
    t.index ["sibling_group_id", "participant_id"], name: "idx_sibling_memberships_unique", unique: true
  end

  create_table "slack_blast_recipients", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error_message"
    t.uuid "participant_event_id", null: false
    t.uuid "slack_blast_id", null: false
    t.string "slack_message_ts"
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.index ["participant_event_id"], name: "index_slack_blast_recipients_on_participant_event_id"
    t.index ["slack_blast_id"], name: "index_slack_blast_recipients_on_slack_blast_id"
  end

  create_table "slack_blasts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.uuid "event_id", null: false
    t.integer "failed_count", default: 0
    t.text "message"
    t.integer "recipient_count", default: 0
    t.uuid "sent_by_user_id", null: false
    t.integer "sent_count", default: 0
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.index ["event_id"], name: "index_slack_blasts_on_event_id"
    t.index ["sent_by_user_id"], name: "index_slack_blasts_on_sent_by_user_id"
  end

  create_table "ticket_messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.boolean "automated", default: false, null: false
    t.text "body", null: false
    t.string "channel", null: false
    t.datetime "created_at", null: false
    t.string "direction", null: false
    t.text "error_message"
    t.uuid "merged_from_ticket_id"
    t.jsonb "raw_payload", default: {}
    t.datetime "sent_at"
    t.string "signal_message_sid"
    t.uuid "ticket_id", null: false
    t.string "twilio_message_sid"
    t.string "twilio_status"
    t.datetime "updated_at", null: false
    t.uuid "user_id"
    t.index ["direction"], name: "index_ticket_messages_on_direction"
    t.index ["merged_from_ticket_id"], name: "index_ticket_messages_on_merged_from_ticket_id"
    t.index ["signal_message_sid"], name: "index_ticket_messages_on_signal_message_sid", unique: true, where: "(signal_message_sid IS NOT NULL)"
    t.index ["ticket_id"], name: "index_ticket_messages_on_ticket_id"
    t.index ["twilio_message_sid"], name: "index_ticket_messages_on_twilio_message_sid", unique: true, where: "(twilio_message_sid IS NOT NULL)"
    t.index ["user_id"], name: "index_ticket_messages_on_user_id"
  end

  create_table "tickets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "assigned_to_id"
    t.string "channel", null: false
    t.datetime "closed_at"
    t.uuid "closed_by_id"
    t.datetime "created_at", null: false
    t.uuid "created_by_id"
    t.uuid "event_id"
    t.datetime "last_inbound_at"
    t.datetime "last_message_at"
    t.datetime "last_outbound_at"
    t.datetime "merged_at"
    t.uuid "merged_by_id"
    t.uuid "merged_into_id"
    t.string "phone_number", null: false
    t.string "status", default: "open", null: false
    t.uuid "subject_id"
    t.string "subject_type"
    t.string "twilio_to_number"
    t.datetime "updated_at", null: false
    t.index ["assigned_to_id"], name: "index_tickets_on_assigned_to_id"
    t.index ["channel", "phone_number", "status"], name: "idx_tickets_by_phone_chan_status"
    t.index ["closed_by_id"], name: "index_tickets_on_closed_by_id"
    t.index ["created_by_id"], name: "index_tickets_on_created_by_id"
    t.index ["event_id"], name: "index_tickets_on_event_id"
    t.index ["merged_by_id"], name: "index_tickets_on_merged_by_id"
    t.index ["merged_into_id"], name: "index_tickets_on_merged_into_id"
    t.index ["phone_number"], name: "index_tickets_on_phone_number"
    t.index ["status"], name: "index_tickets_on_status"
    t.index ["subject_type", "subject_id"], name: "index_tickets_on_subject_type_and_subject_id"
  end

  create_table "toolchest_oauth_access_grants", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.string "code_challenge"
    t.string "code_challenge_method"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "mount_key", default: "default", null: false
    t.text "redirect_uri", null: false
    t.string "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_toolchest_oauth_access_grants_on_application_id"
    t.index ["token_digest"], name: "index_toolchest_oauth_access_grants_on_token_digest", unique: true
  end

  create_table "toolchest_oauth_access_tokens", force: :cascade do |t|
    t.bigint "application_id", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "mount_key", default: "default", null: false
    t.string "refresh_token"
    t.string "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_toolchest_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_toolchest_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["token"], name: "index_toolchest_oauth_access_tokens_on_token", unique: true
  end

  create_table "toolchest_oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret"
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["uid"], name: "index_toolchest_oauth_applications_on_uid", unique: true
  end

  create_table "travel_legs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "arrival_airport"
    t.datetime "arrival_time"
    t.string "confirmation_code"
    t.datetime "created_at", null: false
    t.string "departure_airport"
    t.datetime "departure_time"
    t.string "flight_code"
    t.datetime "last_tracked_at"
    t.datetime "live_arrival_time"
    t.jsonb "live_data"
    t.datetime "live_departure_time"
    t.string "live_status"
    t.jsonb "oag_flight_data"
    t.string "oag_schedule_instance_key"
    t.uuid "picked_up_by_user_id"
    t.integer "position", default: 0
    t.uuid "travel_id", null: false
    t.datetime "travel_picked_up_at"
    t.datetime "updated_at", null: false
    t.index ["picked_up_by_user_id"], name: "index_travel_legs_on_picked_up_by_user_id"
    t.index ["travel_id"], name: "index_travel_legs_on_travel_id"
  end

  create_table "travels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "arrival_city"
    t.string "arrival_station"
    t.datetime "arrival_time"
    t.string "bus_arrival_location"
    t.string "bus_departure_location"
    t.string "carrier"
    t.datetime "created_at", null: false
    t.string "departure_city"
    t.string "departure_station"
    t.datetime "departure_time"
    t.string "direction", null: false
    t.datetime "expected_arrival_time"
    t.string "flight_number"
    t.boolean "is_unaccompanied_minor", default: false
    t.string "mode"
    t.text "notes"
    t.text "origin_address"
    t.text "other_details"
    t.uuid "participant_event_id", null: false
    t.string "passport_nationality"
    t.datetime "pickup_dismissed_at"
    t.string "train_arrival_station"
    t.string "train_departure_station"
    t.datetime "updated_at", null: false
    t.string "visa_number"
    t.boolean "visa_required", default: false
    t.string "visa_status"
    t.string "visa_type"
    t.index ["participant_event_id"], name: "index_travels_on_participant_event_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "current_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "display_name"
    t.string "email", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "global_role", default: "none"
    t.string "hack_club_account_id"
    t.datetime "last_sign_in_at"
    t.string "last_sign_in_ip"
    t.string "name"
    t.jsonb "oidc_claims", default: {}
    t.string "phone_number"
    t.datetime "remember_created_at"
    t.datetime "reset_password_sent_at"
    t.string "reset_password_token"
    t.integer "sign_in_count", default: 0, null: false
    t.string "slack_user_id"
    t.string "theme"
    t.string "time_zone", default: "UTC"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["global_role"], name: "index_users_on_global_role"
    t.index ["hack_club_account_id"], name: "index_users_on_hack_club_account_id", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
  end

  create_table "versions", force: :cascade do |t|
    t.datetime "created_at"
    t.string "event", null: false
    t.uuid "item_id", null: false
    t.string "item_type", null: false
    t.text "object"
    t.text "object_changes"
    t.string "whodunnit"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  add_foreign_key "accessibilities", "participant_events"
  add_foreign_key "accommodations", "participant_events"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "audit_logs", "events"
  add_foreign_key "audit_logs", "users", column: "actor_user_id"
  add_foreign_key "ban_emails", "bans"
  add_foreign_key "bans", "users", column: "created_by_id"
  add_foreign_key "bans", "users", column: "revoked_by_id"
  add_foreign_key "consents", "custom_documents"
  add_foreign_key "consents", "guardian_participant_events"
  add_foreign_key "consents", "participant_events"
  add_foreign_key "custom_documents", "events"
  add_foreign_key "dietaries", "participant_events"
  add_foreign_key "email_log_events", "email_logs"
  add_foreign_key "email_logs", "events"
  add_foreign_key "emergency_contacts", "guardian_participant_events"
  add_foreign_key "emergency_contacts", "participant_events"
  add_foreign_key "event_api_tokens", "events"
  add_foreign_key "event_api_tokens", "users", on_delete: :nullify
  add_foreign_key "event_role_assignments", "events"
  add_foreign_key "event_role_assignments", "users"
  add_foreign_key "events", "event_series"
  add_foreign_key "events", "scan_contexts", column: "hotel_scan_context_id"
  add_foreign_key "events", "users", column: "airtable_config_updated_by_id"
  add_foreign_key "export_templates", "events"
  add_foreign_key "export_templates", "users", column: "created_by_id"
  add_foreign_key "global_api_tokens", "users", on_delete: :cascade
  add_foreign_key "group_memberships", "groups"
  add_foreign_key "group_memberships", "participant_events"
  add_foreign_key "groups", "events"
  add_foreign_key "guardian_participant_events", "guardians"
  add_foreign_key "guardian_participant_events", "participant_events"
  add_foreign_key "guardians", "users"
  add_foreign_key "hospitality_acts", "events"
  add_foreign_key "hospitality_acts", "participant_events"
  add_foreign_key "hospitality_acts", "users"
  add_foreign_key "hospitality_redemptions", "hospitality_rewards"
  add_foreign_key "hospitality_redemptions", "users"
  add_foreign_key "hospitality_redemptions", "users", column: "fulfilled_by_user_id"
  add_foreign_key "import_batches", "events"
  add_foreign_key "incident_comments", "incidents"
  add_foreign_key "incident_comments", "users"
  add_foreign_key "incident_helping_staff", "incidents"
  add_foreign_key "incident_helping_staff", "users"
  add_foreign_key "incident_participants", "incidents"
  add_foreign_key "incident_participants", "participant_events"
  add_foreign_key "incident_report_comments", "incident_reports"
  add_foreign_key "incident_report_comments", "users"
  add_foreign_key "incident_reports", "events"
  add_foreign_key "incident_reports", "users"
  add_foreign_key "incidents", "events"
  add_foreign_key "incidents", "participant_events"
  add_foreign_key "incidents", "users", column: "reported_by_user_id"
  add_foreign_key "invitations", "events"
  add_foreign_key "mcp_connection_events", "events"
  add_foreign_key "mcp_connection_events", "mcp_connection_settings"
  add_foreign_key "mcp_connection_settings", "toolchest_oauth_applications", column: "application_id"
  add_foreign_key "medicals", "participant_events"
  add_foreign_key "medicals", "users", column: "last_updated_by_user_id"
  add_foreign_key "message_deliveries", "guardians"
  add_foreign_key "message_deliveries", "messages"
  add_foreign_key "message_deliveries", "participant_events"
  add_foreign_key "messages", "events"
  add_foreign_key "messages", "users", column: "sent_by_user_id"
  add_foreign_key "mobile_tokens", "users"
  add_foreign_key "nfc_tokens", "users"
  add_foreign_key "nfc_tokens", "users", column: "paired_by_id"
  add_foreign_key "nfc_tokens", "users", column: "revoked_by_id"
  add_foreign_key "notes", "events"
  add_foreign_key "notes", "participant_events"
  add_foreign_key "notes", "tickets"
  add_foreign_key "notes", "users", column: "author_user_id"
  add_foreign_key "participant_events", "events"
  add_foreign_key "participant_events", "participants"
  add_foreign_key "participant_events", "users", column: "nfc_badge_assigned_by_id"
  add_foreign_key "participant_events", "users", column: "um_verified_by_id"
  add_foreign_key "participants", "users"
  add_foreign_key "passports", "users"
  add_foreign_key "passports", "users", column: "paired_by_id"
  add_foreign_key "passports", "users", column: "revoked_by_id"
  add_foreign_key "push_tokens", "users"
  add_foreign_key "room_assignments", "participant_events"
  add_foreign_key "room_assignments", "rooms"
  add_foreign_key "rooming_plans", "events"
  add_foreign_key "rooming_plans", "users", column: "created_by_user_id"
  add_foreign_key "rooming_plans", "users", column: "finalized_by_user_id"
  add_foreign_key "roommate_exclusions", "participant_events"
  add_foreign_key "roommate_exclusions", "participant_events", column: "excluded_participant_event_id"
  add_foreign_key "roommate_preferences", "participant_events"
  add_foreign_key "roommate_preferences", "participant_events", column: "preferred_participant_event_id"
  add_foreign_key "rooms", "events"
  add_foreign_key "safeguarding_infos", "participant_events"
  add_foreign_key "scan_contexts", "events"
  add_foreign_key "scans", "participant_events"
  add_foreign_key "scans", "scan_contexts"
  add_foreign_key "scans", "users"
  add_foreign_key "series_api_tokens", "event_series"
  add_foreign_key "series_api_tokens", "users", on_delete: :nullify
  add_foreign_key "series_role_assignments", "event_series"
  add_foreign_key "series_role_assignments", "users"
  add_foreign_key "sibling_memberships", "participants"
  add_foreign_key "sibling_memberships", "sibling_groups"
  add_foreign_key "slack_blast_recipients", "participant_events"
  add_foreign_key "slack_blast_recipients", "slack_blasts"
  add_foreign_key "slack_blasts", "events"
  add_foreign_key "slack_blasts", "users", column: "sent_by_user_id"
  add_foreign_key "ticket_messages", "tickets"
  add_foreign_key "ticket_messages", "tickets", column: "merged_from_ticket_id"
  add_foreign_key "ticket_messages", "users"
  add_foreign_key "tickets", "events"
  add_foreign_key "tickets", "tickets", column: "merged_into_id"
  add_foreign_key "tickets", "users", column: "assigned_to_id"
  add_foreign_key "tickets", "users", column: "closed_by_id"
  add_foreign_key "tickets", "users", column: "created_by_id"
  add_foreign_key "tickets", "users", column: "merged_by_id"
  add_foreign_key "toolchest_oauth_access_grants", "toolchest_oauth_applications", column: "application_id"
  add_foreign_key "toolchest_oauth_access_tokens", "toolchest_oauth_applications", column: "application_id"
  add_foreign_key "travel_legs", "travels"
  add_foreign_key "travels", "participant_events"
end
