# Contributing

Thanks for helping improve SwiftJSONSchemaGen. Bug reports, schema fixtures,
documentation fixes, and focused pull requests are welcome.

## Development setup

The package requires Swift 6.3. Install the pinned toolchain and run the checks with
[mise](https://mise.jdx.dev/):

```sh
mise install
mise run lint
mise run test
mise run build
```

You can also run the underlying commands directly:

```sh
Scripts/check-format.sh
swift test -q
Scripts/test-library.sh
Scripts/test-plugin.sh
swift build -q --configuration release
```

## Making a change

1. Open an issue for substantial behavior or public API changes so the design can be
   agreed before implementation.
2. Add a focused fixture or behavioral test for generator, CLI, or plugin behavior.
   Prefer tests that compile or execute generated code over snapshots that only repeat
   implementation details.
3. Keep the library, CLI, and build-tool plugin on the same generation semantics.
4. Update `README.md`, `Docs/`, `ARCHITECTURE.md`, and `CHANGELOG.md` when their
   documented contracts change.
5. Run the checks above and include the relevant evidence in the pull request.

Generated output is a user-facing API. Call out changes to names, optionality,
conformance, encoding, or decoding behavior even when they are bug fixes.

## Pull requests

Keep each pull request scoped to one coherent change and use a Conventional Commit
style title, such as `feat: support dependent schemas` or `fix: escape coding keys`.
Describe the triggering schema, the resulting Swift behavior, and the checks you ran.

By contributing, you agree that your contribution is licensed under the repository's
MIT license.

## Publishing this standalone package

Publish this directory as the repository root. Before the first push, replace
`YOUR-ORG` in `README.md` with the GitHub owner and verify the installation snippets
against the final repository URL.

## Cutting a release

1. Choose a Semantic Versioning tag such as `v0.1.0`.
2. Set the matching version in
   `Sources/SwiftJSONSchemaGenCLI/JSONSchemaGeneratorCommand.swift`. The packaging
   script rejects a tag that differs from the executable's `--version` output.
3. Move the relevant `CHANGELOG.md` entries from Unreleased into a versioned section
   with the release date.
4. Run the complete local gates:

   ```sh
   mise install
   mise run lint
   mise run test
   mise run build
   mise run release-check
   ```

5. Commit and push the release preparation, then create and push the tag:

   ```sh
   git tag -a v0.1.0 -m "Release 0.1.0"
   git push origin main v0.1.0
   ```

The tag starts `.github/workflows/release.yml`. It reruns formatting, package,
external-library, plugin, and relocated-archive checks on macOS and Linux. If every
gate passes, it creates a draft GitHub release with native binary archives and
SHA-256 checksum files. Review the generated notes and downloaded artifacts, then
publish the draft manually. GitHub supplies the source archives for the tag.
