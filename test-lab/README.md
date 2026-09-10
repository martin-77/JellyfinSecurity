# JellyfinSecurity test lab

A self-contained, repeatable environment for reproducing and verifying plugin
behaviour **without** depending on a remote/production Jellyfin server. Spin it
up locally, point the plugin at a real OIDC provider (Keycloak) and a hostile
reverse proxy (nginx), and exercise the exact flows that bite users in the
field — OIDC group→library/admin mapping, force-password onboarding, the
proxy-class HTML corruption (#95), passkeys, app-passwords, and the SSRF guard.

```
 browser ──► nginx (8097, "nasty" proxy)  ─┐
 browser ──► Jellyfin (8096, direct) ───────┼─► Jellyfin + the locally-built plugin
 browser ──► Keycloak (8080, OIDC/groups) ──┘
```

---

## 0. Storage — keep it OFF the C: drive

Two separate things eat disk; both should live on a fast non-C drive (this PC
uses **G:**, a 2TB NVMe SSD):

1. **The lab's Jellyfin data** (config DB, image cache, the staged plugin) —
   controlled by `TESTLAB_DATA` in `.env`. Already set to `G:/jellyfin-testlab/data`.
2. **Docker's own image store** (the jellyfin/keycloak/nginx images, ~2–3 GB) —
   this defaults to C:. Move it:
   - **Docker Desktop:** Settings → Resources → Advanced → *Disk image location* → `G:\docker-data`, then Apply & Restart.
   - **Podman:** `podman machine stop; podman machine set --image-path G:\podman-data; podman machine start` (or recreate the machine with `--volume`).

The small config files (this folder) stay in the repo on F: — they're tiny and
version-controlled. `.env` and `data/` are git-ignored.

---

## 1. One-time setup

1. **Install a container runtime** (your choice; the lab works with either):
   - Docker Desktop (free for personal use), or
   - Podman Desktop (free, no licensing). Use `podman compose` in place of `docker compose`.
2. **Hosts file** — add this line so the OIDC issuer URL is identical for the
   browser *and* the Jellyfin container (run Notepad as admin):
   `C:\Windows\System32\drivers\etc\hosts`
   ```
   127.0.0.1   keycloak.test
   ```
3. **Point storage at G:** — see section 0 (`.env` is already done; do the Docker
   image-location step).

---

## 2. Bring it up

```powershell
cd F:\tmp\JellyfinSecurity\test-lab

# Tier 1 — Jellyfin + plugin only (2FA, passkeys, app-passwords, set-password page)
pwsh ./stage-plugin.ps1            # builds the plugin + stages it onto G:
docker compose up -d jellyfin

# Tier 2 — add real OIDC (group→library, group→admin, force-password, #103/#104)
docker compose up -d jellyfin keycloak

# Tier 3 — add the hostile proxy (#95, proxy side of #102)
docker compose up -d
```

| What | URL | Creds |
|------|-----|-------|
| Jellyfin (direct)      | http://localhost:8096        | set up on first run |
| Jellyfin (via proxy)   | http://localhost:8097        | same server |
| Keycloak admin console | http://keycloak.test:8080    | `admin` / `admin` |

First Jellyfin run: complete the setup wizard, create your admin user, then
confirm the plugin loaded under **Dashboard → Plugins** (and **My Profile →
Two-Factor Authentication** appears).

To re-stage after a code change: `pwsh ./stage-plugin.ps1` (rebuilds + restarts).
To re-stage without rebuilding: `pwsh ./stage-plugin.ps1 -NoBuild`.

---

## 3. Wire up OIDC (Tier 2+)

Keycloak imports a ready realm `jellyfin-test` with:
- client `jellyfin` (secret `jellyfin-test-secret`),
- groups `jellyfin-users` / `jellyfin-admins`,
- a `groups` claim mapper,
- users **testuser** / `testpass` (in jellyfin-users) and **adminuser** / `adminpass` (in jellyfin-admins).

In the plugin's OIDC provider config:
- **Discovery URL:** `http://keycloak.test:8080/realms/jellyfin-test/.well-known/openid-configuration`
- **Client ID:** `jellyfin`  •  **Client secret:** `jellyfin-test-secret`
- **Groups claim:** `groups`; map `jellyfin-admins` → admin, `jellyfin-users` → a library.
- ⚠️ **Enable "Allow private networks"** for this provider. Inside the container
  `keycloak.test` resolves to the host-gateway (a private IP), so the SSRF guard
  (#103) blocks discovery otherwise — which is itself a faithful repro of #103.

> The realm export is best-effort; if import looks off, open the Keycloak admin
> console and verify the client redirect URIs (`http://localhost:8096/*`,
> `http://localhost:8097/*`) and the `groups` mapper.

---

## 4. Test recipes (issue → how to exercise it)

- **#100 force-password + back-button (v2.5.16):** enable *Force password setup*
  on the provider, sign in as a brand-new OIDC user → you land on `/TwoFactorAuth/SetPassword`.
  - *(a) robustness:* set a strong policy (e.g. min 12 + upper + digit) — the page
    must show those exact rules; with the page open, stop the jellyfin container's
    policy endpoint (or break the token) and reload → it must show the error +
    "Continue to Jellyfin for now", **not** a silent "16 characters".
  - *(b) escape:* on the set-password page press **Back** to `/web` → you must be
    bounced straight back to the set-password page. Set the password → you reach
    `/web` and stay there.
- **#65 / #96 group mapping:** sign in as adminuser → becomes admin; as testuser →
  gets exactly the mapped library (verify in Dashboard → Users → Policy).
- **#95 proxy corruption:** open Setup via the **proxy** (http://localhost:8097)
  with the `sub_filter` enabled → the page must render normally and *Linked
  Sign-In Methods* must load (proves the v2.5.15 tag-splitting fix).
- **#102 (proxy side):** drive passkey/app-password setup via the proxy and
  compare to direct (:8096) to isolate proxy vs client issues.
- **#103 SSRF guard:** point a provider's discovery at a private IP with "Allow
  private networks" OFF → discovery must be refused.

---

## 5. Teardown / reset

```powershell
docker compose down                 # stop containers, keep data
docker compose down -v              # stop + remove named volumes
Remove-Item G:\jellyfin-testlab\data -Recurse -Force   # full wipe (fresh Jellyfin)
```

---

## Troubleshooting

- **OIDC redirects to a page that won't load / "can't reach keycloak":** the
  hosts entry (`127.0.0.1 keycloak.test`) is missing, or Keycloak's issuer
  differs between browser and container. Both must use `http://keycloak.test:8080`.
- **Discovery fails with an SSRF/"not allowed" error:** enable *Allow private
  networks* on the provider (host-gateway is a private IP) — see §3.
- **Plugin doesn't appear:** re-run `pwsh ./stage-plugin.ps1`; confirm files exist
  under `<TESTLAB_DATA>/jellyfin-config/plugins/JellyfinSecurity/`; check
  `docker logs jstl-jellyfin` for `Loaded assembly Jellyfin.Plugin.TwoFactorAuth`.
- **Windows bind-mount is slow/empty:** make sure the G: drive is shared with the
  container runtime (Docker Desktop → Settings → Resources → File sharing).
