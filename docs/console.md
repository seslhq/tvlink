# Console

Every unit hosts its own console: web pages and a JSON API on port 80, for the unit's status, settings, actions,
logs, Wi-Fi, updates and API tokens. It works from a phone on the same network as the unit, or from anywhere through a
tunnel in front of it. No other server is needed.

![The Status page: a screenshot of the TV, the screen state, TV power and health](images/console-status.png)

## Claiming a unit

The console is on from the first install, but until it has a password it shows only a claim page. Claiming needs a
one-time code, so someone on the network who can't see the TV can't take the unit over.

1. Find the code. The splash shows it with the console's address, eg `Console: http://tv-lobby-01.local Code: K7M-4QX`.
   A unit already showing its page puts it on screen with `sudo tvlink identify`; on the unit, `sudo tvlink console
   claim` prints it.
2. Open the address (or `http://<IP>` where `.local` names don't resolve), enter the code and choose a password of at
   least 10 characters. The code then stops working and leaves the splash.

Forgotten the password: `sudo tvlink console reset` on the unit (eg over Raspberry Pi Connect) goes back to claim mode
and prints a new code. API tokens keep working.

## Pages

| Page | Shows or does |
| --- | --- |
| Status | The last screenshot (Take Screenshot for a new one), the screen state as the badge sees it, the TV's power, name, IP, version, uptime, and `tvlink doctor`'s health lines |
| Settings | Every setting `tvlink set` takes, as a form built from `tvlink keys --json`; values are checked by `tvlink set` and errors show beside the field |
| Actions | Reload Page, Identify, Take Screenshot, TV On, TV Off, and Reboot (asks first, on the page) |
| Logs | The last 200 lines of the kiosk, TV power and Wi-Fi network logs |
| Wi-Fi | The `WIFI*` settings and the networks the unit can see |
| Update | `tvlink update` with an archive URL and its SHA-256 ([operations](operations.md#updates)) |
| API Tokens | Create, list and revoke tokens for the API |

![The Settings page: a form with one field per setting, each with its hint and default](images/console-settings.png)

Passwords (`WIFI1_PSK`, `WIFI2_PSK`) are write-only: the page shows `(set)` or `(not set)`; a blank field keeps the
current one, and Clear removes it.

## Security

- **Privileges.** The console runs as its own system user, `tvlink-console`, in a systemd sandbox (read-only system,
  private `/tmp`, no home directories), with only the capability to bind port 80. It reaches root through sudo, for a
  fixed list of `tvlink` commands in `/etc/sudoers.d/tvlink-console` (`status`, `doctor`, `on`, `off`, `identify`,
  `reload`, `screenshot`, `reboot`, `logs`, `set`, `update`). Arguments go to sudo as a list, never through a shell,
  and sudo does not log them (`set` can carry a Wi-Fi password).
- **Login.** One password per unit, stored as a PBKDF2-SHA256 hash (600,000 rounds) readable only by the console user.
  Sessions are in memory (a restart logs everyone out) and expire after 12 hours. The cookie is `HttpOnly` and
  `SameSite=Strict`, and `Secure` when the request came through an HTTPS proxy (`X-Forwarded-Proto: https`).
- **Forms.** Every change needs the session's CSRF token. Five wrong passwords or claim codes from one address in five
  minutes (or 20 from all) lock logins out until the window passes.
- **Tokens.** Random 256-bit, shown once when made, stored as SHA-256 only. A token can do everything the console can,
  including updates, so give each fleet or script its own and revoke it when done.
- **Plain HTTP.** On the local network, traffic (including the password) is not encrypted. For access from elsewhere
  put a tunnel with HTTPS in front of it (eg Cloudflare Tunnel with Access); the console trusts no proxy header
  except as the hint for the cookie's `Secure` flag.

## API

JSON over HTTP under `/api/`. Authenticate with a token (`Authorization: Bearer TOKEN`), or with a logged-in session
plus the `X-CSRF-Token` header on changes (every page sends the token in that response header). Without either:
`401`. Errors are `{"error": "..."}`.

| Method and path | Body | Answer |
| --- | --- | --- |
| `GET /api/status` | | `name`, `ip`, `version`, `state` and `screen` (badge state), `code`, `host`, `tv`, `uptime` (s), `health` (lines), `screenshot` (time taken, or null) |
| `GET /api/settings` | | `version` and `keys`: `key`, `type` (`text`, `url`, `time`, `number`, `choice` with `choices`, `secret` with `set`), `label`, `hint`, `value`, `default` |
| `POST /api/settings` | `{"KEY": "value", ...}` | `{"ok": true}`, or `400` with `error` and the `key` it is about |
| `POST /api/action` | `{"action": "reload"}`: `reload`, `identify`, `screenshot`, `on`, `off` or `reboot` | `ok` and the command's `message` |
| `GET /api/screenshot` | | The last screenshot (JPEG), or `404` |
| `POST /api/screenshot` | | Takes one, then answers as GET |
| `GET /api/logs?part=kiosk` | | `{"kiosk": "..."}`; without `part`: kiosk, power and net |
| `GET /api/wifi` | | `networks`: `ssid`, `signal` (%), `security` |
| `POST /api/update` | `{"url": "https://...", "sha256": "..."}` | `ok` and `message` |
| `GET /api/tokens` | | `tokens`: `name`, `created` |
| `POST /api/tokens` | `{"name": "fleet"}` | `name` and `token`, shown only this once |
| `DELETE /api/tokens/NAME` | | `{"ok": true}`, or `404` |

```bash
curl -H "Authorization: Bearer $TOKEN" http://tv-lobby-01.local/api/status
curl -H "Authorization: Bearer $TOKEN" -d '{"OVERLAY_CORNER": "top-left"}' http://tv-lobby-01.local/api/settings
curl -H "Authorization: Bearer $TOKEN" -d '{"action": "reload"}' http://tv-lobby-01.local/api/action
```
