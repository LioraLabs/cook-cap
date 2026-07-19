# Cap, built with Cook

This is a fork of **[Cap](https://github.com/CapSoftware/Cap)** — the open-source
screen recorder — with **Turborepo replaced by the
[Cook build system](https://github.com/LioraLabs/cook)** via the `cook_pnpm`
module. `turbo.json` is left untouched in-tree so the two descriptions of the
same pipeline can be read side by side.

It exists as a worked example of Cook on a real, large JS/TS monorepo
(10 apps, 16 packages, 48 Rust crates, 20k★). The interesting part isn't that
Cook can run pnpm scripts — it's what the cache does with them:

> Every task's key folds the **content** of the artifacts it consumes — its own
> sources, its dependencies' built output, the lockfile, declared env values.
> A dependency that rebuilds to byte-identical output re-runs **nothing**
> downstream; a real API change re-runs **exactly** the consumers that read it.
> Turbo's `dependsOn` hash cascade cannot tell those two edits apart.

Concretely, on this repo (same machine, steady state): a comment-only edit in
`@cap/env` rebuilds **1 package in ~0.8s** under Cook versus **6 packages in
~47s** under Turbo (both app builds re-run for a byte-identical result). Warm
no-op is ~0.25s across the whole graph, `rm -rf` of every build output restores
from the content-addressed store in ~1s, and the test/lint/typecheck tasks that
Cap's own `turbo.json` marks `"cache": false` are cached test units with
replayed passes. The Rust half — which Turbo cannot see at all — is three more
recipes in the same DAG.

> **Scope.** This Cookfile targets the **Linux-honest subset**. 22 of the 48
> crates (everything touching ffmpeg, including the desktop app's Tauri core)
> do not currently build on Linux for an **upstream** reason: the pinned
> `ffmpeg-sys-next 7.x` predates FFmpeg 8's header removals. The Next.js web
> app and the desktop's JS frontend build against a dummy `.env` (the same
> trick Cap's own CI uses); the `pnpm dev` / docker orchestration is not
> ported and remains driven by the upstream scripts. `@cap/sdk-recorder` is
> excluded from the aggregate — it fails to build under plain pnpm too.

## Building

You need [Cook](https://github.com/LioraLabs/cook), **Node ≥ 20**, and
**pnpm 10** (corepack picks up the `packageManager` pin). Then:

```sh
pnpm install              # once; Cook's install probe keys on the lockfile after that
cook modules install      # fetch the cook_pnpm module pinned in cook.toml
```

The app builds read a root `.env`. No live services are needed — dummy values
satisfy the schemas (this mirrors Cap's CI):

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
cp .env apps/desktop/.env   # vinxi loads the app-local file (as Cap's CI does)
```

Then:

```sh
cook build                # everything Linux-buildable: JS workspace + Rust binaries
cook test                 # all checks: vitest, tsc, cargo check, cargo test — cached
```

`cook build` produces the library `dist/` trees, the Chrome extension bundle,
`apps/web/.next`, `apps/desktop/.output`, and the portable Rust binaries under
`target/debug/`.

Other targets:

```sh
cook menu                    # list every recipe and chore
cook "@cap/web:build"        # just the Next.js app
cook rust-check              # cargo check over the 26 Linux-clean crates
cook rust-test               # cargo test --lib on the pure crates (78 tests)
cook install                 # pnpm install --frozen-lockfile (cached by lockfile hash)
```

## What Cook builds

One `cook_pnpm.workspace{}` call in the [Cookfile](Cookfile) mints the whole JS
side from `package.json` scripts: ten build recipes and nine check recipes,
named `<package>:<task>`. Tasks with declared outputs become cached, store-
restored build units; tasks without become engine test units (content-
fingerprinted, pass results replayed, run by `cook test`). Turbo's per-package
overrides (`"@cap/desktop#build"`), `globalDependencies`, and `globalEnv`
map onto per-package `#` task keys, workspace-level `inputs`, and declared
`env` keys respectively. Dependency artifacts fold into consumers' keys via
discovered-inputs depfiles (builds) and ready-time glob inputs (checks), which
is what makes the comment-vs-API-change distinction above possible.

The Rust half is three plain recipes: an aggregate `cargo check` over the
26-crate Linux-clean closure, `cargo test --lib` on the pure crates, and
`cargo build` of the binaries that link on Linux.

## License and credits

**Cap is Copyright (c) Cap Software, Inc.**, licensed under **AGPLv3** with the
`cap-camera*` / `scap-*` crate families under MIT — see [LICENSE](LICENSE) and
[licenses/](licenses/). All third-party components remain under their original
licenses. The full upstream documentation, feature overview, and credits are
preserved verbatim in **[README.cap.md](README.cap.md)** — those notices must
travel with the code.

Cap is built by the team at https://cap.so — this fork changes only the build
description (plus one resilience tweak: `turbopack.root` is pinned in
`apps/web/next.config.mjs`, because a stray lockfile above the repo makes
Turbopack's root inference break module resolution); all credit for the
product belongs upstream.

## Contributing and a note on how this was built

The **Cook build files** in this fork (`Cookfile`, `cook.toml`, this README)
were developed with AI assistance, as a dogfooding exercise for `cook_pnpm`.

The **Cap application** is not this fork's to govern: send product fixes and
features to [upstream Cap](https://github.com/CapSoftware/Cap) under their
contribution guidelines. Issues specific to *this* Cook build belong here.
