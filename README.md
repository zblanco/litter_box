<p align="center">
  <img src="./assets/brand/litter-box-logo.png" alt="LitterBox logo: a magic purple cat sitting in a gold-rimmed litterbox" width="240">
</p>

# LitterBox

LitterBox is an Elixir toolbox for virtual compute orchestration. It gives
applications a small, structured API for opening sandbox sessions, executing
code, moving files, streaming process output, managing services and proxies,
and inspecting backend capabilities across several compute substrates.

The library was extracted from a dynamic workflow generation agent harness project so the sandbox contracts and backends can
be reused by other projects. The current focus is agent and workflow code
execution, but the longer-term direction is broader: local microVM sandboxes,
container and gVisor execution, hosted stateful sandboxes, service actors,
serverless runners, and durable workflow runtimes.

> Current State: Operational but in active development

## Installation


```elixir
def deps do
  [
    {:litter_box, github: "zblanco/litter_box"}
  ]
end
```

## Design Aim

LitterBox should hide virtual compute complexity behind a small interface
without pretending that every backend is the same.

Users should be able to ask for a capability:

- "run this Bash/Python/Node/Elixir code in an isolated workspace"
- "open a persistent session and prove these generated files"
- "start a service and expose a scoped proxy"
- "use a microVM when KVM is available, otherwise choose a configured fallback"
- "restrict egress except for this host-side model or MCP proxy"

They should not need to know every detail of Firecracker TAP networking, Docker
runtime flags, Fly Machine state, Sprites checkpoints, or provider-specific file
transfer protocols before doing useful work.

At the same time, the abstraction must not be leaky. LitterBox reports backend
capabilities, isolation level, state model, attach mode, network policy support,
and known limitations as structured data. If a backend cannot enforce a
requested boundary, it should fail closed instead of silently degrading.

## Current Capabilities

The public API is centered on `LitterBox` and these provider-neutral structs:

- `LitterBox.Profile`: named sandbox configuration, backend choice, runtimes,
  pool settings, workspace shape, and backend options.
- `LitterBox.Policy`: timeout, output caps, allowed runtimes, minimum isolation,
  network mode, restricted-egress metadata, and MCP boundary intent.
- `LitterBox.Workspace`: how host data enters the sandbox, such as `:copy_in`,
  `:stateful`, or future bind modes.
- `LitterBox.Capabilities`: exec, files, checkpoints, services, proxies,
  leases, streaming, persistent identity, attach mode, and state tier.
- `LitterBox.Session`: a provider-neutral handle to a sandbox environment.
- `LitterBox.ExecutionRequest` and `LitterBox.ExecutionResult`: structured code
  execution inputs and outputs.
- `LitterBox.AttachHandle`, `SessionEvent`, and process handles for streaming
  and long-running process flows.

Implemented or scaffolded backend families include:

- `:just_bash`: in-process virtual Bash evaluation for dev/test use.
- `:lua`: in-process Lua evaluation when the optional dependency is available.
- `:docker` and `:gvisor`: container-style execution through Docker-compatible
  profiles and runtime options.
- `:vmsan`: Firecracker/KVM microVM orchestration through the Vmsan CLI.
- `:sprites`: hosted stateful sandbox sessions through Fly.io Sprites.
- `:remote`: provider-adapter shape for remote machine execution.
- `:firecracker`, `:podman`, and `:wasmtime`: named profile targets reserved by
  the contract, with implementation depth depending on backend support.

See [ARCHITECTURE.md](./ARCHITECTURE.md) for the current boundary and
[ROADMAP.md](./ROADMAP.md) for planned work and prior-art references.

## Quick Start

Add LitterBox to a supervision tree with one or more named sandbox profiles:

```elixir
children = [
  {LitterBox,
   name: MyApp.Sandboxes,
   sandboxes: [
     local_code: [
       backend: :docker,
       runtimes: [:bash, :python, :node],
       image: "my-org/agent-runtime:latest",
       pool: [warm: 1, max: 4],
       network: :disabled,
       workspace: [mode: :copy_in, persist?: true]
     ]
   ]}
]
```

Run a one-shot request through the manager:

```elixir
{:ok, result} =
  LitterBox.exec(
    %{
      sandbox: :local_code,
      runtime: :bash,
      source: "printf 'hello from sandbox\n'",
      timeout_ms: 5_000
    },
    server: MyApp.Sandboxes
  )

result.stdout
```

Open a stateful session when you need file operations, checkpoints, attached
processes, services, or proxies:

```elixir
{:ok, session} = LitterBox.open_session(:local_code, [], server: MyApp.Sandboxes)

{:ok, _ref} = LitterBox.write_file(session, "proof/input.txt", "hello")
{:ok, result} = LitterBox.exec(session, runtime: :bash, source: "cat proof/input.txt")

:ok = LitterBox.close_session(session, server: MyApp.Sandboxes)
```

## Backend Images And Runtime Dependencies

Profiles describe policy and workspace shape. They do not install language
runtimes, CLIs, package managers, model tools, or application dependencies for
you. Prepare those in the selected image, rootfs, Sprite template, or provider
runtime.

### Docker And GVisor

Docker and gVisor profiles use `backend_options.image` or the top-level `image:`
profile option.

For contained agent CLI sessions:

- keep provider credentials on the host or in a controlled proxy, not inside
  the sandbox image;
- include full runtime dependencies in the image, such as full `python3` when a
  sidecar imports Python stdlib modules;
- prefer non-root runtime users and make managed workspaces writable by that
  uid before container startup;
- install OS packages, language runtimes, global CLIs, and project tools in a
  project-specific Dockerfile or derived image.

For stateful Docker sessions, `workspace.host_root` is copy-seeded into the
managed workspace before the container starts. Missing or non-directory
`host_root` values fail closed before `docker run`. This is intentionally not a
host bind/writeback mode; use explicit artifact or tool flows for host writes
until bind semantics are designed and reviewed.

### Vmsan And Firecracker

Vmsan profiles expect KVM, Firecracker assets, a kernel/rootfs, the Vmsan agent,
and required guest runtimes to already exist on the host. Use `mix
litter_box.doctor --format json` to inspect readiness. Treat Vmsan as a CLI
adapter around Firecracker rather than as a direct Firecracker control plane.

Keep this boundary:

- model credentials stay on the host or in a provider-managed control plane;
- guest rootfs images own language runtimes and agent CLIs;
- network policy and host-service access must be explicit;
- snapshot semantics are backend-specific and must say whether they preserve
  filesystem state, process memory, open sockets, or only provider checkpoints.

### Sprites And Remote Sandboxes

Hosted sandbox providers can provide persistent identity, checkpoint/restore,
services, URLs/proxies, and provider-managed hibernation. LitterBox should
normalize those operations into sessions, files, checkpoints, services, and
proxies while preserving provider-specific health and limitation metadata.

## Development

```bash
mix deps.get
mix test
mix format
mix compile --warnings-as-errors
```

Backend-specific smoke scripts live in `scripts/`. Run them only when the
corresponding provider and credentials are configured.
