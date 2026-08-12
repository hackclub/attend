# Attend - Agent Instructions

## Commands
```bash
bin/dev                           # Start dev server (Rails + Tailwind)
bundle exec rspec                 # Run all tests
bundle exec rspec spec/path_spec.rb:42  # Run single test at line
bin/rubocop -a                    # Lint (auto-fix)
rails db:migrate                  # Run migrations
```

## Architecture
Rails 8.1 app with PostgreSQL, Hotwire, Tailwind. UUID primary keys (set `self.implicit_order_column = "created_at"`). Pundit for authorization, Devise for auth, Active Record Encryption for sensitive fields.

**Structure:** `app/models/` (AR models), `app/controllers/` (namespaced: admin/, guardian_portal/, onboarding/), `app/policies/` (Pundit), `app/services/` (Docuseal, Airtable APIs), `app/jobs/` (Solid Queue).

## Code Style
- Omakase Ruby style (rubocop-rails-omakase)
- String-backed enums: `enum :status, { pending: "pending", complete: "complete" }`
- Encrypted fields: `encrypts :allergies, :medical_conditions`
- Policies check `user.global_admin?` first, then role-based access
- Admin UI elements on user pages: wrap in `border-2 border-dashed border-orange-400`

## Test Users (dev)
admin@hackclub.com / eventadmin@hackclub.com / ops@hackclub.com / safeguarding@hackclub.com / participant@example.com (all use password123)
