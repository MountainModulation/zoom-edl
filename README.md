# zoom-edl

Auto-updating Palo Alto External Dynamic List for Zoom IP ranges.

**Source:** `https://assets.zoom.us/docs/ipranges/Zoom.json`  
**EDL URL (after setup):** `https://YOUR-ORG.github.io/zoom-edl/zoom-edl.txt`  
**Update cadence:** Every 6 hours via GitHub Actions  
**Watchdog:** Raspberry Pi — Slack alerts if EDL goes stale or count drops  

---

## Repo layout

```
zoom-edl/
├── .github/workflows/update-zoom-edl.yml   ← scraper / GitHub Actions
├── scripts/fetch_zoom_ips.py               ← Zoom JSON parser
├── docs/zoom-edl.txt                       ← EDL file (served by GitHub Pages)
├── pi-watchdog/                            ← Pi watchdog scripts + installer
│   ├── zoom-edl-watchdog.sh
│   ├── watchdog.conf
│   ├── install.sh
│   ├── zoom-edl-watchdog.service
│   └── zoom-edl-watchdog.timer
└── README.md
```

---

## Setup (one time)

### 1. Create the repo and enable GitHub Pages

1. Create a new **private** repo named `zoom-edl` under your org.
2. Push all files from this directory to it.
3. Go to **Settings → Pages**:
   - Source: `Deploy from a branch`
   - Branch: `main`, folder: `/docs`
   - Save
4. GitHub will show you the Pages URL — it will be:
   `https://YOUR-ORG.github.io/zoom-edl/zoom-edl.txt`

### 2. Trigger the first workflow run

Go to **Actions → Update Zoom EDL → Run workflow**.  
This writes real Zoom IPs to `docs/zoom-edl.txt` and commits them.  
After the run, verify the file is live at your Pages URL.

### 3. Configure Palo Alto / Panorama

#### Create the EDL object
```
Objects > External Dynamic Lists > Add
  Name:        Zoom-IPs-EDL
  Type:        IP List
  Source:      https://YOUR-ORG.github.io/zoom-edl/zoom-edl.txt
  Repeat:      Every Hour
  Exceptions:  (none needed)
```

#### Wire it into GlobalProtect split tunneling
```
Network > GlobalProtect > Gateways > [Your GW]
  > Agent > Client Settings > [Profile]
  > Split Tunnel > Access Route > Exclude

  Add: Zoom-IPs-EDL
```

> **PAN-OS version note:** EDL references in GP split tunnel exclude routes
> require PAN-OS 10.1+. On 9.x you'll need to reference the EDL in a
> security policy (no-decrypt / allow) and handle routing separately.

#### Force an immediate EDL refresh (CLI)
```
> request system external-list refresh type ip name Zoom-IPs-EDL
> show object external-list all
```

### 4. Install the Pi watchdog

Copy the `pi-watchdog/` directory to your Pi — **use scp, do not paste**:

```bash
scp -r pi-watchdog/ pi@10.19.42.53:~/zoom-edl-watchdog/
ssh pi@10.19.42.53
cd ~/zoom-edl-watchdog
chmod +x install.sh zoom-edl-watchdog.sh
sudo ./install.sh
```

The installer will:
- Prompt for your Slack webhook URL (same one used by the DDNS watchdog)
- Prompt for your GitHub Pages EDL URL
- Send a test Slack message
- Install systemd service + timer (runs hourly)
- Run the watchdog once immediately

#### Verify
```bash
systemctl list-timers | grep zoom-edl
journalctl -t zoom-edl-watchdog -n 20
sudo /opt/zoom-edl-watchdog/zoom-edl-watchdog.sh   # force a run
```

---

## Slack alerts

| Event | Icon | Meaning |
|---|---|---|
| EDL URL unreachable | 🚨 | GitHub Pages down or URL wrong |
| EDL not changed in 8h | 🚨 | GitHub Actions likely failing |
| Entry count dropped >20% | 🚨 | Zoom changed JSON schema |

Alerts throttle to once per 6 hours per condition — same behavior as the DDNS watchdog.

---

## Operational notes

| Topic | Detail |
|---|---|
| Zoom's JSON schema | If their format changes, the Actions run exits non-zero and no bad commit lands. Watchdog will alert on staleness within 8h. |
| IPv6 | Included — Zoom does publish IPv6 ranges |
| EDL size | ~500 CIDRs — well within Palo Alto's 150k limit |
| GitHub Actions minutes | Well within free tier — each run takes ~20 seconds |
| Private repo vs public | Either works for GitHub Pages on paid orgs; free orgs need a public repo for Pages |

---

## Relationship to zoom-ip-watch

`zoom-ip-watch` — your existing repo — monitors Zoom IPs and alerts you when they change.  
`zoom-edl` — this repo — actually *updates* the firewall automatically.

Both can (and should) coexist. They watch the same source but serve different purposes.
