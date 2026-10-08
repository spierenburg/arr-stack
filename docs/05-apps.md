# 5. Wiring the apps together

Create the `media` stack in Portainer if you haven't yet ([step 3](03-gitops-stacks.md#create-the-stacks-in-portainer)). In Portainer → Stacks → `media`, every container should be *running* and `gluetun` should be *healthy*.

Do the steps below in order, because each one needs something from the one before. Containers reach each other **by container name** on the `proxy` network: `http://sonarr:8989`, not the public URL. The one exception is qBittorrent, which is reached at **`gluetun:8080`** because it shares Gluetun's network.

The `docker logs` and `docker exec … wget` commands below only read. They don't change the deployment.

## 5.1 VPN + qBittorrent

**Confirm the VPN before anything else:**

```bash
docker exec gluetun wget -qO- https://ipinfo.io/ip     # must be the VPN's IP, not your home IP
```

The first login password for qBittorrent is printed in the container log:

```bash
docker logs qbittorrent 2>&1 | grep -i password
```

Open `http://qbittorrent.home.arpa` and configure:
- **Tools → Options → Web UI:** set your own username and password.
- **Downloads:** *Default Torrent Management Mode* = **Automatic**. Default save path = `/data/torrents`.
- **Advanced:** *Network interface* = `tun0`. This is a second kill switch on top of Gluetun.
- **BitTorrent:** set seeding limits as you prefer.
- **Categories** (right-click in the left sidebar → Add category):
  - `tv` with save path `/data/torrents/tv`
  - `movies` with save path `/data/torrents/movies`

**Port forwarding (optional, gives much better speeds)** if `VPN_PORT_FORWARDING=on`:

```bash
docker logs gluetun 2>&1 | grep -i "port forwarded"
```

Enter that port under qBittorrent → Options → Connection → *Listening port*. The VPN provider can change the port when the tunnel reconnects. The Gluetun wiki explains how to automate updating it (`VPN_PORT_FORWARDING_UP_COMMAND`).

## 5.2 Sonarr and Radarr

Do the same steps in both apps (Sonarr shown, Radarr in brackets):

1. **First visit:** set authentication to *Forms (login page)* and create a user.
2. **Settings → Media Management:**
   - *Root folder*: `/data/media/tv` (`/data/media/movies`)
   - *Use Hardlinks instead of Copy*: **on** (Show Advanced → Importing)
   - Turn on renaming if you want clean file names.
3. **Settings → Download Clients → + → qBittorrent:**
   - Host `gluetun`, port `8080`, plus the username and password from 5.1
   - Category `tv` (`movies`)
   - Click *Test*, then *Save*.
4. **Settings → General:** copy the **API key**. Prowlarr, Bazarr and Seerr need it.

## 5.3 Prowlarr (indexers)

1. Set up authentication the same way as above.
2. **Settings → Apps → + Sonarr:**
   - Prowlarr server `http://prowlarr:9696`
   - Sonarr server `http://sonarr:8989`
   - API key from 5.2
   Repeat for Radarr (`http://radarr:7878`).
3. **Indexers → Add Indexer:** add your trackers. They sync to Sonarr and Radarr automatically.

Some public indexers sit behind Cloudflare challenges. Those need FlareSolverr, which isn't included here. Add it only if you actually hit that.

## 5.4 Bazarr (subtitles)

- **Settings → Sonarr:** address `sonarr`, port `8989`, API key. **Settings → Radarr:** address `radarr`, port `7878`, API key.
- **Settings → Languages:** create a language profile, for example Dutch + English, and set it as the default for series and movies.
- **Settings → Providers:** add OpenSubtitles.com (free account) and others.

Paths line up because Bazarr mounts `/data/media` at the same location as Sonarr and Radarr.

## 5.5 Jellyfin

Open `http://jellyfin.home.arpa`:
1. In the setup wizard, create an admin user and add the libraries:
   - *Movies* → `/data/media/movies`
   - *Shows* → `/data/media/tv`
2. **Dashboard → Users:** create one account per household member. Logins are local, so they keep working during internet outages.

## 5.6 Seerr (requests)

Open `http://requests.home.arpa`:
1. Choose **Jellyfin**. Server `jellyfin`, port `8096`, no SSL. Sign in with the Jellyfin admin account.
2. Sync the libraries.
3. **Services → Add Radarr:** hostname `radarr`, port `7878`, API key. Select the quality profile and root folder `/data/media/movies`, and tick *Default server*. Do the same for Sonarr (`sonarr`, `8989`, `/data/media/tv`).
4. **Users → Import Jellyfin users.** Household members log in with their Jellyfin account.

## End-to-end check

1. Request a movie in Seerr.
2. It appears in Radarr, and the download shows up in qBittorrent under the `movies` category.
3. Once it finishes, Radarr imports it and Jellyfin shows it after a library scan, or sooner if you add Jellyfin under Radarr → Connect.
4. **Confirm the hardlink worked:**
   ```bash
   stat -c '%h %n' /srv/data/media/movies/*/*.mkv
   ```
   The first number should be `2`, meaning one file with two names. If it's `1`, the import made a copy. Re-check the paths in 5.2.

## Next step: quality profiles

The default quality profiles are mediocre. The [TRaSH Guides](https://trash-guides.info/) explain good settings. [Recyclarr](https://recyclarr.dev/) can sync them into Sonarr and Radarr automatically, and can run as one extra container once everything above works.
