# Cap, built with cook

> **One changed comment. Seven rebuilds, or one.**

This is a fork of [Cap](https://github.com/CapSoftware/Cap), the open-source
screen recorder, with its build and verification graph redone in
[cook](https://github.com/LioraLabs/cook) through the `cook_pnpm` module.

Cap is a real polyglot product: a pnpm workspace with a Next.js web app, a
Tauri desktop app, shared TypeScript packages, a Chrome extension, and 48
Rust crates beside them. It was not designed around cook, and that's the
point: a build tool should be able to walk into a repository that already
has a life of its own and describe the work that's actually there.

The original `turbo.json` stays in-tree, untouched, so both descriptions of
the same pipeline can be read side by side. The interesting result is not
that cook can run pnpm scripts. It's that cook knows when an upstream task
ran *without changing the artifact its consumers receive*.

## The result

Two edits to the same file, `packages/env/index.ts`, the entry point of the
`@cap/env` package that the rest of the workspace imports. One edit appends
a comment. The other appends an export, a real API change. Same machine,
warm caches, each run starting from a settled steady state:

| Edit to `@cap/env`                 | cook                                      | Turbo                             |
| ---------------------------------- | ----------------------------------------- | --------------------------------- |
| Comment only                       | rebuilds `@cap/env`, **~1s**              | rebuilds **7 of 11 tasks, ~47s**  |
| Real API change                    | rebuilds `@cap/env` + `@cap/web`, ~30s    | rebuilds the same 7 tasks, ~47s   |

To Turbo these two edits are indistinguishable. The file's hash changed, so
`@cap/env`'s task hash changed, so by `^build` cascade everything downstream
re-runs: both application builds, every time, whether the change could have
affected them or not.

cook re-runs `@cap/env` too: half a second of `tsdown`. Then it hashes what
came out.

For the comment, the output bytes are unchanged. Every consumer keys on the
artifact it receives, not on the task that produced it, so their keys are
still valid and the cascade stops dead:

```text
comment changed
      │
      ▼
 @cap/env runs
      │
      ▼
output bytes unchanged
      │
      └── consumers stay cached
```

For the real API change, the output bytes did change, and cook re-runs
exactly the consumers that ingest them: `@cap/web`, where Next.js compiles
`@cap/env` into the app. The desktop app, `@cap/utils`, `@cap/database`,
and `@cap/web-backend` stay cached even then, because the bytes they
consume never moved. Turbo rebuilds the desktop app in both cases: its hash
cascade reaches it three edges away, through packages whose output never
changed.

That is the claim this repository exists to demonstrate:

> **Source invalidation does not have to become artifact invalidation.**
> The set of things worth rebuilding is the set of things that consume the
> changed bytes.

The benchmark measures two more things. A warm no-op is fast in both tools
(about a second each). And after `rm -rf` of every declared build output,
cook restores all of it from its content-addressed store in about a second.
Turbo restores from its cache too; in our runs that took anywhere from one
second to half a minute, because deleting outputs can disturb Turbo's own
input hashes and re-run the app builds. Because cook's store is just a
content-addressed directory, it
can be [shared](https://github.com/LioraLabs/cook/blob/main/docs/shared-cache.md):
point a teammate or a CI runner at the same path and an artifact built once
is never built twice.

## Reproduce it

The table above is printed by [`bench/compare.sh`](bench/compare.sh):

```sh
bash bench/compare.sh
```

It settles both caches, then measures each scenario from steady state for
both tools: warm no-op, the comment-only edit, the real API change, and the
delete-and-restore round. Edits touch only `packages/env` and are reverted
on exit. Expect five to ten minutes; the script re-settles both tools
between scenarios so that each measurement starts from a clean steady
state.

The numbers quoted here came from that script on a Ryzen 9 7950X (32
threads), cook 0.6.4 with `cook_pnpm` 0.5.0, Turbo 2.10.2. Yours will
differ in the absolute
seconds and should not differ in the rebuild counts. The comparison excludes
`@cap/sdk-recorder` on both sides; it fails to build under plain pnpm too.

## One graph for both halves

Turbo describes Cap's JavaScript tasks. It cannot see the Rust workspace
beside them.

cook doesn't ask the repository to pick an ecosystem. The JavaScript
workspace minted by `cook_pnpm` and the Rust recipes written directly in the
[`Cookfile`](Cookfile) share one project graph:

```text
package sources ──► pnpm build tasks ──► web / desktop / extension artifacts
       │
       ├──────────► cached test, typecheck, and lint units
       │
Rust sources ─────► cargo check / test / binaries
```

This is the role cook is built for: not replacing pnpm, Next.js, Cargo, or
anything else, but giving all of them one artifact model, one dependency
graph, and one content-addressed cache.

## What `cook_pnpm` does here

One `cook_pnpm.workspace({ ... })` call reads the workspace manifests and
mints package-scoped recipes from their scripts. In this repository that
comes to:

* ten JavaScript build recipes and nine verification recipes, named
  `<package>:<task>`;
* dependency edges matching `^build`;
* per-package output and environment overrides;
* a lockfile-keyed install step;
* cached test units for the checks that produce no artifacts.

Tasks with declared outputs become store-backed build units. Tasks without
become content-keyed test units whose passes are replayed.

If you maintain a `turbo.json` today, here is what that means for you:
everything in Cap's config survived the move, and porting it was mechanical.
`dependsOn: ["^build"]` became dependency edges, per-package overrides like
`"@cap/web#build"` kept their shape and their names, `globalDependencies`
became workspace-level inputs. Nothing you can express there is
unexpressible here.

Two things came out better than parity:

* Cap marks its test, lint, and typecheck tasks `"cache": false`, because
  Turbo has no files to restore for them. cook doesn't need a file to cache
  a result: they become content-keyed test units, and a package that hasn't
  changed doesn't re-test.
* Cap sets `globalEnv: ["*"]`, folding the entire ambient environment into
  every task hash; export an unrelated variable and Turbo rebuilds the
  world. The Cookfile declares the specific variables each app actually
  reads, and only those.

And one thing has no `turbo.json` equivalent at all: dependency artifacts
fold into consumers' cache keys, through discovered-input depfiles for
builds and ready-time inputs for checks. That is the machinery behind the
results table above. It's what lets cook tell a dependency whose sources
changed from a dependency whose consumed output changed.

## Build it

You need [cook](https://github.com/LioraLabs/cook), Node 20 or newer, and
pnpm 10 (corepack picks up the `packageManager` pin). Then:

```sh
pnpm install
cook modules install
```

The app builds read a root `.env`. No live services are needed; dummy
values satisfy the schemas, the same trick Cap's own CI uses:

```sh
cat > .env <<'EOF'
NODE_ENV=production
VITE_ENVIRONMENT=production
NEXT_PUBLIC_WEB_URL=http://localhost:3000
WEB_URL=http://localhost:3000
NEXTAUTH_URL=http://localhost:3000
NEXTAUTH_SECRET=dummy-nextauth-secret-dummy-nextauth-secret
DATABASE_URL=mysql://user:pass@localhost:3306/db
CAP_AWS_BUCKET=dummy-bucket
CAP_AWS_REGION=us-east-1
NEXT_PUBLIC_POSTHOG_KEY=dummy
NEXT_PUBLIC_POSTHOG_HOST=http://localhost:3000
VITE_POSTHOG_KEY=dummy
VITE_POSTHOG_HOST=http://localhost:3000
VITE_SERVER_URL=http://localhost:3000
EOF

cp .env apps/desktop/.env    # vinxi loads the app-local file
```

Then:

```sh
cook build    # everything Linux-buildable: JS workspace + Rust binaries
cook test     # vitest, tsc, cargo check, cargo test; all cached
```

`cook build` produces the library `dist/` trees, the Chrome extension
bundle, `apps/web/.next`, `apps/desktop/.output`, and the Rust binaries
that link on Linux under `target/debug/`.

Other targets:

```sh
cook menu                  # list every recipe and chore
cook "@cap/web:build"      # just the Next.js app
cook "@cap/desktop:build"  # just the desktop JS frontend
cook rust-check            # cargo check over the Linux-clean crate subset
cook rust-test             # cached library tests for the pure Rust crates
cook install               # lockfile-keyed pnpm install
```

## Scope, honestly

This fork models Cap's build and verification pipeline. It does not claim
the rest of the development workflow:

* 22 of the 48 Rust crates touch FFmpeg and don't compile on a host with
  FFmpeg 8, for an upstream reason: the pinned `ffmpeg-sys-next 7.x`
  expects headers that FFmpeg 8 removed. The desktop app's Tauri core is inside
  that set, so the Cookfile targets the Linux-honest subset.
* `@cap/sdk-recorder` is excluded from the aggregate; it fails under plain
  pnpm too.
* The web and desktop frontends build against the dummy CI-style `.env`.
* `pnpm dev` and the Docker orchestration remain driven by Cap's upstream
  scripts.

The Rust recipes are deliberately coarse today. They prove the Rust half
participates in the same graph; they do not yet model Cargo's dependency
graph crate by crate.

## Why this fork exists

cook did not choose Cap's frameworks, package boundaries, native
dependencies, or historical decisions. That's what makes it useful
evidence. This fork demonstrates two things:

1. cook can model a substantial modern monorepo without replacing the tools
   inside it.
2. An artifact-aware cache makes a more precise rebuild decision than a
   source-triggered task cascade.

The first proves reach. The second is the reason cook exists.

## License and credits

**Cap is Copyright © Cap Software, Inc.**, licensed under AGPLv3 with the
`cap-camera*` and `scap-*` crate families under MIT. See
[LICENSE](LICENSE) and [licenses/](licenses/). The full upstream
documentation, feature overview, and credits are preserved in
[README.cap.md](README.cap.md); those notices must travel with the code.

Cap is built by the team at [cap.so](https://cap.so). This fork changes the
build description, plus one resilience tweak: `turbopack.root` is pinned in
`apps/web/next.config.mjs` so a stray lockfile above the repo can't break
Turbopack's root inference. All credit for the product belongs upstream.

## Contributing

The cook-specific files in this fork (`Cookfile`, `cook.toml`, `bench/`,
this README) were developed with AI assistance, as a dogfooding exercise
for `cook_pnpm`.

The Cap application is not this fork's to govern: send product fixes and
features to [upstream Cap](https://github.com/CapSoftware/Cap) under its
contribution guidelines. Issues about the cook build belong here.
