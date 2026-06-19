# LitterBox Architecture

Status: grounding document

LitterBox is a provider-neutral library for virtual compute sessions. It should
make common sandbox workflows simple while keeping backend-specific guarantees
honest and inspectable.

The central design goal is the Ousterhout-style interface shape: hide a large
amount of operational complexity behind a small API, but make the few exposed
concepts deep enough that users do not fall through to provider implementation
details for normal work.

## What LitterBox Owns

LitterBox owns:

- sandbox profile normalization;
- execution policy and capability metadata;
- session lifecycle;
- one-shot execution;
- file transfer within sandbox sessions;
- attach-shaped streaming and process control;
- checkpoints and restore handles;
- services and scoped proxies;
- leases and active attach lifecycle;
- backend health and host readiness probes;
- provider adapter behaviours and fallback dispatch.

LitterBox does not own:

- LLM provider clients;
- agent planning or repair loops;
- workflow graph compilation;
- user approval UX;
- durable workflow journals;
- application read models;
- host workspace write policy outside sandbox import/export semantics;
- secret stores beyond explicit provider/backend configuration.

Those are application-layer concerns for consumers such as RunicAI, Libbit, or
ordinary OTP applications.

## Public Layering

```text
Consumer application
  -> app policy, review, trace, workflow, persistence, UI
  -> LitterBox facade and supervised manager
  -> Profile, Policy, Workspace, Capabilities, Session contracts
  -> backend adapters
  -> Docker, gVisor, Vmsan/Firecracker, Sprites, Fly Machines, local runtimes
```

The application should ask for a sandbox capability. It should not need to
parse Docker JSON, Vmsan output, Sprites frames, Fly Machine state, or
Firecracker API responses directly.

## Core Contracts

### Profile

`LitterBox.Profile` is the named backend configuration. It carries:

- `name`
- `backend`
- `runtimes`
- `isolation_level`
- `policy`
- `workspace`
- `pool`
- `stateful?`
- `enabled?`
- `backend_options`
- `metadata`

Profiles are meant to be durable enough for apps to store or generate, while
remaining generic enough that a profile can select Docker today and Vmsan or
Sprites tomorrow.

### Policy

`LitterBox.Policy` describes what an execution is allowed to do:

- network mode: `:disabled`, `:host`, or `:restricted`;
- timeout and output caps;
- allowed runtimes;
- minimum isolation level;
- persistence intent;
- egress allow-list metadata;
- MCP boundary metadata;
- deny-by-default behavior.

Policy must be fail-closed. A backend that cannot enforce scoped restricted
egress should report that limitation and reject a request that requires it.

### Workspace

`LitterBox.Workspace` describes how host data reaches the sandbox:

- `:none`
- `:copy_in`
- `:bind_read_only`
- `:bind`
- `:stateful`

The current safe default is explicit copy-in. Bind and writeback semantics are
more dangerous and should remain opt-in, narrowly tested, and clearly reported.

### Capabilities

`LitterBox.Capabilities` is the main guard against leaky abstractions. It tells
consumers what a backend or session can actually do:

- exec;
- files and inline files;
- artifacts;
- session files;
- checkpoints;
- services;
- proxies;
- leases;
- streaming;
- network policy;
- persistent identity.

Capability metadata also records attach mode, live streaming, stdin support,
stderr separation, MCP-boundary support, restricted-egress support, PTY support,
state tier, service hosting, process hosting, workspace persistence, and
snapshot modes.

This is how LitterBox can present one API without pretending that in-process
Lua, Docker, Vmsan, and Sprites have the same guarantees.

## Backend Behaviour

`LitterBox.Backend` defines the adapter boundary. Required operations cover
basic provision/exec/upload/download/snapshot/reset/destroy/health. Optional
callbacks add richer session behavior:

- open and close sessions;
- execute inside a session;
- attach and stream;
- write stdin and close attach;
- start/list/status/signal/kill/wait processes;
- read/write/list/delete files;
- checkpoint and restore;
- start/stop/list services;
- open/close proxies;
- acquire/release leases.

Optional callbacks are deliberate. They let simple backends participate without
faking capabilities they do not have.

## State Model

LitterBox should distinguish these state tiers:

- `:one_shot_exec`: a request runs and disappears.
- `:persistent_workspace`: files persist across calls.
- `:persistent_process_host`: long-lived processes can be started and observed.
- `:service_actor`: the sandbox can host services, proxies, and actor-like
  state.

This is important for durable execution systems. LitterBox can host compute and
stateful runtime handles, but it should not become the workflow journal. A
consumer can pair LitterBox sessions with a durable execution system such as a
Runic workflow runner, Temporal-style workflow, Restate-style journal, or
workspace event store.

## I/O Model

The I/O model should stay structured:

- request metadata and files go in through `ExecutionRequest`, session files, or
  explicit workspace import;
- stdout, stderr, exit status, duration, artifacts, and backend metadata come
  out through `ExecutionResult`;
- long-running output flows through `SessionEvent`;
- process state flows through `ProcessHandle` and `ProcessStatus`;
- service reachability flows through `Service` and `Proxy`;
- file references flow through `FileRef`.

Future work should consider richer payload encodings for cross-boundary calls,
including gRPC/protobuf-style contracts for service actors. That belongs above
raw stdout/stderr, not as a replacement for terminal execution.

## Image And Environment Model

Profiles select an environment. They should not build it implicitly.

Current configuration uses backend options such as image names, Vmsan runtime
selection, provider tokens, and rootfs/runtime metadata. The roadmap should add
a first-class build/runtime catalog, but the boundary should remain:

- LitterBox can name and validate runtime environments.
- Backends can build, pull, or select images when explicitly requested.
- Applications decide which runtime profiles are trusted, published, or allowed
  for a user/workflow.

## Backend Families

### In-Process Runtimes

`just_bash` and Lua are fast, useful, and testable. They are not strong
security boundaries. Their capability metadata must make that clear.

### Containers

Docker is the practical baseline for local polyglot execution. gVisor and
Kata-style runtimes are stronger container-compatible isolation options. The
same LitterBox profile should be able to report which runtime actually enforced
the boundary.

### MicroVMs

Vmsan is the current path to Firecracker/KVM because it wraps host setup,
runtime images, file transfer, network policy, and CLI automation. A direct
Firecracker backend is possible later, but it should not leak raw TAP, jailer,
kernel, rootfs, or snapshot plumbing into application code.

### Hosted Sandboxes And Machines

Sprites and Fly Machines are remote compute substrates. Sprites map well to
stateful agent sandboxes with files, checkpoints, services, and URLs. Fly
Machines are a lower-level hosted VM primitive for broader runtime and service
orchestration. LitterBox should normalize both behind sessions and capabilities
while preserving provider metadata.

## Design Tests

Before adding an API, ask:

1. Can at least two backend families implement or explicitly reject this
   contract?
2. Does the contract expose the user's intent rather than a provider mechanism?
3. Can a consumer decide safely from capability metadata?
4. Does unsupported behavior fail closed?
5. Does the API avoid smuggling app-specific workflow, review, or persistence
   concerns into the library?

If the answer is no, keep the feature in a backend option, metadata field, or
consumer integration until the deeper abstraction is clearer.
