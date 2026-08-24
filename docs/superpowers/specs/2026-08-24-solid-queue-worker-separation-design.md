# solid queue worker separation

## objective

run solid queue outside the puma web pods in both staging and production. web request capacity and background-job capacity must be independently scalable, and a worker failure must not remove a web replica.

this change does not introduce redis or sidekiq. jobs remain durable in postgresql through solid queue.

## considered approaches

### 1. separate orchard deployments with a start-command override

build the existing dockerfile from the same github repository, but override the worker deployment's command to `./bin/jobs`.

advantages:

- no application-code or image-layout change
- uses the existing supported solid queue executable
- web and worker replicas can be scaled independently
- both roles can continue auto-deploying from `main`

tradeoffs:

- orchard builds the repository once for each deployment
- web and worker rollouts can briefly overlap different commits
- workers do not expose an http health endpoint, so health is verified through pod state, logs, and solid queue heartbeats

this is the selected approach.

### 2. add a worker-specific dockerfile

add `Dockerfile.worker` with `CMD ["./bin/jobs"]` and deploy it separately.

this makes the process role explicit in source control, but duplicates dockerfile maintenance and still requires separate builds. it adds code without improving runtime isolation.

### 3. keep solid queue embedded in puma

retain `SOLID_QUEUE_IN_PUMA=true` and scale web and job capacity together.

this is operationally simple, but every web replica also creates a solid queue supervisor, dispatcher, scheduler, and worker. it couples failure domains, resource usage, and database connection growth, which is what this change is intended to remove.

## target topology

### staging

- existing `attend-staging` deployment remains the web tier
- new `attend-staging-worker` deployment
- github repository: `hackclub/attend`
- branch: `main`
- dockerfile: `Dockerfile`
- start command: `./bin/jobs`
- replicas: 1
- initial resources: 500 millicpu and 2 gibibytes memory per pod
- no ingress and no public service exposure
- `SOLID_QUEUE_IN_PUMA` absent

### production

- existing `attend` deployment remains the web tier
- new `attend-worker` deployment
- github repository: `hackclub/attend`
- branch: `main`
- dockerfile: `Dockerfile`
- start command: `./bin/jobs`
- replicas: 2, allowing one worker pod or node to fail without stopping job processing
- initial resources: 1000 millicpu and 2 gibibytes memory per pod
- no ingress and no public service exposure
- `SOLID_QUEUE_IN_PUMA` absent

the worker deployments receive the environment needed to boot the corresponding rails environment and connect to its existing internal postgresql endpoint. secret values are copied through orchard and are not written to this repository.

## startup and migrations

the existing container entrypoint performs a rails boot check for every process. it only runs `db:prepare` and secondary-schema setup for the rails server command, so standalone workers will not attempt concurrent schema changes.

web and worker builds can complete in either order when both deployments auto-deploy from `main`. migrations must remain compatible with the preceding application release because the web tier already uses rolling updates and old web pods remain live while a new pod runs `db:prepare`. the worker separation does not create a new migration-safety requirement, but it makes release-version overlap more visible.

## rollout

each environment is migrated independently, staging first.

1. record the existing web, database, and solid queue state.
2. create the standalone worker deployment while embedded puma workers remain active.
3. wait for all worker pods to run without restarts.
4. verify solid queue registers the expected standalone processes and has fresh heartbeats.
5. observe an existing recurring job being claimed and completed by the standalone worker.
6. remove `SOLID_QUEUE_IN_PUMA` from the web deployment, triggering a rolling restart.
7. verify web health, worker health, queue progress, and the absence of solid queue supervisors in web pods.
8. observe logs, restarts, database connections, cpu, and memory before proceeding to the next environment.

brief duplicate worker capacity during the cutover is safe because solid queue coordinates claims in postgresql.

## failure and rollback

if a standalone worker deployment fails before embedded workers are disabled, leave the web deployment unchanged and repair or remove the new worker deployment.

if a failure appears after cutover:

1. restore `SOLID_QUEUE_IN_PUMA=true` on the web deployment.
2. wait for the web rollout and embedded worker heartbeats.
3. scale the standalone worker deployment to zero or remove it after job processing is confirmed.

queued jobs remain in postgresql throughout the transition.

## verification criteria

an environment is complete only when:

- every web and worker pod is running with zero unexpected restarts
- the web health endpoint succeeds
- an existing recurring job completes on a standalone worker
- solid queue heartbeats are fresh
- web pods no longer run solid queue supervisors
- ready, scheduled, claimed, blocked, and failed job counts show no new unexplained growth
- database connection usage remains below the current 100-connection limit

production is changed only after staging meets these criteria.
