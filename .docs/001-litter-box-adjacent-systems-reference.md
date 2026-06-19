# LitterBox Adjacent Systems Reference

Status: research reference

Date: 2026-06-19

## Purpose

This document canvases adjacent systems and papers that matter for LitterBox's
future direction. The goal is not to copy any one platform. The goal is to
understand which abstractions are stable across virtual compute systems, which
provider details should remain backend-local, and where LitterBox's API should
grow next.

LitterBox's intended role:

```text
consumer app / workflow engine / agent harness
  -> app policy, review, trace, durable workflow state, UI
  -> LitterBox profiles, policy, sessions, files, processes, services, proxies
  -> Docker, gVisor, Vmsan/Firecracker, Sprites, Fly Machines, local runtimes
```

The abstraction design target is a deep interface: hide the operational
complexity of virtual compute behind simple contracts, while reporting enough
capability and policy metadata to avoid leaky or unsafe abstractions.

## Source Set

Local context:

- [RunicAI sandboxing research](../../runic_ai/.docs/046-ai-code-sandboxing-research.md)
- [RunicAI serverless mesh plan](../../runic_ai/.docs/050-sandbox-serverless-mesh-and-libbit-consumer-next-steps.md)
- [RunicAI streaming and MCP dogfood](../../runic_ai/.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md)
- [RunicAI consumer-driven improvement plan](../../runic_ai/.docs/053-runic-sandbox-consumer-driven-improvement-plan.md)
- [Libbit workspace sandbox and graph memory exploration](../../libbit/.docs/workspace-sandbox-and-graph-memory-architecture-exploration.md)
- [Libbit container infrastructure providers plan](../../libbit/.docs/container_infrastructure_providers_plan.md)
- [Libbit Firecracker local provider plan](../../libbit/.docs/firecracker_local_provider_plan.md)
- [Libbit durable execution plan](../../libbit/.docs/durable_execution.md)
- [Libbit Restate-inspired durable execution approach](../../libbit/.docs/restate_durable_execution_approach.md)

External references are linked inline below. Prefer official docs, upstream
repositories, and papers when extending this document.

## High-Level Comparison Matrix

| System | Primary lesson for LitterBox | Most relevant contract area |
| --- | --- | --- |
| Firecracker | MicroVMs can be fast and strong, but host setup, rootfs, networking, jailer, and snapshot semantics must not leak into the app API. | `:microvm` backend, health, runtime images, snapshots |
| Vmsan | A Docker-like CLI/API can make Firecracker usable; LitterBox should adapt the ergonomic layer before owning raw VMM orchestration. | Vmsan backend, doctor, file transfer, network policy |
| gVisor | Sandboxed container runtime is a middle point between Docker and microVMs; report it as a distinct isolation level. | Docker runtime options, `:gvisor` isolation |
| Kata Containers | VM-backed containers fit Kubernetes/containerd better than local app APIs; useful as runtime-class support, not as a separate app concept. | Kubernetes/runtime-class future backend |
| Docker/Podman | The practical local baseline; image/env/workspace semantics are central and should be first-class enough to configure safely. | container backend, runtime profiles, workspace |
| Wasmtime/WASI | Capability-oriented in-process sandboxing is valuable for deterministic plugins, but not a replacement for OS sandboxes. | `:wasi`, policy, runtime capability subset |
| Fly Machines | Hosted VM lifecycle and volumes are useful provider primitives, but lower-level than agent sandbox sessions. | remote VM backend, placement, volumes |
| Sprites | A high-level hosted sandbox maps closely to LitterBox sessions: files, checkpoints, services, proxies, hibernation, and policy. | remote microVM sessions, stateful workspaces |
| Modal Sandboxes | Sandbox handles as imperative objects are useful; images/templates are product-level concepts. | runtime profiles, hosted backend shape |
| E2B | Agent-oriented sandboxes emphasize templates, filesystem, process, ports, and lifecycle. | agent harness backend and runtime profiles |
| FLAME | Elastic pools and remote execution are app distribution primitives; LitterBox can learn pool vocabulary without becoming FLAME. | serverless pools, placement, lifecycle |
| Eigr Spawn | Sidecar/proxy and polyglot stateful actors point toward structured service I/O above terminal execution. | service actors, gRPC/protobuf, sidecars |
| Dapr | Sidecars create a stable app API for state, pub/sub, bindings, and service invocation across runtimes. | service mesh boundaries and host-side proxies |
| Temporal | Durable workflow state belongs above compute sessions; LitterBox should provide handles/evidence, not own replay. | durable integration contracts |
| Restate | Virtual objects and journaled execution clarify the separation between durable identity and compute placement. | idempotency, service actors, checkpoints |
| Durable Functions / Netherite | Event-sourced orchestration and storage-provider performance are workflow-engine concerns; expose compute events cleanly. | event mapping and idempotency |

## Local Compute And Isolation

### Firecracker

References:

- [Firecracker GitHub](https://github.com/firecracker-microvm/firecracker)
- [Firecracker documentation](https://firecracker-microvm.github.io/)
- [Firecracker jailer documentation](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md)
- Paper: [Firecracker: Lightweight Virtualization for Serverless Applications](https://www.usenix.org/conference/nsdi20/presentation/agache)

Relevance:

Firecracker is the canonical microVM target for local hard isolation. It is
purpose-built for serverless and multi-tenant workloads, uses KVM, and exposes a
small VMM with a deliberately reduced device model. It is directly relevant to
LitterBox's `:microvm` isolation level and to any future direct `:firecracker`
backend.

Comparison to LitterBox:

- Firecracker is a VMM, not a user-facing sandbox product.
- LitterBox should not expose TAP devices, jailer chroot paths, kernel paths,
  rootfs block devices, or Unix socket API calls as the normal app API.
- LitterBox should expose profile/runtime selection, session lifecycle, file
  transfer, exec, checkpoints, services, and health diagnostics.

What to learn:

- MicroVM startup can be compatible with serverless and agent workflows if warm
  pools, snapshots, or prebuilt rootfs images are available.
- Snapshot semantics need careful capability metadata. Filesystem-only
  checkpoint, provider checkpoint, and memory/device snapshot are not
  equivalent.
- Host readiness is part of the product: KVM availability, jailer assets,
  networking helpers, kernel/rootfs images, and permissions need structured
  health reports.

Risk:

Direct Firecracker ownership can quickly pull LitterBox into host networking and
image management complexity. Keep Vmsan as the near-term wrapper unless a direct
backend can stay small and testable.

### Vmsan

References:

- [Vmsan documentation](https://vmsan.dev/)
- [Vmsan GitHub](https://github.com/angelorc/vmsan)

Relevance:

Vmsan is currently the practical Firecracker path for LitterBox. It wraps
Firecracker into a developer-facing CLI with JSON output, file transfer,
network policy, PTY/WebSocket surfaces, and OCI/rootfs workflows.

Comparison to LitterBox:

- Vmsan is a backend. LitterBox is the provider-neutral facade.
- Vmsan concepts such as runtime names, rootfs paths, CLI flags, and doctor
  checks should normalize into LitterBox health, runtime profile, session, and
  capability data.

What to learn:

- A Docker-like experience for microVMs is the right developer shape.
- `doctor`/health output is a first-class contract, not just a troubleshooting
  command.
- The backend should preserve Vmsan's concrete limitations: sudo requirements,
  rootfs readiness, workdir preparation, and terminal-versus-live streaming.

### Docker And Podman

References:

- [Docker Engine security](https://docs.docker.com/engine/security/)
- [Docker seccomp security profiles](https://docs.docker.com/engine/security/seccomp/)
- [Docker Engine API](https://docs.docker.com/reference/api/engine/)
- [Podman documentation](https://docs.podman.io/)

Relevance:

Containers are the practical default for local polyglot execution. They are easy
to run, easy to customize with Dockerfiles, and good enough for many trusted or
semi-trusted workflow steps.

Comparison to LitterBox:

- Docker is a backend and image format ecosystem; LitterBox owns the sandbox
  contract above it.
- LitterBox must not imply Docker equals microVM isolation.
- Docker-specific options belong in runtime/backend options unless they reflect
  a provider-neutral policy such as network mode, workspace mode, or runtime
  image selection.

What to learn:

- Runtime profiles should become explicit. Image, user, workdir, env allowlist,
  runtime (`runc`, `runsc`, future `kata`), volumes, and labels need one
  normalized place.
- Non-root execution requires workspace ownership preparation before container
  startup.
- Network modes should fail closed. Restricted egress should not silently
  become broad bridge networking.

### gVisor

References:

- [gVisor documentation](https://gvisor.dev/docs/)
- [gVisor architecture guide](https://gvisor.dev/docs/architecture_guide/)
- [gVisor runsc quick start](https://gvisor.dev/docs/user_guide/quick_start/docker/)

Relevance:

gVisor is an intermediate isolation level: it preserves container workflows
while reducing direct host-kernel syscall exposure through an application
kernel.

Comparison to LitterBox:

- gVisor should be a reported isolation level or runtime variant, not just a
  Docker option hidden in metadata.
- A profile requesting `isolation_minimum: :gvisor` should fail if the Docker
  runtime actually uses ordinary `runc`.

What to learn:

- Container-compatible sandboxing can be a high-value upgrade path for users
  who cannot run microVMs.
- Capability reports need to say what was actually enforced, not only what was
  requested.

### Kata Containers

References:

- [Kata Containers documentation](https://katacontainers.io/)
- [Kata Containers architecture](https://github.com/kata-containers/kata-containers)

Relevance:

Kata runs container workloads in lightweight VMs. It is most relevant when
LitterBox eventually targets Kubernetes/containerd runtime classes.

Comparison to LitterBox:

- Kata is likely not a separate facade-level backend. It is a runtime class or
  provider capability under a Kubernetes/container backend.
- The isolation should still report as VM-backed, not ordinary container.

What to learn:

- Runtime-class selection needs a clean profile field once Kubernetes becomes a
  target.
- Stronger isolation can be delivered through container orchestration APIs, not
  only direct Firecracker control.

### Wasmtime And WASI

References:

- [Wasmtime documentation](https://docs.wasmtime.dev/)
- [WASI overview](https://wasi.dev/)
- [WebAssembly Component Model](https://component-model.bytecodealliance.org/)

Relevance:

WASI is useful for deterministic plugin-style execution with explicit
capabilities. It is not a full Linux runtime, but it can give LitterBox a fast
and portable `:wasi` tier for narrow tasks.

Comparison to LitterBox:

- WASI belongs beside `:lua` and `:just_bash` as a constrained local runtime,
  not beside Firecracker as a general OS sandbox.
- Its capability model can inform LitterBox policy design: filesystem,
  environment, clocks, network, and host calls should be explicit.

What to learn:

- Capability-based execution is often clearer than broad "sandboxed" labels.
- LitterBox should report runtime capability gaps before execution.

## Hosted Sandboxes And Virtual Machines

### Fly Machines

References:

- [Fly Machines overview](https://fly.io/docs/machines/)
- [Fly Machines API](https://fly.io/docs/machines/api/)
- [Fly volumes](https://fly.io/docs/volumes/)

Relevance:

Fly Machines are hosted VM primitives with API-controlled lifecycle, regions,
volumes, and machine config. They are relevant to LitterBox's remote VM and
serverless pool roadmap.

Comparison to LitterBox:

- Machines are lower-level than a sandbox session.
- LitterBox should normalize machine lifecycle into sessions, services,
  proxies, files, and health, while preserving provider metadata such as region,
  app, machine id, and volume ids.

What to learn:

- Placement, region, guest resources, volumes, and scale-to-zero are real user
  concerns for hosted compute.
- Provider identity and durable volume identity should be represented in
  session/checkpoint metadata.

### Sprites

References:

- [Sprites documentation](https://sprites.dev/)
- [Sprites Elixir package](https://hex.pm/packages/sprites)

Relevance:

Sprites maps unusually well to LitterBox's higher-level session contract:
stateful sandboxes, files, exec, checkpoints, services, URLs/proxies, network
policy, and provider-managed hibernation.

Comparison to LitterBox:

- Sprites is one hosted backend. LitterBox should expose the same operations to
  consumers without making "Sprite" the app-facing noun.
- Provider-specific details such as hibernation and framed stdout/stderr should
  normalize into session state and `SessionEvent`/`ExecutionResult` decoding.

What to learn:

- High-level sandbox providers validate LitterBox's session/file/checkpoint/
  service/proxy vocabulary.
- CWD defaults and binary stdout/stderr framing are concrete backend details
  that must be adapted at the boundary.

### Modal Sandboxes

References:

- [Modal Sandboxes](https://modal.com/docs/guide/sandboxes)
- [Modal images](https://modal.com/docs/guide/images)

Relevance:

Modal exposes sandbox handles and images/templates as first-class product
concepts for running untrusted or dynamic code in a hosted environment.

Comparison to LitterBox:

- Modal's sandbox object is similar to `LitterBox.Session`.
- Modal's images/templates reinforce that runtime environment definitions
  deserve a first-class LitterBox contract.

What to learn:

- Hosted sandbox UX is often organized around templates/images, not only
  backend names.
- LitterBox should let apps list and choose runtime profiles without requiring
  the app to know provider-specific image mechanics.

### E2B

References:

- [E2B documentation](https://e2b.dev/docs)
- [E2B sandbox templates](https://e2b.dev/docs/sandbox-template)

Relevance:

E2B focuses on AI-agent sandboxes with templates, files, command execution, and
lifecycle management.

Comparison to LitterBox:

- E2B is agent-oriented and hosted; LitterBox should make the same style of
  agent harness possible across local and hosted backends.
- E2B template concepts map to future runtime profiles.

What to learn:

- Agent sandbox APIs need ergonomic file, command, process, and port/proxy
  operations.
- Templates and fast startup are core product surfaces, not internal details.

## Serverless Pools, Sidecars, And Actors

### FLAME

References:

- [FLAME GitHub](https://github.com/phoenixframework/flame)
- [Rethinking serverless with FLAME](https://fly.io/blog/rethinking-serverless-with-flame/)

Relevance:

FLAME lets Elixir applications run parts of themselves on short-lived elastic
infrastructure through pools and backend adapters. It is adjacent because it
solves elastic app execution, not arbitrary sandbox sessions.

Comparison to LitterBox:

- FLAME distributes trusted application code. LitterBox contains potentially
  untrusted or polyglot code behind explicit sandbox contracts.
- FLAME's pools and placement APIs are relevant to LitterBox's future pool
  vocabulary.

What to learn:

- Pool APIs should be simple: call, cast, place child, and backend selection.
- LitterBox should keep compute placement separate from workflow semantics.

Open question:

- A future LitterBox backend might use FLAME to place trusted helper processes,
  but FLAME should not become the sandbox isolation boundary by itself.

### Eigr Spawn

References:

- [Eigr Spawn GitHub](https://github.com/eigr/spawn)
- [Eigr Spawn documentation](https://eigr.io/spawn/)

Relevance:

Spawn is a stateful serverless and actor system with polyglot actors,
sidecars/proxies, and transports including Erlang-native, gRPC, and HTTP. It is
highly relevant to LitterBox's future `:service_actor` state tier.

Comparison to LitterBox:

- Spawn owns actor placement, state, invocation, and sidecar semantics.
- LitterBox should not become a full actor runtime, but it should support
  service actors hosted inside sandbox sessions.

What to learn:

- Terminal stdout/stderr is not enough for durable service actors.
- gRPC/protobuf or versioned envelopes can be the right cross-boundary payload
  model once a sandbox hosts a long-lived service.
- Sidecar/proxy metadata should become explicit instead of being hidden in
  backend options.

### Dapr

References:

- [Dapr overview](https://docs.dapr.io/concepts/overview/)
- [Dapr service invocation](https://docs.dapr.io/developing-applications/building-blocks/service-invocation/)
- [Dapr actors](https://docs.dapr.io/developing-applications/building-blocks/actors/)

Relevance:

Dapr is not a sandbox system, but its sidecar model is instructive. It provides
stable APIs for service invocation, state, pub/sub, bindings, and actors across
many languages and hosting environments.

Comparison to LitterBox:

- Dapr abstracts distributed application building blocks.
- LitterBox abstracts virtual compute boundaries.
- A LitterBox sidecar/MCP boundary can borrow Dapr's separation between app API
  and infrastructure implementation.

What to learn:

- Sidecars let credentials and infrastructure access remain outside the
  sandboxed workload.
- Stable local endpoints can hide provider-specific networking if policy is
  explicit and enforced.

## Durable Execution Systems

### Temporal

References:

- [Temporal durable execution overview](https://docs.temporal.io/evaluate/understanding-temporal)
- [Temporal workflows](https://docs.temporal.io/workflows)
- [Temporal activities](https://docs.temporal.io/activities)

Relevance:

Temporal distinguishes durable workflow state from activity execution. That
separation is important for LitterBox: sandbox sessions execute work, but the
consumer workflow engine should own replay, durable timers, retries,
compensation, and orchestration history.

Comparison to LitterBox:

- Temporal is a durable execution platform.
- LitterBox is a virtual compute substrate.
- A Temporal activity could use LitterBox, but LitterBox should not become a
  Temporal replacement.

What to learn:

- Execution requests should support idempotency keys and stable identifiers so
  durable callers can recover safely.
- Results and events should be deterministic enough for consumers to store and
  reason about.

### Restate

References:

- [Restate key concepts](https://docs.restate.dev/foundations/key-concepts)
- [Restate workflows](https://docs.restate.dev/foundations/workflows)
- [Restate virtual objects](https://docs.restate.dev/foundations/objects)

Relevance:

Restate's model of durable services, workflows, and virtual objects clarifies
how durable identity can be separate from process placement. This is relevant to
future LitterBox service actors and persistent sessions.

Comparison to LitterBox:

- Restate owns invocation journaling and replay.
- LitterBox owns compute sessions and backend capability truth.

What to learn:

- Persistent identity is not the same thing as a running process.
- LitterBox session handles should be resumable only when the backend has a
  real persistent identity and the consumer has stored the relevant handle.

### Durable Functions And Netherite

References:

- [Azure Durable Functions overview](https://learn.microsoft.com/azure/azure-functions/durable/durable-functions-overview)
- Paper: [Durable Functions: Semantics for Stateful Serverless](https://www.microsoft.com/en-us/research/publication/durable-functions-semantics-for-stateful-serverless/)
- Paper: [Netherite: Efficient Execution of Serverless Workflows](https://www.microsoft.com/en-us/research/publication/netherite-efficient-execution-of-serverless-workflows/)

Relevance:

Durable Functions and Netherite show the workflow-engine side of the same
problem: event-sourced orchestration, deterministic replay, and storage/provider
performance for serverless workflows.

Comparison to LitterBox:

- These systems should sit above LitterBox.
- LitterBox should make its execution events easy for such systems to journal,
  but should not own their orchestration semantics.

What to learn:

- Event volume, replay cost, and idempotency matter when sandbox execution is
  part of a durable workflow.
- LitterBox should provide compact summaries and artifact references in addition
  to raw terminal chunks.

### SAND And Serverless Papers

References:

- Paper: [SAND: Towards High-Performance Serverless Computing](https://www.usenix.org/conference/atc18/presentation/akkus)
- Paper: [Cloudburst: Stateful Functions-as-a-Service](https://www.vldb.org/pvldb/vol13/p2438-sreekanti.pdf)

Relevance:

SAND and Cloudburst are useful for thinking about low-latency function
composition, state locality, and the limits of stateless serverless designs.

Comparison to LitterBox:

- These papers are about serverless platforms and dataflow systems.
- LitterBox can borrow their emphasis on state locality and warm execution
  without taking over scheduling or workflow composition.

What to learn:

- Stateless compute alone is insufficient for many agent/workflow tasks.
- Warm pools, colocated state, and explicit state handles should be part of the
  roadmap.

## Agent Sandbox Systems

### OpenAI Code Interpreter-Style Sandboxes

References:

- [OpenAI Code Interpreter tool guide](https://platform.openai.com/docs/guides/tools-code-interpreter)

Relevance:

Code Interpreter-style products show the user-facing target: "run code, inspect
files, return artifacts" without exposing infrastructure details.

Comparison to LitterBox:

- LitterBox is lower-level infrastructure for applications that want their own
  sandbox substrate.
- It should still offer similarly simple primitives: run, file, artifact,
  timeout, and session.

What to learn:

- Artifacts and file references are part of the user contract, not incidental
  stdout.
- Users rarely want to choose infrastructure first; they want a capability with
  clear safety and cost boundaries.

### Tensorlake Sandbox Notes

Reference:

- [RunicAI Tensorlake takeaways](../../runic_ai/.docs/055-tensorlake-sandbox-reference-takeaways.md)

Relevance:

The RunicAI Tensorlake note already captured a similar lesson: sandbox products
often converge on runtime images, sessions, command execution, files,
artifacts, and policy.

Comparison to LitterBox:

- Tensorlake-style hosted sandbox features can become future backend adapters or
  roadmap pressure.
- LitterBox should avoid product-specific assumptions while borrowing the
  stable nouns.

## Cross-Cutting Design Implications

### 1. Runtime profiles should be first-class

Current LitterBox profiles can carry `backend_options.image`, Vmsan runtime
selection, provider tokens, and metadata. That is enough for an extracted first
library, but not enough for a durable roadmap.

Recommended direction:

```elixir
%LitterBox.RuntimeProfile{
  name: :agent_python,
  family: :container,
  runtimes: [:bash, :python],
  image: "ghcr.io/example/agent-python:latest",
  workdir: "/workspace",
  user: "10001:10001",
  capabilities: [:exec, :files, :services],
  labels: %{purpose: :agent_code}
}
```

Keep building/publishing optional. Selecting and validating a runtime profile
is the deeper interface.

### 2. Capability metadata is the anti-leak mechanism

LitterBox should not hide differences between:

- terminal adapters and live streaming;
- stdin-capable attached processes and one-shot exec;
- filesystem checkpoints and memory snapshots;
- container isolation and microVM isolation;
- deny-all network and scoped restricted egress;
- persistent workspace and persistent process identity.

When in doubt, expose the difference in `Capabilities.metadata` or a typed
field before adding app-facing behavior.

### 3. Sidecar and proxy contracts should become explicit

Agent sandboxes often need model access, MCP access, package registries, or test
service access. The safe pattern is not broad internet egress. It is scoped
host/provider-side boundaries:

- host-forwarded HTTP/TCP endpoint;
- unix socket;
- reverse proxy;
- provider service URL;
- sidecar service with explicit allow-list.

LitterBox already has policy metadata and proxy/service structs. Future work
should connect those into a coherent sidecar/proxy contract.

### 4. Durable execution belongs above LitterBox

Do not make LitterBox a workflow engine. Instead:

- accept caller-provided request ids/idempotency keys;
- produce compact event summaries and artifact refs;
- keep session/checkpoint handles serializable where possible;
- expose enough lifecycle events for consumers to journal.

RunicAI, Libbit, Temporal, Restate, or another engine can own durable
orchestration.

### 5. Provider certification should become a report format

The same backend can be in several states:

- static contract exists;
- unit tests pass with fake provider;
- health/preflight is ready;
- local live smoke passed;
- credential-backed remote execution passed;
- cleanup/leak checks passed.

Future LitterBox reports should make this distinction machine-readable.

## Proposed Reference Categories For Future Issues

When adding a feature, tag it against one or more categories:

- `runtime-profile`
- `local-container`
- `microvm`
- `hosted-sandbox`
- `serverless-pool`
- `sidecar-boundary`
- `structured-io`
- `durable-integration`
- `provider-certification`
- `workspace-transfer`
- `service-actor`

This keeps future expansion organized around stable responsibilities rather
than backend brands.

## Immediate Follow-Up Work

1. Add `RuntimeProfile` or an equivalent image/environment catalog contract.
2. Extend `mix litter_box.report` so each backend reports certification level:
   contract, tests, preflight, live, remote, cleanup.
3. Create focused capability tests for Docker, Vmsan, Sprites, JustBash, and Lua
   that assert honest state tier, attach mode, and isolation metadata.
4. Draft a sidecar/MCP boundary contract that covers host-forward, unix socket,
   egress allow-list, and provider URL transports.
5. Add idempotency/request-id fields to execution/session calls for durable
   workflow callers.
6. Write a follow-up design note on binary-safe artifact transfer and
   protobuf/gRPC service actor I/O.
