# market-bot

An automated market bot for the Dune Awakening private server exchange. It runs as a k3s Deployment on the TrueNAS VM and continuously maintains sell listings for every tradeable item in the game, repriced dynamically based on sales velocity. It also buys underpriced player listings to drain cheap stock from the market.

## How it works

**Every 5 minutes** the bot checks for underpriced player listings and buys them (up to 50 per tick) at or below 1.05× the bot's own sell price.

**Every 30 minutes** the bot restocks and reprices its listings:

1. Loads the item catalog from `item-data.json`
2. Queries the exchange for its own existing listings (bot actor: **Revy**, actor ID looked up dynamically)
3. Removes listings whose price has drifted from the current target
4. Tops up any partially-depleted stacks to full `stack_max`
5. Creates **5 listings per quality grade** for each applicable item
6. Refreshes all order expiry times to game-time + 24 h

The bot only touches its own NPC orders — player listings are never modified (only purchased if below threshold).

### Grade listings

Items that can drop from overland testing stations (ecolabs) are listed at **each of grades 0–5**, for 30 listings per item. Grade eligibility is determined by the `is_gradeable` flag in `item-data.json` — any non-schematic, non-resource item with a `LootTier.*` tag is considered gradeable.

Items without a `LootTier` tag (crafted-only, story-progression) are listed at **grade 0 only**, 5 listings. Schematics and stackable materials are always grade 0 only.

### Pricing

Base price = `vendor_price × rarity_multiplier`:

| Rarity | Multiplier |
|--------|-----------|
| Common | 2× |
| Unique | 3× |
| Memento | 5× |

Prices adjust ±5–10 % per tick based on how much of each item sold. Floor = base price; ceiling = 5× base price.

### Exchange details

| Setting | Value |
|---------|-------|
| Exchange | HarkoVillage\_EX (ID 2) |
| Access point | HarkoVillage\_AP (ID 1) |
| Bot character | Revy (class `Revy`, actor ID **varies per server** — looked up dynamically) |
| Listings per gradeable item | 5 per grade × 6 grades (0–5) = 30 total |
| Listings per non-gradeable item | 5 (grade 0 only) |
| Order expiry | 24 h (game time) |

---

## Architecture

```
your machine
  └─ deploy.sh / deploy.ps1
       ├─ cross-compiles market-bot-linux (GOOS=linux GOARCH=amd64)
       ├─ scp → VM /opt/market-bot/bin/market-bot
       ├─ scp → VM /opt/market-bot/data/item-data.json
       └─ kubectl apply + rollout restart

TrueNAS VM (k3s)
  └─ Deployment: market-bot  (namespace: dune-market-bot)
       ├─ binary: hostPath /opt/market-bot/bin/market-bot
       ├─ data:   hostPath /opt/market-bot/data/
       └─ cache:  hostPath /opt/market-bot/cache/  (SQLite)
            └─ connects to PostgreSQL in funcom-seabass-* namespace
```

The bot runs entirely inside the cluster. The deploy scripts only need SSH access to the VM to upload files — no direct database access required from your machine.

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Go | 1.21+ | Required for building locally |
| SSH key | — | Auto-detected by deploy scripts (see below) |
| VM access | port 22 | Required for deploy |
| k3s cluster | running | Must have the Dune server Deployment active |
| VM OS | Alpine Linux | `openssh-sftp-server` must be installed (see First-time deploy) |

### SSH key

The deploy scripts search for an SSH key in this order:

1. `./sshKey` (repo root — gitignored)
2. `~/.ssh/dune`
3. `~/.ssh/id_ed25519`
4. `~/.ssh/id_rsa`

You can also set `SSH_KEY=/path/to/key` in `.deploy-config` or as an environment variable.

---

## Item data

`item-data.json` is committed to the repository. The deploy scripts upload it to the VM automatically — no extra steps needed.

---

## Building locally

All platforms require Go 1.21+. The binary is always cross-compiled for Linux/amd64 since it runs on the TrueNAS VM.

### macOS / Linux

```bash
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o market-bot-linux .
```

### Windows

```powershell
$env:GOOS="linux"; $env:GOARCH="amd64"; $env:CGO_ENABLED="0"
go build -trimpath -ldflags="-s -w" -o market-bot-linux .
```

The deploy scripts run the build automatically — you rarely need to build manually.

---

## Deploying

### First run — setup wizard

On the first run (or when `.deploy-config` is missing credentials) the script launches an interactive setup wizard that:

1. Finds or prompts for the SSH key
2. Prompts for the VM IP (auto-detects via Hyper-V on Windows)
3. Verifies the SSH connection
4. Discovers the DB host from the k3s service list
5. Lists battlegroups via `battlegroup list` on the VM and reads the application credentials from `~/.dune/<battlegroup>.yaml`
6. Saves everything to `.deploy-config` (gitignored)

You can re-run the wizard at any time:

```bash
./deploy.sh --setup     # macOS / Linux
.\deploy.ps1 -Setup     # Windows
```

### macOS / Linux

```bash
./deploy.sh
```

### Windows

```powershell
.\deploy.ps1
```

On Windows the server typically runs in a Hyper-V VM. The setup wizard auto-detects the IP. You can also pass it explicitly:

```powershell
.\deploy.ps1 -VmIp 172.28.144.1
```

### What the deploy scripts do

Both scripts perform the same steps:

1. Cross-compile the bot for Linux/amd64
2. Upload the binary to `/opt/market-bot/bin/market-bot` on the VM
3. Upload `item-data.json` to `/opt/market-bot/data/`
4. Render a manifest with injected DB credentials and apply it via `kubectl apply`
5. Roll out the Deployment and wait for it to become ready
6. Tail the last 40 log lines

### First-time VM setup (Alpine Linux)

Before the first deploy, ensure the SFTP subsystem is available — SCP will fail without it:

```bash
sudo apk add openssh-sftp-server
sudo sed -i 's|^#\?Subsystem sftp .*|Subsystem sftp /usr/lib/ssh/sftp-server|' /etc/ssh/sshd_config
sudo rc-service sshd restart
```

The k8s namespace, Deployment, and host directories are all created automatically by the deploy script.

---

## Configuration

Credentials and connection details are stored in `.deploy-config` (gitignored, created by `--setup`). The deploy scripts discover the DB host dynamically from the k3s service list on each run; credentials come from `.deploy-config`.

You can override any value with environment variables:

```bash
DUNE_DB_HOST=... DUNE_DB_USER=... DUNE_DB_PASS=... ./deploy.sh
```

### All settings

| Setting | Default | Source |
|---------|---------|--------|
| DB host | detected from k3s service | `.deploy-config` / `DUNE_DB_HOST` |
| DB port | `15432` | ConfigMap `DB_PORT` / `DUNE_DB_PORT` |
| DB user | from battlegroup YAML | `.deploy-config` / `DUNE_DB_USER` |
| DB password | from battlegroup YAML | `.deploy-config` / `DUNE_DB_PASS` |
| DB name | `dune` | ConfigMap `DB_NAME` |
| Buy interval | `5m` | ConfigMap `BUY_INTERVAL` |
| List interval | `30m` | ConfigMap `LIST_INTERVAL` |
| Buy threshold | `1.05` | `-buythreshold` flag |
| Max buys/tick | `50` | `-maxbuys` flag |
| Item data path | `/data/item-data.json` | ConfigMap `ITEM_DATA_PATH` |
| Cache DB path | `/cache/market-bot-cache.db` | ConfigMap `CACHE_DB_PATH` |

---

## Logs

```bash
# Shown automatically after each deploy, or directly:
ssh -i ./sshKey dune@192.168.0.72 \
  "sudo kubectl logs -n dune-market-bot -l app=market-bot --tail=50 -f"
```

Key log lines:

```
market-bot catalog: 1391 listable items         ← items loaded from JSON
market-bot exchange inventory id: 1613          ← bot's exchange inventory
market-bot bot actor id: 158 (Revy)             ← NPC actor confirmed/created
market-bot game epoch learned: unix 1776...     ← game clock calibrated from player orders
market-bot tick: 4875 created, 0 topped up, 0 pruned, 0 errors
```

---

## Wiping bot listings

To remove all bot listings from the database (e.g. before a redeploy with new prices), the deploy script does this automatically on each run. To do it manually:

```sql
WITH bot AS (
  SELECT id FROM dune.actors WHERE class = 'Revy' LIMIT 1
),
del_orders AS (
  DELETE FROM dune.dune_exchange_orders
  WHERE owner_id = (SELECT id FROM bot) AND is_npc_order = TRUE
  RETURNING item_id
),
del_items AS (
  DELETE FROM dune.items
  WHERE id IN (SELECT item_id FROM del_orders WHERE item_id IS NOT NULL)
  RETURNING id
)
SELECT
  (SELECT COUNT(*) FROM del_orders) AS orders_deleted,
  (SELECT COUNT(*) FROM del_items)  AS items_deleted;
```

> **Note:** The bot's actor ID is assigned dynamically and **varies per server instance** — never hardcode it. The query above looks it up by the `Revy` class name, which is always correct.

Run this from the **dune-admin** Database tab or any PostgreSQL client with access to the cluster.

After wiping, delete the SQLite cache on the VM so the bot does not reuse stale data:

```bash
ssh -i ./sshKey dune@192.168.0.72 \
  "sudo rm -f /opt/market-bot/cache/market-bot-cache.db"
```

Then restart:

```bash
ssh -i ./sshKey dune@192.168.0.72 \
  "sudo kubectl rollout restart deployment/market-bot -n dune-market-bot"
```

---

## Tests

```bash
go test ./...
```

Verifies the category mask encoding (category → 32-bit market filter code) for known items. Run after any changes to `pricing.go`.
