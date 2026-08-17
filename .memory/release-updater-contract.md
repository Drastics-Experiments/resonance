# Release and Windows updater contract

- Production YouTube download failures seen on public v2.0.2 were version skew: the cross-platform resolver hardening landed after that release. Current source already contains the resolver fix; no runtime-only production switch was found.
- The direct-release unsigned desktop option must embed `resonanceUpdateAuthenticity=unsigned` in the packaged Windows `package.json`. Production-signed packages embed `production` and continue to require the same valid Authenticode publisher.
- Windows packaging uses an explicit `build.files` allowlist. `main.cjs` began requiring `listening-history.cjs` without that file being added, producing an immediate installed-app startup crash. Keep `validate-packaged-app.cjs` in CI so the built `app.asar` startup dependency closure and embedded updater policy are verified after packaging.
- The unsigned updater path is valid only when both the installed executable and downloaded NSIS installer report Authenticode `NotSigned`. Environment variables never select a packaged policy.
- Release Studio stages and validates a private draft before publishing. Retries reuse matching assets by name and size, upload only missing assets, and stop on unexpected or ambiguous draft state.
- A candidate build, annotated tag, or private draft is not a public release. Do not claim the YouTube fix is in production until a later explicitly authorized release is published and verified.
