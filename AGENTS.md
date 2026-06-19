# LitterBox Agent Guide

LitterBox is an Elixir library for virtual compute orchestration. It exposes a
provider-neutral sandbox API over local process-like runtimes, containers,
gVisor-style runtimes, Firecracker/KVM microVMs through Vmsan, hosted stateful
sandboxes such as Sprites, and future remote compute providers.

The library is intentionally not coupled to Runic. RunicAI is an early consumer,
but LitterBox should remain useful to ordinary OTP applications, agent harnesses,
workflow engines, and serverless-style compute systems.

## Build And Test Commands

- `mix deps.get` - fetch dependencies
- `mix test` - run the standalone package test suite
- `mix test test/litter_box_test.exs` - run the main contract suite
- `mix test test/docker_workspace_seeding_test.exs` - run the Docker workspace
  seeding tests
- `mix compile --warnings-as-errors` - compile with warnings treated as failures
- `mix format` - format code and docs covered by `.formatter.exs`
- `mix litter_box.doctor --format json` - inspect backend health when host tools
  are available
- `mix litter_box.report` - generate backend capability reporting

Run package tests from `/home/doops/wrk/litter_box`, not from a consuming
repository. Package-local tests rely on `test/support`.

## Architecture Rules

- Keep the public surface provider-neutral. Applications should depend on
  profiles, policies, sessions, files, processes, services, proxies,
  checkpoints, and capability metadata, not directly on Docker containers, Fly
  Machines, Sprites, or Firecracker VMs.
- Fail closed when a backend cannot enforce requested policy. Do not silently
  degrade `network: :restricted`, MCP boundary requests, isolation minimums, or
  workspace persistence claims.
- Make backend differences explicit through `LitterBox.Capabilities` metadata:
  attach mode, live streaming, stdin support, state tier, persistent identity,
  snapshot modes, restricted egress, and service/proxy support.
- Keep host secrets out of sandbox images by default. Prefer host-side proxies,
  provider control planes, or explicit secret-injection mechanisms with policy
  and audit events.
- Keep app-specific workflow, review, trace, persistence, and UI semantics out
  of this package. Consumers such as RunicAI or Libbit can build those above
  LitterBox.
- Do not add broad provider-specific shortcuts to `LitterBox` just because one
  backend exposes them. Add a provider-neutral contract first, then adapt.

## Core Modules

```text
lib/litter_box.ex                         # public facade and manager-facing API
lib/litter_box/backend_health.ex          # normalized health data
lib/litter_box/consumer_profiles.ex       # example profiles for common consumers
lib/litter_box/host_probe.ex              # host readiness probes
lib/litter_box/reports.ex                 # capability and health reports
lib/litter_box/vmsan_cli.ex               # Vmsan CLI boundary
lib/litter_box/sandbox/
  backend.ex                              # backend behaviour and fallback dispatch
  profile.ex                              # named sandbox configuration
  policy.ex                               # execution and network policy
  workspace.ex                            # host/sandbox workspace shape
  capabilities.ex                         # provider-neutral capability metadata
  manager.ex                              # supervised profiles, pools, sessions
  session*.ex                             # session handles and events
  execution_request.ex                    # execution input contract
  execution_result.ex                     # execution output contract
  attach*.ex                              # attach handles, bridge, event helpers
  process*.ex                             # long-running process handles/status
  file_ref.ex                             # file/artifact references
  checkpoint.ex                           # checkpoint/restore contract
  service.ex / proxy.ex / lease.ex        # service, proxy, and lease contracts
  backends/*.ex                           # backend adapters
```

## Current Backend Posture

- `:just_bash` and `:lua` are useful for dev/test and deterministic in-process
  work. They are not strong isolation boundaries.
- `:docker` is the practical local polyglot baseline. Treat it as container
  isolation, not a VM boundary.
- `:gvisor` should be modeled as a stronger container runtime option when the
  local Docker runtime supports it.
- `:vmsan` is the current Firecracker/KVM path. Keep direct Firecracker
  orchestration behind future backend work unless implementation pressure proves
  otherwise.
- `:sprites` and `:remote` are hosted sandbox/provider paths. Preserve provider
  identity, hibernation, checkpoint, and URL/proxy semantics through normalized
  LitterBox contracts.

## Documentation Anchors

- [README.md](./README.md): user-facing overview and quick start.
- [ARCHITECTURE.md](./ARCHITECTURE.md): current boundary, contracts, and design
  principles.
- [ROADMAP.md](./ROADMAP.md): phased future work and prior-art references.
- RunicAI context:
  - `../runic_ai/.docs/046-ai-code-sandboxing-research.md`
  - `../runic_ai/.docs/050-sandbox-serverless-mesh-and-libbit-consumer-next-steps.md`
  - `../runic_ai/.docs/052-runic-sandbox-streaming-and-mcp-dogfood-plan.md`
  - `../runic_ai/.docs/053-runic-sandbox-consumer-driven-improvement-plan.md`
- Libbit context:
  - `../libbit/.docs/workspace-sandbox-and-graph-memory-architecture-exploration.md`
  - `../libbit/.docs/container_infrastructure_providers_plan.md`
  - `../libbit/.docs/firecracker_local_provider_plan.md`
  - `../libbit/.docs/durable_execution.md`
  - `../libbit/.docs/restate_durable_execution_approach.md`

## Coding Conventions

- Follow normal Elixir style: `snake_case` functions and variables,
  `PascalCase` modules, pattern matching over nested conditionals where it
  improves clarity.
- Use `with` for linear `{:ok, value}` / `{:error, reason}` chains.
- Do not use `String.to_atom/1` on user or provider input.
- Do not use map access syntax on structs. Use `struct.field`.
- Prefer structured parsing and provider boundary modules over ad hoc string
  manipulation.
- Add tests for new contract behavior before broad backend work.
- Keep comments short and useful. Do not narrate obvious assignments.

## Validation Expectations

For contract-only changes:

```bash
mix test
mix compile --warnings-as-errors
mix format
```

For Docker workspace, restricted egress, attach, or image/runtime changes, also
run the relevant script or live smoke when the host supports it, and check that
containers/networks are cleaned up.

For Vmsan, Sprites, or remote provider changes, run the focused tests first and
then a live smoke only when host prerequisites or credentials are available.
Record whether the result is real execution or readiness/preflight only.
