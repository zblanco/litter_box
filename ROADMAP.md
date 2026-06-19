# LitterBox Roadmap

Status: research and direction

This roadmap grounds future LitterBox work in current code, RunicAI sandbox
use cases, Libbit durable/serverless workspace plans, and adjacent systems.

## North Star

LitterBox should become the Elixir library for taming virtual compute
complexity. It should let applications ask for sandbox capabilities without
learning every operational detail of KVM, Firecracker, Docker, gVisor, Fly
Machines, Sprites, sidecars, service meshes, workspace volumes, and provider
APIs.

The library should expose a small set of deep interfaces:

- profiles;
- policies;
- sessions;
- execution requests/results;
- files and artifacts;
- attached processes and events;
- checkpoints;
- services and proxies;
- capability and health metadata;
- runtime/image definitions.

Everything else should be backend implementation detail.

## Product Scope

### In Scope

- Local agent harnesses that execute potentially unsafe generated code.
- Polyglot workflow steps that need a selected runtime environment.
- Stateful and stateless sandbox sessions.
- Hosted sandbox adapters and local compute adapters behind one contract.
- Explicit image/runtime configuration and readiness reporting.
- Service/proxy primitives for tests, web previews, MCP endpoints, and sidecars.
- File, artifact, and workspace transfer over sandbox boundaries.
- Capability metadata that lets consumers select a backend safely.
- Provider-neutral integration with durable workflow systems.

### Out Of Scope

- A full workflow engine.
- An LLM agent framework.
- A multi-tenant SaaS control plane.
- A secret manager.
- A container registry or image builder as the default path.
- A database/event store for durable workflow state.

LitterBox should make those systems easier to build. It should not become all of
them.

## Current Baseline

Already present:

- provider-neutral facade and backend behaviour;
- named sandbox profiles;
- policy, workspace, and capability structs;
- one-shot execution and stateful sessions;
- file operations;
- attach-shaped streaming;
- process handles;
- checkpoints and restore;
- service/proxy/lease contracts;
- backend health/reporting;
- Docker, gVisor-shape, Vmsan, Sprites, Remote, JustBash, and Lua backend
  surfaces.

Known limitations:

- runtime image/build configuration is still mostly backend options;
- provider-native live streaming is uneven across backends;
- microVM setup depends on host-specific Vmsan/Firecracker assets;
- service mesh and sidecar patterns are not first-class yet;
- binary/protobuf/gRPC I/O contracts are future work;
- durability belongs to consumers today, not LitterBox.

## Roadmap Phases

### Phase 1: Documentation And Boundary Hardening

Goal: make the extracted library self-describing and safe to extend.

Deliverables:

- `AGENTS.md`, `README.md`, `ARCHITECTURE.md`, and `ROADMAP.md`.
- Clear language for current versus future capabilities.
- Examples that show supervision-tree usage and stateful sessions.
- Capability metadata guidance for backend authors.
- Validation expectations for package-local tests and live smokes.

Acceptance:

- a new contributor can tell what belongs in LitterBox versus a consumer app;
- no public docs imply every backend has the same security or state guarantees.

### Phase 2: Runtime And Image Definitions

Goal: make environment selection explicit without turning LitterBox into a
full image builder.

Potential API:

```elixir
runtime = %{
  name: :agent_python,
  family: :container,
  image: "ghcr.io/example/agent-python:latest",
  runtimes: [:bash, :python],
  user: "10001:10001",
  workdir: "/workspace",
  labels: %{purpose: :agent_code}
}
```

Deliverables:

- `RuntimeProfile` or equivalent environment catalog contract.
- Normalized image/rootfs/provider-template metadata.
- Backend health that can say which runtime profiles are installed, missing, or
  stale.
- Clear split between selecting a runtime and building/publishing a runtime.
- Optional build hooks for Dockerfiles, Vmsan rootfs/image creation, and hosted
  provider templates.

Prior-art pressure:

- Vmsan can create Firecracker rootfs images from OCI images and exposes
  multi-runtime profiles.
- Modal and E2B expose sandbox images/templates as core user concepts.
- Libbit plans model runtime images and workspace infrastructure separately.

### Phase 3: Stronger Local Isolation Matrix

Goal: make local isolation choices obvious and testable.

Deliverables:

- Docker runtime selection for `runc`, `runsc`/gVisor, and future Kata-style
  runtimes where available.
- Vmsan readiness and execution profiles that distinguish host prerequisites,
  runtime image readiness, network policy readiness, and exec readiness.
- Optional direct Firecracker backend investigation after Vmsan stabilizes.
- Capability reports that compare isolation level, state tier, attach mode,
  network enforcement, and filesystem model across configured profiles.

Acceptance:

- users can ask for "microVM or fail" or "container acceptable" without knowing
  provider internals;
- missing KVM, missing Firecracker assets, missing runtime images, and missing
  network helpers surface as structured health diagnostics.

### Phase 4: Serverless Compute Pools

Goal: support elastic stateless and stateful compute without embedding a
workflow engine.

Deliverables:

- pool semantics that distinguish warm sessions, elastic runners, persistent
  sessions, and service actors;
- scale-to-zero capable backend adapters where providers support hibernation;
- lifecycle events for create, start, hibernate, wake, checkpoint, restore,
  retire, and cleanup;
- placement hints such as local, hosted, region, isolation minimum, runtime
  family, GPU, or large-memory capability.

Related systems:

- FLAME exposes `FLAME.call/3`, `FLAME.cast/3`, `FLAME.place_child/3`, and
  elastic pools for short-lived infrastructure.
- Fly Machines expose fast VM lifecycle and volumes.
- Sprites expose stateful sandboxes with persistence, checkpoints, URLs, and
  network policy.

LitterBox should learn from these systems while keeping its role narrower:
virtual compute handles and policy, not application code distribution semantics.

### Phase 5: Sidecars, Service Mesh, And MCP Boundaries

Goal: model safe communication across sandbox boundaries.

Deliverables:

- first-class sidecar/service definitions;
- explicit host-forward, unix-socket, TCP, HTTP, and egress-allow-list boundary
  metadata;
- scoped proxy lifecycle and health checks;
- MCP/model/tool boundary recipes that keep credentials on the host;
- denial checks that prove unrelated egress is blocked.

Prior-art pressure:

- Eigr Spawn uses actor/service mesh ideas for durable, polyglot stateful
  computing over Erlang-native, gRPC, and HTTP transports.
- Libbit's provider plans call out sidecar proxy patterns for polyglot workflow
  runtimes.
- RunicAI and Ariston sandbox plans needed scoped host-side MCP/model access
  without broad sandbox network egress.

### Phase 6: Structured Cross-Boundary I/O

Goal: go beyond terminal text when the sandbox hosts services or actors.

Deliverables:

- typed request/response envelopes for service actors;
- binary-safe file and artifact transfer contracts;
- optional protobuf/gRPC encoding for backends that support service mesh
  semantics;
- event framing that preserves stdout/stderr, status, trace ids, artifact refs,
  and provider metadata;
- versioned protocol metadata so consumers can evolve contracts safely.

Do not remove terminal execution. Keep terminal I/O as the universal lowest
common denominator, and add structured channels above it.

### Phase 7: Durable Execution Integration Points

Goal: make LitterBox a good compute substrate for durable systems without
becoming one.

Deliverables:

- idempotency keys and request identifiers in execution/session calls;
- resumable session handles where backends support persistent identity;
- checkpoint handles that applications can store in their own journals;
- clear mapping from LitterBox events to workflow engine events;
- guidance for Temporal/Restate/Runic/Libbit integration.

Prior-art pressure:

- Temporal emphasizes durable workflow state that can recover, replay, pause,
  and run for long periods.
- Restate emphasizes journaled durable execution, virtual objects, and service
  calls.
- Libbit uses per-workspace event stores, SQLite read models, and workflow
  journals.

LitterBox should provide durable compute handles and evidence. Durable ordering,
replay, compensation, and workflow ownership remain consumer responsibilities.

### Phase 8: Provider Expansion

Potential backends and integrations:

- Podman.
- Wasmtime/WASI.
- Direct Firecracker.
- Kata Containers through container runtime configuration.
- Kubernetes jobs/pods with gVisor/Kata runtime classes.
- Modal Sandboxes.
- E2B.
- FLAME backend collaboration or adapter recipes.
- Native Fly Machines backend distinct from Sprites.

Selection rule: add backends only when they can implement meaningful
capabilities behind the same contracts and report limitations honestly.

## Research Notes And Prior Art

### MicroVMs And Containers

- [Firecracker](https://github.com/firecracker-microvm/firecracker) is a KVM
  virtual machine monitor for microVMs with a minimalist device model intended
  to reduce memory footprint and attack surface.
- [Firecracker docs](https://firecracker-microvm.github.io/) describe the KVM
  microVM model, hardware virtualization requirements, and host-facing control
  API.
- [Vmsan](https://vmsan.dev/) wraps Firecracker with CLI automation, JSON flags,
  WebSocket PTY, file transfer, network policy, and OCI image/rootfs workflows.
- [gVisor](https://gvisor.dev/) provides a Linux-compatible sandbox for
  containers and moves much of the host-kernel interface into a per-sandbox
  application kernel.
- [Kata Containers](https://katacontainers.io/) provides container-compatible
  workloads inside lightweight VMs for stronger isolation than ordinary
  containers.

### Hosted Sandboxes And Virtual Computers

- [Sprites](https://sprites.dev/) provides stateful sandbox VMs with
  persistence, checkpoints, HTTP URLs, and network policy.
- [Fly Machines](https://fly.io/docs/machines/) provide fast-launching hosted VM
  primitives with an API for machine lifecycle.
- [Fly Volumes](https://fly.io/docs/volumes/) provide local persistent storage
  for Fly Machines.
- [Modal Sandboxes](https://modal.com/docs/guide/sandboxes) expose secure
  containers for untrusted user or agent code, including imperative sandbox
  handles.
- [E2B](https://e2b.dev/docs) provides isolated cloud sandboxes for agents to
  execute code, process data, and run tools.

### Serverless And Durable Compute

- [FLAME](https://github.com/phoenixframework/flame) lets Elixir applications
  elastically run parts of the app on short-lived runners through pools and
  backend adapters.
- [FLAME on Fly](https://fly.io/blog/rethinking-serverless-with-flame/)
  describes elastic runner pools and scale-to-zero style execution.
- [Eigr Spawn](https://github.com/eigr/spawn) is an actor-native service mesh
  for durable, stateful, polyglot computing over Erlang-native, gRPC, and HTTP
  transports.
- [Temporal](https://docs.temporal.io/evaluate/understanding-temporal) is a
  durable execution platform for long-running recoverable workflows.
- [Restate](https://docs.restate.dev/foundations/key-concepts) provides durable
  execution, workflows, virtual objects, and service invocation semantics.

### Internal Context

- [RunicAI sandboxing research](../runic_ai/.docs/046-ai-code-sandboxing-research.md)
  established backend-agnostic sandbox workspaces with explicit isolation
  levels.
- [RunicAI serverless mesh plan](../runic_ai/.docs/050-sandbox-serverless-mesh-and-libbit-consumer-next-steps.md)
  framed sessions, files, checkpoints, services, proxies, leases, and lifecycle
  events as the right substrate.
- [RunicAI streaming and MCP dogfood](../runic_ai/.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md)
  established attach events, live-versus-terminal streaming truth, and scoped
  MCP boundary requirements.
- [RunicAI consumer-driven plan](../runic_ai/.docs/053-runic-sandbox-consumer-driven-improvement-plan.md)
  tied sandbox work to generated-component proof, restricted egress, active
  attach lifecycle, and provider certification.
- [Libbit workspace sandbox exploration](../libbit/.docs/workspace-sandbox-and-graph-memory-architecture-exploration.md)
  separates agent-facing capabilities from provider adapters and names
  sandbox sessions, graph stores, context bundlers, and code runtimes as stable
  contracts.
- [Libbit container providers plan](../libbit/.docs/container_infrastructure_providers_plan.md)
  maps Docker, Kubernetes, Fly, and Firecracker provider responsibilities.
- [Libbit Firecracker local provider plan](../libbit/.docs/firecracker_local_provider_plan.md)
  captures local microVM security, image, snapshot, and host-network complexity.
- [Libbit durable execution plan](../libbit/.docs/durable_execution.md) and
  [Restate-inspired approach](../libbit/.docs/restate_durable_execution_approach.md)
  frame workspace-scoped durable execution and journal boundaries.

## Immediate Next Work

1. Convert backend runtime/image options into a documented runtime profile
   contract.
2. Add focused tests around capability reporting for each backend family.
3. Make Vmsan and Docker examples in README independent of RunicAI-specific
   image names.
4. Decide whether `ConsumerProfiles` should remain examples or move to docs.
5. Add a provider certification report format that clearly separates
   readiness, mocked tests, local live smokes, and credential-backed remote
   execution.
