# alpha-app — island facts

Body shape: edit

- The service lives in `src/`; its deploy manifest is `deploy/app.yaml`.

## Membership

Release bookkeeping and the roadmap epics are not intake's.

- exclude label: epic
- exclude title: ^(release|chore\(deps\)):

## Sources

| question | read | note |
|---|---|---|
| which version is deployed | `deploy/app.yaml`, `image:` | the tag, not the digest |

## What a ride can do

- **Recipe**: the repo's own `devbox run test`.
