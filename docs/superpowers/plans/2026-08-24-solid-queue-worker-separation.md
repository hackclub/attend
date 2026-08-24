# Solid Queue Worker Separation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Solid Queue execution out of the staging and production Puma pods into independently scalable Orchard worker deployments.

**Architecture:** Each environment keeps its existing web deployment and PostgreSQL-backed Solid Queue tables. A tested `PROCESS_TYPE` selector in `bin/docker-entrypoint` preserves the default web command and switches worker deployments to `./bin/jobs`. A new Orchard deployment builds the same `hackclub/attend` Dockerfile from `main`, receives the corresponding Rails and database environment in memory from the existing web deployment, and has Orchard's auto-generated ingress removed before validation. Staging is cut over and verified before production.

**Tech Stack:** Rails 8.1, Solid Queue 1.4, PostgreSQL 17, Docker, Kubernetes, Orchard

**Spec:** `docs/superpowers/specs/2026-08-24-solid-queue-worker-separation-design.md`

## Global Constraints

- Keep Solid Queue and PostgreSQL; do not add Redis or Sidekiq.
- Delete Orchard's auto-generated worker ingress immediately after deployment creation, and do not expose either worker through any other ingress or public service.
- Never write Orchard environment-variable values or database credentials to the repository, logs, plan, or final report.
- Preserve the existing web deployments, services, ingresses, replica counts, and resource requests.
- Keep embedded workers active until the corresponding standalone worker deployment has healthy pods and fresh Solid Queue heartbeats.
- Complete and verify staging before creating the production worker deployment.
- Roll back by restoring `SOLID_QUEUE_IN_PUMA=true` before pausing a faulty standalone worker.

---

### Task 1: Add and Land the Container Process Role

**Files:**
- Modify: `bin/docker-entrypoint`
- Create: `spec/bin/docker_entrypoint_spec.sh`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `PROCESS_TYPE`, with supported values `web` and `worker`
- Produces: a Docker entrypoint that preserves the image command for `web`, runs `./bin/jobs` for `worker`, and exits 64 for any other value

- [x] **Step 1: Write and run the failing worker-role test**

Execute the real entrypoint from a temporary directory containing controlled `bin/rails`, `bin/jobs`, and `bin/thrust` executables. Require `PROCESS_TYPE=worker` to execute `bin/jobs` without executing `db:prepare` or Thruster.

Run:

```bash
bash spec/bin/docker_entrypoint_spec.sh
```

Expected before implementation: exit 1 with `worker process did not start bin/jobs`.

- [x] **Step 2: Implement and verify the worker role**

Select `./bin/jobs` before the existing boot checks when `PROCESS_TYPE=worker`, then rerun the test and require exit 0.

- [x] **Step 3: Write and run the failing invalid-role test**

Require a misspelled `PROCESS_TYPE=workre` to exit nonzero without invoking Rails, jobs, or Thruster.

Run the shell spec and require it to fail with `invalid process type did not fail` before implementing validation.

- [x] **Step 4: Implement fail-closed validation and verify both roles**

Accept `web` and `worker`, default an absent value to `web`, and exit 64 for every other value. Rerun the shell spec and require exit 0.

- [x] **Step 5: Add the shell spec to continuous integration**

Add a `Test container entrypoint` step running `bash spec/bin/docker_entrypoint_spec.sh` immediately before the RSpec step in `.github/workflows/ci.yml`.

- [ ] **Step 6: Commit and land the change on `main`**

Commit the entrypoint, test, CI, design, and plan changes. Push the working branch, create or update its pull request, merge it after required checks pass, then require both existing web deployments to auto-deploy the merged commit and return to their existing healthy replica counts before creating a worker.

### Task 2: Capture the Staging Baseline

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
%w[SOLID_QUEUE_IN_PUMA HOST APP_REVISION GIT_REVISION PROCESS_TYPE]
```

Require the resulting keys to include `DATABASE_URL`, `RAILS_ENV`, and `RAILS_MASTER_KEY`, and require `RAILS_ENV` to equal `staging`. Add `{ key: "PROCESS_TYPE", value: "worker" }`. Do not display the other values.

### Task 3: Create and Validate the Staging Worker

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `staging_worker_env` from Task 2
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
  "port": 3000,
  "cpuRequestMilli": 500,
  "memoryRequestBytes": 2147483648,
  "env": "staging_worker_env"
}
```

`env` above means the exact in-memory array from Task 2, including `PROCESS_TYPE=worker`, not a serialized string. Capture the returned deployment ID as `staging_worker_id`.

- [ ] **Step 2: Remove the auto-generated ingress**

Read the deployment's ingress list, delete every ingress attached to `staging_worker_id`, then require the deployment to have no ingress and no publicly enabled service port.

- [ ] **Step 3: Wait for the build and pod to become healthy**

Poll Orchard deployment state until the build is `succeeded`, deployment state is `running`, one replica is available, and restart count is zero. On build or startup failure, inspect build logs and pod logs; do not change staging web.

- [ ] **Step 4: Verify the worker process tree**

Read the worker pod logs and require `Command: ./bin/jobs`, with no `Running db:prepare` or Puma startup. Require fresh standalone `Supervisor`, `Worker`, `Dispatcher`, and `Scheduler` heartbeats.

- [ ] **Step 5: Enable worker auto-deploy**

Enable auto-deploy for `staging_worker_id` on branch `main`, then read the deployment back and require `autoDeployEnabled=true`, `autoDeployBranch=main`, and `PROCESS_TYPE=worker`.

### Task 4: Cut Staging Web Over to the Standalone Worker

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `staging_worker_id` from Task 3
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

### Task 5: Capture the Production Baseline

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: Orchard production web deployment `79b6905f-3928-4969-beaa-a95423b6a650`
- Produces: `production_worker_env`, an in-memory array of Orchard `{ key, value }` objects; baseline pod, queue, and database-connection observations

- [ ] **Step 1: Confirm production web and database health**

Use Orchard to read deployment `79b6905f-3928-4969-beaa-a95423b6a650` and database `33d3b7bb-bbc2-4667-99ba-1a8c1bd1a73e`. Require three healthy web replicas, a healthy database, and a successful `https://attend.hackclub.com/up` response.

- [ ] **Step 2: Capture current Solid Queue state and connection count**

Run the queue-count runner from Task 2 in one production web pod. Query `pg_stat_activity` for the current database connection count and require it to remain below 100.

- [ ] **Step 3: Build the production worker environment in memory**

Fetch the production web environment from Orchard. Copy every entry except `SOLID_QUEUE_IN_PUMA`, `HOST`, and `PROCESS_TYPE`. Require the resulting keys to include `DATABASE_URL` and `RAILS_MASTER_KEY`. Add `{ key: "PROCESS_TYPE", value: "worker" }`. Do not display the other values.

### Task 6: Create and Validate the Production Workers

**Files:**
- No repository files are changed.

**Interfaces:**
- Consumes: `production_worker_env` from Task 5
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
  "port": 3000,
  "cpuRequestMilli": 1000,
  "memoryRequestBytes": 2147483648,
  "env": "production_worker_env"
}
```

Capture the returned deployment ID as `production_worker_id`.

- [ ] **Step 2: Remove the auto-generated ingress**

Delete every ingress attached to `production_worker_id`, then require no ingress and no publicly enabled service port.

- [ ] **Step 3: Validate one production worker pod**

Wait for the build to succeed and one pod to run with zero restarts. Require logs to show `Command: ./bin/jobs` without `Running db:prepare` or Puma startup. Require fresh `Supervisor`, `Worker`, `Dispatcher`, and `Scheduler` heartbeats.

- [ ] **Step 4: Scale to two worker replicas**

Scale `production_worker_id` to two replicas. Require two available pods, zero unexpected restarts, and fresh process heartbeats from both pod hostnames.

- [ ] **Step 5: Enable worker auto-deploy**

Enable auto-deploy for `production_worker_id` on `main`, then read the deployment back and require `autoDeployEnabled=true`, `autoDeployBranch=main`, `PROCESS_TYPE=worker`, and `replicas=2`.

### Task 7: Cut Production Web Over and Complete Verification

**Files:**
- Modify: `docs/superpowers/plans/2026-08-24-solid-queue-worker-separation.md`

**Interfaces:**
- Consumes: `production_worker_id` from Task 6
- Produces: production web without embedded Solid Queue; two verified standalone worker replicas; completed runbook

- [ ] **Step 1: Disable embedded production workers**

Delete only `SOLID_QUEUE_IN_PUMA` from production web deployment `79b6905f-3928-4969-beaa-a95423b6a650` through Orchard.

- [ ] **Step 2: Verify the production web rollout**

Require three available web replicas with zero unexpected restarts. Require `https://attend.hackclub.com/up` to return HTTP 200 and inspect pod logs for Rails boot or migration errors.

- [ ] **Step 3: Verify standalone production job execution**

Enqueue the marker job from Task 4 in a production web pod. Require the marker token in one standalone worker pod's logs and require the job to leave ready/claimed state.

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
