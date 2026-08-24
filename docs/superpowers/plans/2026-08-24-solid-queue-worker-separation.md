# Solid Queue Worker Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Solid Queue execution out of the staging and production Puma pods into independently scalable Orchard worker deployments.

**Architecture:** Each environment keeps its existing web deployment and PostgreSQL-backed Solid Queue tables. A new Orchard deployment builds the same `hackclub/attend` Dockerfile from `main`, overrides the start command to `./bin/jobs`, and receives the corresponding Rails and database environment in memory from the existing web deployment. Staging is cut over and verified before production.

**Tech Stack:** Rails 8.1, Solid Queue 1.4, PostgreSQL 17, Docker, Kubernetes, Orchard

**Spec:** `docs/superpowers/specs/2026-08-24-solid-queue-worker-separation-design.md`

## Global Constraints

- Keep Solid Queue and PostgreSQL; do not add Redis or Sidekiq.
- Do not expose either worker deployment through an ingress or public service.
- Never write Orchard environment-variable values or database credentials to the repository, logs, plan, or final report.
- Preserve the existing web deployments, services, ingresses, replica counts, and resource requests.
- Keep embedded workers active until the corresponding standalone worker deployment has healthy pods and fresh Solid Queue heartbeats.
- Complete and verify staging before creating the production worker deployment.
- Roll back by restoring `SOLID_QUEUE_IN_PUMA=true` before pausing a faulty standalone worker.

---

### Task 1: Capture the Staging Baseline

**Files:**
- Read: `config/queue.yml`
- Read: `config/puma.rb`
- Read: `bin/jobs`
- Read: `bin/docker-entrypoint`

**Interfaces:**
- Consumes: Orchard staging web deployment `61d39961-8f55-438a-a13b-3e223b7969e7`
- Produces: `staging_worker_env`, an in-memory array of Orchard `{ key, value }` objects; baseline pod, queue, and database-connection observations

- [ ] **Step 1: Confirm staging web and database health**

Use Orchard to read deployment `61d39961-8f55-438a-a13b-3e223b7969e7` and database `fb69d175-ea99-4a19-b196-0cce0228ff34`. Require all current web replicas and the database to be healthy before proceeding.

- [ ] **Step 2: Capture current Solid Queue state**

Run this through `./bin/rails runner` in one staging web pod:

```ruby
puts({
  processes: SolidQueue::Process.group(:kind).count,
  ready: SolidQueue::ReadyExecution.count,
  scheduled: SolidQueue::ScheduledExecution.count,
  claimed: SolidQueue::ClaimedExecution.count,
  blocked: SolidQueue::BlockedExecution.count,
  failed: SolidQueue::FailedExecution.count
}.to_json)
```

Record the output only as counts. Do not print environment values.

- [ ] **Step 3: Build the staging worker environment in memory**

Fetch the staging web environment from Orchard. Copy every entry except these web/build-specific keys:

```ruby
%w[SOLID_QUEUE_IN_PUMA HOST APP_REVISION GIT_REVISION]
```

Require the resulting keys to include `DATABASE_URL`, `RAILS_ENV`, and `RAILS_MASTER_KEY`, and require `RAILS_ENV` to equal `staging`. Do not display the values.

### Task 2: Create and Validate the Staging Worker

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `staging_worker_env` from Task 1
- Produces: `staging_worker_id`, the deployment ID returned by Orchard

- [ ] **Step 1: Create the worker deployment**

Call Orchard's GitHub deployment operation with exactly:

```json
{
  "projectId": "70a03bbf-e89c-410e-aa1e-a37b5223bb60",
  "githubRepo": "hackclub/attend",
  "branch": "main",
  "name": "attend-staging-worker",
  "buildType": "dockerfile",
  "dockerfilePath": "Dockerfile",
  "startCommand": "./bin/jobs",
  "port": 3000,
  "cpuRequestMilli": 500,
  "memoryRequestBytes": 2147483648,
  "env": "staging_worker_env"
}
```

`env` above means the exact in-memory array from Task 1, not a serialized string. Capture the returned deployment ID as `staging_worker_id`.

- [ ] **Step 2: Wait for the build and pod to become healthy**

Poll Orchard deployment state until the build is `succeeded`, deployment state is `running`, one replica is available, and restart count is zero. On build or startup failure, inspect build logs and pod logs; do not change staging web.

- [ ] **Step 3: Verify the worker process tree**

Read the worker pod logs and Solid Queue process records. Require fresh standalone `Supervisor`, `Worker`, `Dispatcher`, and `Scheduler` heartbeats. Require the deployment to have no ingress and no publicly enabled service port.

- [ ] **Step 4: Enable worker auto-deploy**

Enable auto-deploy for `staging_worker_id` on branch `main`, then read the deployment back and require `autoDeployEnabled=true`, `autoDeployBranch=main`, and `startCommand=./bin/jobs`.

### Task 3: Cut Staging Web Over to the Standalone Worker

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `staging_worker_id` from Task 2
- Produces: staging web without embedded Solid Queue; verified standalone job execution

- [ ] **Step 1: Disable embedded workers**

Delete only `SOLID_QUEUE_IN_PUMA` from staging web deployment `61d39961-8f55-438a-a13b-3e223b7969e7` through Orchard. This intentionally starts a rolling web restart.

- [ ] **Step 2: Verify the staging web rollout**

Require two available staging web replicas with zero unexpected restarts. Confirm the staging health endpoint from inside a pod and inspect startup logs for Rails boot or migration errors.

- [ ] **Step 3: Verify standalone job execution**

Enqueue a harmless marker job from a staging web pod:

```ruby
token = "standalone-worker-verification-#{SecureRandom.uuid}"
SolidQueue::RecurringJob.perform_later(%(Rails.logger.info(#{token.dump})))
puts token
```

Read the marker token from stdout, then require the same token to appear in the standalone worker pod logs and require the job to leave ready/claimed state.

- [ ] **Step 4: Verify process ownership and database connections**

Require fresh Solid Queue process heartbeats only from the standalone worker pod, with no Solid Queue supervisor process registered for either staging web pod. Query PostgreSQL connection count and require it to remain below 100.

- [ ] **Step 5: Apply the staging rollback if any check fails**

If Steps 2 through 4 fail, add `SOLID_QUEUE_IN_PUMA=true` back to staging web, wait for healthy embedded-worker heartbeats, then scale `staging_worker_id` to zero. Do not proceed to production.

### Task 4: Capture the Production Baseline

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: Orchard production web deployment `79b6905f-3928-4969-beaa-a95423b6a650`
- Produces: `production_worker_env`, an in-memory array of Orchard `{ key, value }` objects; baseline pod, queue, and database-connection observations

- [ ] **Step 1: Confirm production web and database health**

Use Orchard to read deployment `79b6905f-3928-4969-beaa-a95423b6a650` and database `33d3b7bb-bbc2-4667-99ba-1a8c1bd1a73e`. Require three healthy web replicas, a healthy database, and a successful `https://attend.hackclub.com/up` response.

- [ ] **Step 2: Capture current Solid Queue state and connection count**

Run the queue-count runner from Task 1 in one production web pod. Query `pg_stat_activity` for the current database connection count and require it to remain below 100.

- [ ] **Step 3: Build the production worker environment in memory**

Fetch the production web environment from Orchard. Copy every entry except `SOLID_QUEUE_IN_PUMA` and `HOST`. Require the resulting keys to include `DATABASE_URL` and `RAILS_MASTER_KEY`. Do not display values.

### Task 5: Create and Validate the Production Workers

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `production_worker_env` from Task 4
- Produces: `production_worker_id`, the deployment ID returned by Orchard

- [ ] **Step 1: Create the initial worker deployment**

Call Orchard's GitHub deployment operation with exactly:

```json
{
  "projectId": "70a03bbf-e89c-410e-aa1e-a37b5223bb60",
  "githubRepo": "hackclub/attend",
  "branch": "main",
  "name": "attend-worker",
  "buildType": "dockerfile",
  "dockerfilePath": "Dockerfile",
  "startCommand": "./bin/jobs",
  "port": 3000,
  "cpuRequestMilli": 1000,
  "memoryRequestBytes": 2147483648,
  "env": "production_worker_env"
}
```

Capture the returned deployment ID as `production_worker_id`.

- [ ] **Step 2: Validate one production worker pod**

Wait for the build to succeed and one pod to run with zero restarts. Require fresh `Supervisor`, `Worker`, `Dispatcher`, and `Scheduler` heartbeats, and require no ingress or publicly enabled service port.

- [ ] **Step 3: Scale to two worker replicas**

Scale `production_worker_id` to two replicas. Require two available pods, zero unexpected restarts, and fresh process heartbeats from both pod hostnames.

- [ ] **Step 4: Enable worker auto-deploy**

Enable auto-deploy for `production_worker_id` on `main`, then read the deployment back and require `autoDeployEnabled=true`, `autoDeployBranch=main`, `startCommand=./bin/jobs`, and `replicas=2`.

### Task 6: Cut Production Web Over and Complete Verification

**Files:**
- Modify: `docs/superpowers/plans/2026-08-24-solid-queue-worker-separation.md`

**Interfaces:**
- Consumes: `production_worker_id` from Task 5
- Produces: production web without embedded Solid Queue; two verified standalone worker replicas; completed runbook

- [ ] **Step 1: Disable embedded production workers**

Delete only `SOLID_QUEUE_IN_PUMA` from production web deployment `79b6905f-3928-4969-beaa-a95423b6a650` through Orchard.

- [ ] **Step 2: Verify the production web rollout**

Require three available web replicas with zero unexpected restarts. Require `https://attend.hackclub.com/up` to return HTTP 200 and inspect pod logs for Rails boot or migration errors.

- [ ] **Step 3: Verify standalone production job execution**

Enqueue the marker job from Task 3 in a production web pod. Require the marker token in one standalone worker pod's logs and require the job to leave ready/claimed state.

- [ ] **Step 4: Verify final ownership and capacity**

Require no Solid Queue supervisors in production web pods. Require fresh worker, dispatcher, scheduler, and supervisor heartbeats from both standalone worker pods. Require database connections below 100 and no new unexplained growth in ready, scheduled, claimed, blocked, or failed jobs.

- [ ] **Step 5: Apply the production rollback if any check fails**

If Steps 2 through 4 fail, add `SOLID_QUEUE_IN_PUMA=true` back to production web, wait for healthy embedded-worker heartbeats, then scale `production_worker_id` to zero.

- [ ] **Step 6: Record completion**

Mark every completed checkbox in this plan, append a short results section containing deployment IDs, replica counts, non-secret queue counts, connection counts, and verification outcome, then commit only this plan file:

```bash
git add docs/superpowers/plans/2026-08-24-solid-queue-worker-separation.md
git commit -m "Record standalone Solid Queue worker rollout"
```
