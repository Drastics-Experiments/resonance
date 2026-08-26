# Mobile song import audit

Audited current HEAD `645f0f2` on 2026-08-26. This was a read-only app-code audit; the container had neither Java/Android tooling nor Swift/Xcode, so native runtime tests were unavailable.

## Confirmed current gaps

- iOS and Android web-import previews ignore the selected video mode and resolve the preview as audio. Actual downloads still receive the selected mode.
- iOS and Android Files imports silently discard per-file failures. Neither path reports a failed count or filename, and neither has focused regression coverage.
- iOS advertises movie-file import but validates every selected file with `AVAudioPlayer`; video-only or unsupported movie containers are deleted after the validation error with no notice.
- Android does not reject copied files when both metadata and playable-duration inspection fail, so invalid content can be registered as a zero-duration fallback track.
- Android classifies scheme-less domains such as `www.youtube.com/watch?...` as links, but provider resolvers require `https`, producing an avoidable unsupported-source failure.

## Confirmed fixed regressions

- Current HEAD contains the iOS playlist row-identity, provider-position, transfer-order, playable-capacity, and continuation fixes from PR #58.
- Current HEAD contains the Android playlist pagination, repeated-row/fallback, failed-dedupe, and partial-import cancellation fixes from PR #58.
- Existing iOS `MobileLocalImportTests` and Android playlist parser/outcome policy tests cover those fixed paths.

## Latent concurrency note

- Concurrent duplicate source downloads are not guarded atomically in current mobile import services. Current playlist imports are sequential, so this is not presently user-reproducible; carry the adoption-gate work from `f20fae9` before enabling concurrent mobile downloads.
