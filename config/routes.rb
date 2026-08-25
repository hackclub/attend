Rails.application.routes.draw do
  toolchest_oauth
  mount Toolchest::Engine => "/mcp"
  mount ActionCable.server => "/cable"
  mount Passkit::Engine => "/passkit", as: "passkit"
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  # Admin-only dashboards
  authenticate :user, ->(user) { user.global_admin? } do
    mount Blazer::Engine, at: "/admin/blazer"
    # mount Audits1984::Engine, at: "/admin/console"  # TEMPORARILY DISABLED
    mount MissionControl::Jobs::Engine, at: "/admin/jobs"
  end
  devise_for :users, controllers: {
    omniauth_callbacks: "users/omniauth_callbacks"
  }, skip: [ :sessions, :passwords, :registrations ]

  devise_scope :user do
    delete "sign_out", to: "devise/sessions#destroy", as: :destroy_user_session
  end

  root "home#index"

  # Admin-only API reference (Scalar). The OpenAPI document is served through
  # the controller so it stays behind the same admin gate as the page itself.
  get "docs", to: "docs#index"
  get "docs/openapi.json", to: "docs#openapi", as: :docs_openapi

  # Opt-in public participant profiles (attend.hackclub.com/p/:slug)
  get "p/:slug/markers", to: "public_profiles#markers", as: :public_profile_markers, constraints: { slug: /[A-Za-z0-9-]+/ }, defaults: { format: :json }
  get "p/:slug", to: "public_profiles#show", as: :public_profile, constraints: { slug: /[A-Za-z0-9-]+/ }

  # Public incident reporting (attend.hackclub.com/incident)
  get "incident", to: "incident_reports#new", as: :incident_report
  post "incident", to: "incident_reports#create"
  get "incident/submitted", to: "incident_reports#submitted", as: :incident_report_submitted

  # Slack OAuth
  get "slack/oauth/callback", to: "slack_oauth#callback", as: :slack_oauth_callback
  get "slack/connect/:token", to: "slack_oauth#connect", as: :slack_connect
  get "slack/success", to: "slack_oauth#success", as: :slack_success
  get "slack/error", to: "slack_oauth#error", as: :slack_error

  delete "stop_impersonation", to: "impersonations#destroy", as: :stop_impersonation

  # Support / Chat system
  namespace :support do
    resources :tickets, only: %i[index show] do
      member do
        patch :close
        patch :reopen
        patch :assign
        patch :set_event
        patch :set_subject
        patch :merge
      end

      resources :messages, only: :create, module: :tickets
      resources :notes, only: %i[create destroy], module: :tickets
    end
  end

  # Twilio webhooks
  namespace :twilio do
    post "incoming", to: "incoming_messages#create"
    post "status", to: "status_callbacks#create"
    post "voice", to: "voice#incoming"
    post "incidents/:id/voice", to: "incident_calls#voice", as: :incident_voice
    post "incidents/:id/gather", to: "incident_calls#gather", as: :incident_gather
  end

  # Signal webhooks
  namespace :signal do
    post "incoming", to: "incoming_messages#create"
  end

  if Rails.env.development?
    post "dev_sign_in", to: "home#dev_sign_in"
  end

  get "dashboard", to: "dashboard#index"
  get "dashboard/profile", to: "dashboard#profile", as: :dashboard_profile
  patch "dashboard/public_profile", to: "dashboard#update_public_profile", as: :dashboard_public_profile
  patch "dashboard/staff_profile", to: "dashboard#update_staff_profile", as: :dashboard_staff_profile
  delete "dashboard/staff_profile/avatar", to: "dashboard#destroy_staff_avatar", as: :dashboard_staff_profile_avatar
  delete "dashboard/mcp_connections/:id", to: "dashboard#revoke_mcp_connection", as: :dashboard_mcp_connection
  patch "dashboard/mcp_connections/:id", to: "dashboard#update_mcp_connection", as: :update_dashboard_mcp_connection
  post "theme", to: "themes#update", as: :update_theme
  get "dashboard/events/:id", to: "dashboard#show", as: :dashboard_event
  get "dashboard/events/:id/google_wallet", to: "dashboard#google_wallet", as: :dashboard_google_wallet
  get "dashboard/events/:id/download_ticket", to: "dashboard#download_ticket", as: :dashboard_download_ticket
  get "dashboard/events/:id/download_excuse_letter", to: "dashboard#download_excuse_letter", as: :dashboard_download_excuse_letter
  get "dashboard/events/:id/documents/:custom_document_id", to: "dashboard#sign_document", as: :dashboard_sign_document
  post "dashboard/events/:id/documents/:custom_document_id/add", to: "dashboard#add_optional_document", as: :dashboard_add_optional_document
  delete "dashboard/events/:id/documents/:custom_document_id/add", to: "dashboard#withdraw_optional_document", as: :dashboard_withdraw_optional_document
  post "dashboard/events/:id/documents/:custom_document_id/upload", to: "dashboard#upload_physical_document", as: :dashboard_upload_physical_document
  delete "dashboard/events/:id/documents/:custom_document_id/uploads/:upload_id", to: "dashboard#remove_physical_upload", as: :dashboard_remove_physical_upload
  post "dashboard/events/:id/resend_guardian_invite", to: "dashboard#resend_guardian_invite", as: :dashboard_resend_guardian_invite
  get "dashboard/events/:id/travel/edit", to: "dashboard#edit_travel", as: :dashboard_event_travel_edit
  patch "dashboard/events/:id/travel", to: "dashboard#update_travel", as: :dashboard_event_travel

  scope "/dashboard" do
    resources :messages, only: [ :index, :show ], controller: "dashboard/messages", as: :dashboard_messages
  end

  scope "/onboarding" do
    get "/", to: "onboarding#index", as: :onboarding
    get "/waiver", to: "onboarding#waiver", as: :onboarding_waiver
    post "/waiver/complete", to: "onboarding#waiver_complete", as: :onboarding_waiver_complete
    post "/documents/:consent_id/signed", to: "onboarding#document_signed", as: :onboarding_document_signed
    get "/documents/status", to: "onboarding#documents_status", as: :onboarding_documents_status
    post "/optional_documents/:custom_document_id", to: "onboarding#add_optional_document", as: :onboarding_add_optional_document
    delete "/optional_documents/:custom_document_id", to: "onboarding#withdraw_optional_document", as: :onboarding_withdraw_optional_document
    post "/documents/:consent_id/physical_upload", to: "onboarding#physical_document_upload", as: :onboarding_physical_document_upload
    delete "/documents/:consent_id/physical_uploads/:upload_id", to: "onboarding#remove_physical_upload", as: :onboarding_remove_physical_upload
    get "/:step", to: "onboarding#show", as: :onboarding_step
    patch "/:step", to: "onboarding#update"
    post "/complete", to: "onboarding#complete", as: :complete_onboarding
  end

  scope "/guardian" do
    get "/invite/:token", to: "guardian_portal#show", as: :guardian_invite
    get "/portal/:token", to: "guardian_portal#show", as: :guardian_portal
    patch "/invite/:token", to: "guardian_portal#update"
    get "/invite/:token/step/:step", to: "guardian_portal#step", as: :guardian_portal_step
    patch "/invite/:token/step/:step", to: "guardian_portal#update_step", as: :guardian_portal_update_step
    post "/invite/:token/complete", to: "guardian_portal#complete", as: :guardian_portal_complete
    get "/invite/:token/confirmed", to: "guardian_portal#confirmed", as: :guardian_portal_confirmed
    get "/invite/:token/waiver", to: "guardian_portal#waiver", as: :guardian_portal_waiver
    post "/invite/:token/waiver/complete", to: "guardian_portal#waiver_complete", as: :guardian_portal_waiver_complete
    get "/invite/:token/freedom_waiver", to: "guardian_portal#freedom_waiver", as: :guardian_portal_freedom_waiver
    post "/invite/:token/freedom_waiver/complete", to: "guardian_portal#freedom_waiver_complete", as: :guardian_portal_freedom_waiver_complete
    get "/invite/:token/documents/:custom_document_id", to: "guardian_portal#custom_document", as: :guardian_portal_custom_document
    post "/invite/:token/documents/:custom_document_id/complete", to: "guardian_portal#custom_document_complete", as: :guardian_portal_custom_document_complete
    post "/invite/:token/documents/:custom_document_id/verify", to: "guardian_portal#verify_physical_document", as: :guardian_portal_verify_physical_document
    post "/invite/:token/documents/:custom_document_id/upload", to: "guardian_portal#upload_physical_document", as: :guardian_portal_upload_physical_document
    delete "/invite/:token/documents/:custom_document_id/uploads/:upload_id", to: "guardian_portal#remove_physical_upload", as: :guardian_portal_remove_physical_upload
    get "/invite/:token/expired", to: "guardian_portal#expired", as: :guardian_portal_expired
    get "/invite/:token/withdrawn", to: "guardian_portal#withdrawn", as: :guardian_portal_withdrawn

    # Portal center: guardians verify their email/phone to find every portal
    # linked to that contact — pending and completed — without needing the
    # original invite link.
    get "/portals", to: "guardian_portal_center#new", as: :guardian_portal_center
    post "/portals/code", to: "guardian_portal_center#request_code", as: :guardian_portal_center_request_code
    get "/portals/verify", to: "guardian_portal_center#verify_form", as: :guardian_portal_center_verify
    post "/portals/verify", to: "guardian_portal_center#verify"
    get "/portals/overview", to: "guardian_portal_center#show", as: :guardian_portal_center_portals
    post "/portals/:id/open", to: "guardian_portal_center#open_portal", as: :guardian_portal_center_open
    delete "/portals/session", to: "guardian_portal_center#destroy", as: :guardian_portal_center_session
  end

  namespace :admin do
    root "dashboard#index"

    get "search", to: "search#index"

    # The staff profile form now lives on the participant-facing settings page.
    get "profile/edit", to: redirect("/dashboard/profile#staff-settings")

    # /admin/new → new event form
    get "new", to: "events#new", as: :new_event

    resources :events, except: [ :index, :show, :new ], param: :slug do
      member do
        get :select
        post :select
        post :regenerate_api_key
        patch :attach_image
      end
      resources :participants, only: [ :index, :show, :edit, :update, :destroy ] do
        collection do
          get :table
          get :new_invite
          post :send_invite
          delete :revoke_invite
          get :sync_slack_channel_preview
          post :sync_slack_channel
        end
        member do
          get :travel
          patch :travel, action: :update_travel
          post :refresh_flight_tracking
          post :refresh_flight_leg
          post :send_travel_update_reminder
          post :approve_um
          post :reject_um
          get :um_proof
          get :accommodation
          patch :accommodation, action: :update_accommodation
          get :medical
          patch :medical, action: :update_medical
          get :safeguarding
          patch :safeguarding, action: :update_safeguarding
          get :consents
          delete :reset_waiver
          delete :reset_freedom_waiver
          post :resend_waiver_completion_email
          post :resend_custom_document
          delete :reset_custom_document
          get :notes
          get :history
          post :resync_airtable
          post :resend_guardian_invite
          get :slack_invite_link
          post :invite_to_slack_channel
          post :withdraw
          post :unwithdraw
          get :merge
          post :merge_duplicate
          post :link_guardian
          patch :groups, action: :update_groups
        end
        resources :notes, only: [ :create, :destroy ], controller: "participant_notes"
        resources :guardians, only: [ :edit, :update ]
        resources :emergency_contacts, only: [ :new, :create, :edit, :update, :destroy ]
      end
      resources :incidents do
        member do
          post :send_to_slack
        end
        resources :comments, only: [ :create ], controller: "incident_comments"
      end
      resources :exports, only: [ :index, :create ]
      resources :export_templates, only: [ :create, :destroy ]
      resources :imports, only: [ :new, :create ] do
          collection do
            get :template
          end
          member do
            get :preview
            post :confirm
            get :progress
            delete :cancel
          end
        end
      resources :staff, only: [ :index, :new, :create, :destroy ], controller: "event_staff"
      resources :slack_blasts, only: [ :index, :show, :new, :create ] do
        member do
          post :retry_failed
          post :retry_recipient
        end
      end
      resources :messages do
        member do
          get :preview
          post :send_now
          post :cancel
          post :retry_failed
          post :retry_delivery
        end
      end
      resources :scans, only: [ :index, :create, :update ] do
        collection do
          get :scanner
          get :search
          get :history
        end
      end
      resources :participant_events, only: [] do
        member do
          post :confirm_nfc_badge
          post :reset_nfc_badge
        end
      end
      resources :scan_contexts, except: [ :show ]
      resource :travel, only: [ :show ], controller: "travel_calendar" do
        post :dismiss_pickup
      end
      resource :airport_mode, only: [ :show ], controller: "airport_mode"
      resource :rooming_wizard, only: [ :show ], controller: "rooming_wizard" do
        get :setup
        post :setup, action: :create_setup
        get :preferences
        post :link_preference
        delete :unlink_preference
        post :manual_assign
        post :auto_assign
        get :assignments
        post :move_assignment
        post :create_room
        patch :update_room
        post :reorder_rooms
        delete :destroy_room
        post :add_staff
        delete :remove_staff
        post :acknowledge_trans_nb
        post :toggle_exempt
        get :finalize
        post :do_finalize
        get :export_csv
        post :lock
        post :unlock
      end
      resources :sibling_groups, only: [ :index, :create, :update, :destroy ], controller: "sibling_groups"
      resources :groups, except: [ :show ] do
        collection do
          post :reorder
        end
        member do
          post :assign
          post :unassign
        end
      end
    end

    resources :series, controller: "event_series", param: :slug, except: [ :destroy ] do
      resources :members, only: [ :index, :new, :create, :destroy ], controller: "series_members"
    end

    resources :users, only: [ :index, :show, :new, :create, :edit, :update ] do
      resource :impersonation, only: [ :create ]
      resources :passports, only: [ :create, :destroy ] do
        post :confirm, on: :member
      end
    end

    resources :bans do
      member do
        patch :revoke
        patch :reinstate
      end
    end

    resources :audit_logs, only: [ :index, :show ] do
      collection do
        get :versions
      end
    end
    resources :email_logs, only: [ :index, :show ]

    resources :global_api_tokens, only: [ :index, :create ] do
      member do
        delete :revoke
      end
    end

    resource :settings, only: [ :show ] do
      post :toggle_maintenance
      post :toggle_twilio
      post :update_twilio_from_number
      post :toggle_waiver_sending
      post :toggle_support_sms
      post :update_support_sms_numbers
    end

    # Global incident reports (public form submissions)
    get "incidents", to: "incident_reports#index", as: :incidents

    # Global incident-report notification settings
    get "incidents/settings", to: "incident_settings#show", as: :incident_settings
    patch "incidents/settings", to: "incident_settings#update"

    get "incidents/:id", to: "incident_reports#show", as: :incident
    post "incidents/:incident_id/comments", to: "incident_report_comments#create", as: :incident_comments

    # Slug-based routes must come last to avoid matching other routes
    get ":slug", to: "dashboard#show", as: :event_dashboard, constraints: { slug: /[a-z0-9-]+/ }
    get ":slug/integrations", to: "dashboard#integrations", as: :event_integrations, constraints: { slug: /[a-z0-9-]+/ }
    patch ":slug/integrations", to: "dashboard#update_integrations", constraints: { slug: /[a-z0-9-]+/ }
    post ":slug/integrations/airtable_sync", to: "dashboard#trigger_airtable_sync", as: :event_trigger_airtable_sync, constraints: { slug: /[a-z0-9-]+/ }
    post ":slug/integrations/vote_event", to: "dashboard#create_vote_event", as: :event_create_vote_event, constraints: { slug: /[a-z0-9-]+/ }
    post ":slug/integrations/api_tokens", to: "event_api_tokens#create", as: :event_api_tokens, constraints: { slug: /[a-z0-9-]+/ }
    post ":slug/integrations/api_tokens/:id/rotate", to: "event_api_tokens#rotate", as: :rotate_event_api_token, constraints: { slug: /[a-z0-9-]+/ }
    delete ":slug/integrations/api_tokens/:id", to: "event_api_tokens#destroy", as: :event_api_token, constraints: { slug: /[a-z0-9-]+/ }

    # New-event setup wizard
    scope ":slug/setup", constraints: { slug: /[a-z0-9-]+/ } do
      get "", to: "event_setup#show", as: :event_setup
      get "schedule", to: "event_setup#schedule", as: :event_setup_schedule
      patch "schedule", to: "event_setup#update_schedule"
      get "modules", to: "event_setup#modules", as: :event_setup_modules
      patch "modules", to: "event_setup#update_modules"
      get "waivers", to: "event_setup#waivers", as: :event_setup_waivers
      patch "waivers", to: "event_setup#update_waivers"
      get "team", to: "event_setup#team", as: :event_setup_team
      post "team", to: "event_setup#add_team_member"
      delete "team/:assignment_id", to: "event_setup#remove_team_member", as: :event_setup_team_member
      get "review", to: "event_setup#review", as: :event_setup_review
      post "complete", to: "event_setup#complete", as: :event_setup_complete
    end

    # DocuSeal template builder and mappings
    scope ":slug/docuseal_templates/:template_type", constraints: { slug: /[a-z0-9-]+/, template_type: /waiver|freedom_waiver|adult_waiver|custom_[0-9a-f-]+/ } do
      post "use_default", to: "docuseal_templates#use_default", as: :event_docuseal_template_use_default
      post "sync", to: "docuseal_templates#sync", as: :event_docuseal_template_sync
      get "mappings", to: "docuseal_templates#mappings", as: :event_docuseal_template_mappings
      patch "mappings", to: "docuseal_templates#update_mappings"
    end

    # Custom documents (per-event DocuSeal templates beyond the built-in waivers)
    scope ":slug", constraints: { slug: /[a-z0-9-]+/ } do
      post "custom_documents", to: "custom_documents#create", as: :event_custom_documents
      get "custom_documents/:id/edit", to: "custom_documents#edit", as: :event_custom_document_edit
      patch "custom_documents/:id", to: "custom_documents#update"
      delete "custom_documents/:id", to: "custom_documents#destroy", as: :event_custom_document
    end
  end

  namespace :api do
    namespace :v1 do
      resources :webhooks, only: [] do
        collection do
          post :docuseal
        end
      end

      post "postmark_webhooks", to: "postmark_webhooks#create"
      post "helpscout_webhooks", to: "helpscout_webhooks#create"
      post "slack/events", to: "slack_events#create"

      # Unauthenticated leaked-token kill switch: POST the token's own secret to
      # revoke it and notify its owner. See TokenRevocationsController.
      post "tokens/revoke", to: "token_revocations#create"

      resource :session, only: [ :create, :destroy ] do
        post :refresh
      end
      resource :me, only: [ :show ], controller: "me"

      # Participant-facing: the current user's own tickets (their participant_events).
      # Distinct from the organizer-scoped events/:id/participants endpoints.
      resources :tickets, only: [ :index, :show ], controller: "tickets" do
        member do
          get :google_wallet
        end
      end

      resources :events, only: [ :index ]
      resources :push_tokens, only: [ :create, :destroy ], param: :token

      get "travel/search_airports", to: "travel#search_airports"
      post "travel/validate_flight", to: "travel#validate_flight"

      resources :events, only: [] do
        resources :participants, only: [ :index, :show, :create ], controller: "participants" do
          collection do
            get :search
            get :lookup
            get :roster
          end
          resources :notes, only: [ :index, :create ], controller: "notes"
        end
        resources :scan_contexts, only: [ :index ]
        resources :scans, only: [ :index, :create, :destroy ]
        resource :travel, only: [ :show ], controller: "travel_calendar"
        resource :airport_mode, only: [ :show ], controller: "airport_mode"
        resources :slack_blasts, only: [ :index, :show, :create ]

        resources :participant_events, only: [] do
          resource :nfc_badge, only: [], controller: "nfc_badges" do
            post :ensure
            post :confirm
            post :reset
          end
        end
      end
    end
  end

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
end
