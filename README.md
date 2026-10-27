# viper-deploy-action

Tells [Viper](https://github.com/twinsunllc/viper) that a build reached an environment, and which
fixes it carries. Viper uses that to say "Fixed in build 1041" in the widget and both portals, to
tell a tester on an older build where to get the fix, and to take the "after" picture when the fix
lands.

There is no build number to keep in step. On each run the action:

1. Asks Viper for the last commit CI reported for the environment (a signed `GET`).
2. Walks the commits HEAD added since then (`last..HEAD`) and the ones it took away
   (`HEAD..last`), so a forward deploy, a rollback and a deploy from another branch are all
   described the same way. A shallow checkout is deepened as needed.
3. Reads the pull requests and Jira keys from those commits, and posts the deploy, signed with the
   environment's deploy token.

On the first run, or when git can't find the last commit (a force-push), it sends HEAD alone with
`range_known: false`, and Viper links no fixes from that deploy.

## A web app

After the deploy step, in the job that deploys:

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      # ... build and deploy to staging ...
      - name: Tell Viper about the deploy
        uses: twinsunllc/viper-deploy-action@<v1 commit SHA> # v1
        with:
          viper-url: https://viper.twinsunsolutions.com
          environment-id: ${{ vars.VIPER_ENVIRONMENT_ID }}
          token: ${{ secrets.VIPER_DEPLOY_TOKEN }}
```

The environment's ID and its deploy token are on the environment's card in the project's settings
in Viper. Add the ID as the `VIPER_ENVIRONMENT_ID` variable and the token as the
`VIPER_DEPLOY_TOKEN` secret. The page can also say
which commit it was built from, in a `<meta name="viper-commit">` tag beside `viper-build`, so Viper
knows exactly which deploy a reviewer is looking at.

## A Flutter app with two platforms (Set&Co)

One `report_deploy` job in `staging.yml` that waits for both platform jobs. It runs when at least
one platform reached its testers, and says which ones did:

```yaml
jobs:
  ios:
    # ... build, upload to TestFlight ...
  android:
    # ... build, upload to Firebase App Distribution ...

  report_deploy:
    needs: [ios, android]
    if: always() && (needs.ios.result == 'success' || needs.android.result == 'success')
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
      - name: Which platforms got the build
        id: platforms
        env:
          IOS: ${{ needs.ios.result }}
          ANDROID: ${{ needs.android.result }}
        run: |
          list=""
          [ "$IOS" = success ] && list="$list ios"
          [ "$ANDROID" = success ] && list="$list android"
          echo "list=$list" >> "$GITHUB_OUTPUT"
      - name: Tell Viper about the build
        uses: twinsunllc/viper-deploy-action@<v1 commit SHA> # v1
        with:
          viper-url: https://viper.twinsunsolutions.com
          environment-id: ${{ vars.VIPER_STAGING_ENVIRONMENT_ID }}
          token: ${{ secrets.VIPER_DEPLOY_TOKEN }}
          platforms: ${{ steps.platforms.outputs.list }}
```

The build's name comes from the `build-1040` tag `bin/deploy` pushes, so "1040" is what people see.
Production builds aren't tagged, so `production.yml` passes the number it computed:

```yaml
        with:
          # ...
          build: ${{ needs.find_build_number.outputs.build_number }}
```

The app tells Viper its commit through the `VIPER_COMMIT` define that CI writes into the staging
flavor's dart-define file beside `VIPER`, for example `VIPER_COMMIT=${{ github.sha }}`. See the
"Install in a Flutter app" block on the environment in Viper.

## Inputs

| Input | Required | What |
|---|---|---|
| `viper-url` | yes | Viper's address. |
| `environment-id` | yes | The environment's ID. |
| `token` | yes | The environment's deploy token, from a secret. |
| `build` | no | The build's name for people. Default: the highest `build-tag` tag at HEAD (local or on origin), else the run number. |
| `build-tag` | no | The tag pattern that names a build. Default `build-*`; `build-1041` names the build "1041". |
| `platforms` | no | `ios`, `android` and `web`, separated by commas or spaces. Empty means every platform. |
| `deployed-by` | no | A name or an email. Default: the workflow's actor. |

Outputs: `deploy-id`, `build`, `outcome` (`created`, `filled` or `duplicate`) and `range-known`.

## What it reads from the commits

From each range, oldest commit first, with the later commit winning when two say different things
about the same pull request:

| Commit subject | Means |
|---|---|
| `Merge pull request #330 from owner/SETCO-921-crew-filter` | adds #330 and SETCO-921 (keys from the branch name) |
| `Add the crew filter SETCO-921 (#330)` (a squash) | adds #330 and SETCO-921 |
| `Merge pull request #340 from owner/revert-330-SETCO-921-crew-filter` | takes #330 and SETCO-921 away; adds nothing |
| `Revert "Add the crew filter SETCO-921 (#330)" (#340)` | takes #330 and SETCO-921 away; adds nothing |
| `Revert "..."`, a plain revert of either form | takes the reverted PR and its keys away |
| Anything else, like `Fix it (SETCO-922 follow-up)` | nothing |

Jira keys are uppercase (`SETCO-921`) and only ever come from merged branch names and merge or
squash subjects, so a commit that mentions another ticket links nothing. Pull requests merged by
rebase leave no PR number in a subject and aren't seen; a revert of a revert is ignored.

What `HEAD..last` holds (a rollback, or another branch's deploy) is reported as taken away. The
pull request and Jira key lists cover each range however long it is; only `commit_shas` is cut to
the newest 500.

## Pinning

Use the action by its full commit SHA with the tag in a comment, as above, so a moved tag can't
change what runs with your deploy token. To find v1's commit:

```sh
git ls-remote https://github.com/twinsunllc/viper-deploy-action refs/tags/v1
```

## Safety

- The token goes in by environment variable, and the HMAC is worked out in the shell, so the token
  never appears in another program's arguments or a process list. The tests check this.
- Each request is signed over a timestamp Viper accepts for five minutes: the body for the
  `POST`, `GET /webhooks/deploys/<id>/latest` for the `GET`. A token only works for its own
  environment.
- The delivery ID is `<run id>-<run attempt>-<job>`, so a retried step is one deploy and a
  re-run is another.

## Requirements

`bash` (3.2 or later), `git`, `jq`, `openssl`, `curl` and `od`, all on GitHub's Ubuntu and macOS
runners. Run `actions/checkout` first, at any depth. For a private repository, keep checkout's
default `persist-credentials` so the action can fetch history and tags.

## Developing

`bash test/run.sh` builds git histories in temporary repositories and runs the script against
`test/server.py`, a stand-in for Viper that checks signatures the same way. CI runs it on Ubuntu
and macOS, on each runner's `bash` and on `/bin/bash`, along with shellcheck and the action itself
through `uses: ./`.
