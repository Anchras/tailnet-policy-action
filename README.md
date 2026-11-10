# Anchras tailnet policy

Keep a tailnet's policy document in a repository: every pull request tests
it, and every push to the default branch applies it. This works on any
tailnet whose provider keeps a policy per tailnet (Anchras Network,
Tailscale). Headscale keeps one policy for the whole deployment and refuses.

The pipeline signs in with a **tailnet trust credential**, not a
person's session or API key:

- **Workload identity federation** (recommended): the CI job's own OIDC ID
  token is exchanged for a short-lived API token. No secret is stored in CI.
- **OAuth client**: a client secret, stored as a CI secret, exchanged the same
  way.

Use **two credentials**:

| Job | Scope | Trusts | Can |
|-----|-------|--------|-----|
| Pull request checks | `policy_file:read` (`tailnet.acl.read`) | pull requests only | `test`, `diff` |
| Apply | `policy_file` (`tailnet.acl.read`, `tailnet.acl.update`) | the default branch only, through a protected environment | `apply` |

A pull request runs the workflow file from its own head, so anyone who can
push a branch can change what a pull request job does. With one credential
that can write, such a job could apply an unreviewed policy. The pull request
credential cannot: `test` uses `CheckACL`, which validates and runs the
policy's tests with read access only, and writes nothing.

A credential's API tokens act as the member who created it, capped by its
scope, so that member must be allowed to edit the policy (admin or owner).

## The commands

| Command | What it does | Needs |
|---------|--------------|-------|
| `anchras tailnets policy test --file policy.hujson` | Validates the file on the server exactly as a save would (syntax, `tests`, `sshTests`, `runTests`, `dataTests`) through `CheckACL`, and writes nothing. | `tailnet.acl.read` |
| `anchras tailnets policy diff --file policy.hujson [--exit-code]` | Shows a unified diff from the live policy to the file. `--exit-code` exits 6 when they differ. | `tailnet.acl.read` |
| `anchras tailnets policy apply --file policy.hujson [--etag-cache <path>] [--force]` | Saves the file. The save runs the same validation and tests first and writes nothing if they fail. The write is conditional on the version just read, so a concurrent edit is never overwritten silently. On Anchras Network it prints the save report. | `tailnet.acl.update` |

`--tailnet <uuid>` (or `ANCHRAS_TAILNET`) names the tailnet. A `policy_file`
credential cannot list tailnets, so in CI always set it. A file that already
matches the live policy is not written; line endings and a trailing newline do
not count as a difference.

### Drift: edits made outside the repository

`--etag-cache <path>` records, after each apply, the version that apply
wrote, as the server reports it (`UpdateACLResponse.etag`). On the next apply,
if the live policy is no longer that version, someone changed it elsewhere
(the dashboard's policy editor, `anchras acls update`, Terraform), and
`apply` refuses with exit 5 rather than discard their edit. Bring the change
into the file (`anchras tailnets policy diff` shows it) and push again, or
rerun with `--force` to write over it.

Without a recorded version (the first run, or a lost cache) the apply still
refuses to write over an edit made between its own read and write, but cannot
see an edit made before it. Tailscale's API does not report the version a
write produced, so on a Tailscale tailnet `apply` clears the cache after each
write and only that concurrent-edit guard applies.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success (valid; applied or nothing to apply; no differences) |
| `1` | The policy is invalid or a policy test failed; nothing was written |
| `2` | Server error, or the live policy could not be read from the provider |
| `4` | The credential was refused or lacks the scope |
| `5` | `apply` refused: the live policy changed since the last apply, or during this one |
| `6` | `diff --exit-code`: the file and the live policy differ |
| `7` | Bad invocation, or a local file (the policy, the etag cache) could not be read or written |

### Signing in from the environment

When there are no saved CLI credentials and no `ANCHRAS_API_KEY`, the CLI
exchanges a trust credential named in the environment:

| Variables | Exchange |
|-----------|----------|
| `ANCHRAS_OAUTH_CLIENT_SECRET` | OAuth client credentials at `/api/v2/oauth/token` |
| `ANCHRAS_OAUTH_CLIENT_ID` + `ANCHRAS_ID_TOKEN` (or `ANCHRAS_ID_TOKEN_FILE`) | Workload identity federation at `/api/v2/oauth/token-exchange` |

The exchange goes to the command's `--server`, else to `ANCHRAS_SERVER`; with
neither set the CLI refuses rather than send the credential to a default. It
refuses plain `http://` except to a loopback address. Every `anchras` command
honours these variables, not only `tailnets policy`.

## Set up

1. Export the current policy into the repository:

   ```bash
   anchras acls get --tailnet <tailnet-uuid> > policy.hujson
   ```

2. In the repository's settings, create an environment (here
   `tailnet-policy`) whose deployment branches are limited to the default
   branch, with required reviewers if you want a second pair of eyes on each
   apply.

3. Create the two federated identities. GitHub's OIDC subject for a pull
   request job is `repo:<owner>/<repo>:pull_request`; for a job that uses an
   environment it is `repo:<owner>/<repo>:environment:<name>`:

   ```bash
   anchras tailnets trust-credentials create-federated \
     --description "policy checks (pull requests)" \
     --issuer https://token.actions.githubusercontent.com \
     --audience anchras \
     --subject 'repo:my-org/network-policy:pull_request' \
     --scope policy_file:read

   anchras tailnets trust-credentials create-federated \
     --description "policy apply (main)" \
     --issuer https://token.actions.githubusercontent.com \
     --audience anchras \
     --subject 'repo:my-org/network-policy:environment:tailnet-policy' \
     --claim ref=refs/heads/main \
     --scope policy_file
   ```

   Each prints a client ID. Store them as repository variables
   (`ANCHRAS_POLICY_CHECK_CLIENT_ID`, `ANCHRAS_POLICY_APPLY_CLIENT_ID`). Do not
   trust `repo:<owner>/<repo>:*` with `policy_file`: that lets any branch's
   workflow write the policy.

   With OAuth clients instead, create one per job
   (`create-oauth-client --scope policy_file:read` and `--scope policy_file`),
   keep the apply secret as an environment secret of `tailnet-policy`, and
   never expose it to pull request jobs.

4. Add the pipeline below.

## GitHub Actions

This composite action
installs the CLI from your server over https (`<server>/cli-releases/`,
checked against the published SHA-256, or against `cli-sha256` when you pin
one), exchanges the job's GitHub OIDC token inside the step that uses it
(never in `$GITHUB_ENV` or on disk), runs `test` on pull requests with the
diff a merge would apply in the job summary, and `apply` on the default
branch. It keeps the etag cache between runs with `actions/cache`.

```yaml
# .github/workflows/tailnet-policy.yml
name: Tailnet policy
on:
  pull_request:
    paths: [policy.hujson]
  push:
    branches: [main]
    paths: [policy.hujson]
  schedule:
    - cron: '17 6 * * 1' # weekly: keeps the etag cache and reports drift
  workflow_dispatch:

permissions:
  contents: read
  id-token: write # the GitHub OIDC token the action exchanges

jobs:
  check:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Anchras/tailnet-policy-action@v1
        with:
          action: test
          server: https://platform.anchras.com
          tailnet: 00000000-0000-0000-0000-000000000000
          client-id: ${{ vars.ANCHRAS_POLICY_CHECK_CLIENT_ID }}
          audience: anchras

  apply:
    if: github.event_name != 'pull_request' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: tailnet-policy
    concurrency:
      group: tailnet-policy # one apply at a time
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@v4
      - uses: Anchras/tailnet-policy-action@v1
        with:
          action: apply
          server: https://platform.anchras.com
          tailnet: 00000000-0000-0000-0000-000000000000
          client-id: ${{ vars.ANCHRAS_POLICY_APPLY_CLIENT_ID }}
          audience: anchras
```

The examples use the moving `v1` tag. For reproducibility, replace `v1` with the full commit SHA of a reviewed release. Inputs: `server` (https) and `tailnet`
(required); `policy-file` (default `policy.hujson`); `client-id` + `audience`
or `client-secret`; `action` (`auto`, `test` or `apply`); `force` (`true`
writes over drift); `cli-sha256`.

**Keep the cache alive.** GitHub evicts an Actions cache entry unused for 7
days, and an apply with nothing restored cannot see an edit made before it.
The weekly `schedule` above re-applies the unchanged file, which writes
nothing and keeps the cache; if someone edited the policy in the dashboard,
that run fails with exit 5 and tells you. When nothing was restored, the apply
step says so in a warning annotation.

**The job summary is visible to anyone who can see the workflow run**, which on
a public repository is everyone. It contains the policy diff.

The action discovers whether policy RPCs use the server root or `/api` before
passing the API base to the CLI. CLI downloads still use the supplied server URL.

## Runner requirements

Linux or macOS on amd64 or arm64, with Bash, curl, jq, awk, and either
sha256sum or shasum installed. Windows runners are unsupported.
Use GitHub-hosted runners or a clean dedicated runner without saved Anchras
CLI credentials or ANCHRAS_API_KEY: these take precedence over the action's
trust credential. actions/cache v6 requires runner version 2.327.1 or later.

## Limitations

- Cache eviction removes the cross-run drift guard for that apply; the action
  warns. The first apply should follow a deliberate review of the live policy.
- Tailscale does not return a written policy version; only the concurrent-edit
  guard applies there. Headscale is unsupported.
- Multiple writers for a tailnet cause drift refusals.
- CLI checksums come from the configured server unless cli-sha256 is pinned.
  A checksum fetched from the same server does not protect against that server
  being compromised. CLI signatures are not verified by this action.
- A release pin fixes the action scripts; the CLI downloaded from your server
  can change. Pin cli-sha256 to require a reviewed binary.
- Policy diffs in job summaries are public when workflow runs are public.

## Data and support

The CLI sends the policy and trust credential to the Anchras server you
configure. OIDC authentication also requests a token from GitHub. The diff
is written to the GitHub job summary, and the last applied version is kept
in the repository's Actions cache. Review your configured server's data
handling before use.

Report action problems through this repository's GitHub Issues. Remove
credentials and private policy details from any report.

## License

Copyright 2026 Anchras BV. Licensed under Apache-2.0; see LICENSE.
