# Releasing

1. Bump `VERSION` in `eng`, commit.
2. Tag `vX.Y.Z` and push the tag: `git push origin vX.Y.Z`.
3. The `mcp-release.yml` workflow compiles `eng-mcp` for all platforms and
   attaches `eng-mcp-vX.Y.Z-<asset>.{tar.gz,zip}` to the release. **Wait for it
   to finish** (check the Actions tab).
4. Ensure the GitHub release exists for the tag (the workflow attaches to it; or
   run `gh release create vX.Y.Z --generate-notes`).
5. ONLY after assets exist: in homebrew-tap and scoop-bucket, run
   `./update.sh eng-leader-tools` (fills the source-tarball hash AND the
   per-platform eng-mcp asset hashes — the URLs are hashed directly, so the
   assets must be present first), then commit + push each.
6. Verify: `brew update && brew upgrade eng-leader-tools`; confirm
   `libexec/eng-mcp` exists and `eng mcp install --dry-run` shows the binary path.
