# 3. GitOps: deploying the stacks with Portainer

## The rules

1. **Git is the only source of truth.** What's on `main` is what runs. No editing stacks in the Portainer web editor, no `docker compose up` or `docker run` on the host, and no "quick fix" with `docker exec` that changes files.
2. **Every image is pinned by digest** (`name:tag@sha256:…`). A tag can be re-pushed, a digest can't, so the same commit always deploys the same bytes. CI rejects unpinned images.
3. **No config files from the host.** Traefik is configured entirely through flags and labels in the compose file. The only host paths are **state** (`CONFIG_ROOT`, app databases written by the apps) and **media** (`DATA_ROOT`).
4. **Secrets live in Portainer's stack variables**, never in git. `stack.env.example` in each stack folder documents the names.
5. **Changing something = commit → PR → merge.** Portainer notices `main` changed and redeploys.
   **Rolling back = `git revert`.** Portainer deploys the previous digests.

Read-only debugging is always fine: `docker logs`, `docker ps`, `docker inspect`, and the Portainer log and console views.

## Two stacks

| Stack | Compose path | Contains | Why separate |
|---|---|---|---|
| `infra` | `stacks/infra/compose.yaml` | Traefik, AdGuard Home | DNS for the whole house. A bad media change must never touch it |
| `media` | `stacks/media/compose.yaml` | Gluetun, qBittorrent, *arr, Jellyfin, Seerr | Changes weekly (Renovate) |

## Repository setup (on GitHub)

All of this happens on **your copy** from [README → Step 0](../README.md#step-0-make-your-own-copy-required) (*Use this template*), never on the template itself.

1. **Check the copy works:** open the *Actions* tab of your copy. The `validate` workflow should run green on its first commit.
2. **Branch protection on `main`:** require pull requests and require the `validate` check to pass. CI checks digest pins, compose syntax and scripts ([.github/workflows/validate.yml](../.github/workflows/validate.yml)). On a free GitHub account this needs a **public** copy, because protection rules on private repos need a paid plan.
3. **Install the [Renovate GitHub app](https://github.com/apps/renovate)** on the repo. Every Saturday it opens PRs that bump image digests: one for infra, one for media, one for Portainer ([renovate.json](../renovate.json)). Nothing merges automatically, because merging means deploying, and that's your call.
4. **If the repo is private:** create a fine-grained GitHub token with read-only *Contents* access to just this repo. Portainer uses it to clone.

## Create the stacks in Portainer

Do this for **infra first**, then media. Portainer's labels differ slightly between versions. These are from the LTS line.

Portainer → **Stacks → Add stack**:

- **Name:** `infra` (later `media`)
- **Build method:** *Repository*
- **Repository URL:** `https://github.com/<you>/arr-stack`
- **Repository reference:** `refs/heads/main`
- **Compose path:** `stacks/infra/compose.yaml`
- **Authentication:** on if the repo is private. Username plus the token from above.
- **GitOps updates:** on
  - Mechanism: **Polling**, interval `5m`. Polling needs nothing exposed to the internet.
  - **Re-pull image:** on
- **Environment variables:** add every variable from `stacks/infra/stack.env.example` with real values. *Load variables from .env file* also works: fill in a copy locally, upload it, then delete the local copy.
- **Deploy the stack**

Repeat for `media`, using `stacks/media/compose.yaml` and `stacks/media/stack.env.example`. `DOMAIN` and `CONFIG_ROOT` must be identical in both stacks.

> Why not mount config files from the repo? Portainer clones the repo inside its own container, so `./file` bind mounts don't resolve to files on the host. Portainer CE doesn't support that. Flags and labels avoid the problem and keep everything in one reviewable file.

## Verify the infra stack

From any LAN machine:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -H "Host: traefik.home.arpa" http://SERVER_IP/
```

**Check:** you get `200` or `302`. A `404` means Traefik has no route for that name. This works before DNS is set up because the `Host` header stands in for the name. Continue with [DNS](04-dns-adguard.md).

## Day-to-day change flow

```
edit in a branch → PR → CI validate ✔ → merge → Portainer polls (≤5 min) → redeploys changed services
```

**Verify a deploy by the image digest, not by "it says running":**

```bash
docker inspect --format '{{.Config.Image}}' sonarr   # must show the digest you just merged
```

If Portainer didn't pick it up, look at Portainer → Stacks → `media` for a git error (token expired, for example). Fix the cause, then use **Pull and redeploy** in the stack view. That's the only manual deploy trigger allowed, and it still deploys from git.
