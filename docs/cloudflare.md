# Cloudflare Tunnel and Access

A unit's console is plain HTTP on the site network. To reach it from anywhere, give each unit a Cloudflare Tunnel:
the unit dials out to Cloudflare (no open ports, no public IP, works behind any NAT), Cloudflare serves it over HTTPS
on a hostname of yours, and Cloudflare Access decides who gets as far as the console's own login. A free Cloudflare
account and a domain on Cloudflare are enough.

```
browser or fleet console ── HTTPS ── Cloudflare, Access ── tunnel ── cloudflared on the unit ── localhost:80
```

The examples use `example.com` and a unit called `tv-lobby-01`.

## One tunnel per unit

In the Cloudflare dashboard, under Zero Trust, Networks, Tunnels:

1. Create a tunnel of type Cloudflared, named after the unit (`tv-lobby-01`).
2. Of the install commands it shows, copy only the token: the long string starting `eyJ`. Don't run the commands;
   tvlink installs and runs cloudflared itself.
3. Add a public hostname (a published application route): subdomain `tv-lobby-01`, domain `example.com`, service
   `HTTP` and `localhost:80`.

Use a first-level hostname, `tv-lobby-01.example.com`, not `tv-lobby-01.tv.example.com`: Cloudflare's free
certificate covers one level of subdomain only.

One tunnel per unit, not one shared tunnel: each unit then has its own token, revoked on its own if the unit or its
card is lost, and the dashboard shows each unit's connection.

## Set the token on the unit

In the unit's console, Settings, paste the token into Tunnel Token and Save; or on the unit:

```bash
read -rs t && sudo tvlink set TUNNEL_TOKEN="$t" # paste, then Enter: kept out of the shell's history
```

The first time, tvlink installs cloudflared from Cloudflare's apt repository (`pkg.cloudflare.com`, signed by its key),
which takes a minute; after that it updates with the unit's security updates. It then runs `tvlink-tunnel.service`.
Within a few seconds the console's Status and `tvlink doctor` say `Tunnel: connected`, and
`https://tv-lobby-01.example.com` opens the console.

- The token is a key to the unit's console from the internet, so it is kept as a root-only file,
  `/etc/tvlink/tunnel-token`, never in `tvlink.conf` on the SD card's FAT partition (which any PC can read). Pages,
  the API and `tvlink show` only say `(set)`. A new card needs it set again.
- cloudflared gets it from systemd as a credential only it can read, runs as a throwaway user, and never has it on its
  command line.
- Turn the tunnel off by clearing Tunnel Token (tick Clear and Save) or `sudo tvlink set TUNNEL_TOKEN=`: the service
  stops and stays off, and the file goes. cloudflared stays installed.
- `Tunnel: not connected` for more than a minute: `journalctl -u tvlink-tunnel -b`. A wrong or revoked token shows as
  `Register tunnel error`; the network needs outbound UDP 7844 (QUIC) or TCP 7844 (HTTP/2) to Cloudflare.
- A unit or card lost: delete its tunnel (or refresh its token) in the dashboard, and revoke the unit's API tokens.

## Access in front of every unit

Without Access, anyone who finds the hostname gets the console's login page. With it, they never reach the unit
unless Cloudflare has already checked who they are. Under Zero Trust, Access, Applications:

1. Add a self-hosted application named eg `tvlink units`, with each unit's hostname (one application can list many;
   add each new unit's).
2. An Allow policy for people: eg emails ending in `@example.com`, or an identity provider group. They log in to
   Access, then to the console with its own password.
3. If a fleet console manages the units: a Service Auth policy that includes its service token (below).

The console trusts no header that Access or a proxy sets: every request still needs its session or an API token.
Cloudflare's `Cf-Visitor` or `X-Forwarded-Proto` header only marks the session cookie `Secure`, and
`Cf-Connecting-IP`, on requests from cloudflared on the unit itself, only keys the login rate limit per visitor.

## A service token for the fleet console

The [fleet console](fleet.md) calls each unit's API from a server, where no one can log in to Access. Under Zero
Trust, Access, Service credentials (Service Auth), create a service token named eg `tvlink-fleet` and copy its client
ID and client secret (the secret is shown once). Add a Service Auth policy with it to the units' application, as
above, and enter both in the fleet console with each unit. The fleet console sends them as `CF-Access-Client-Id` and
`CF-Access-Client-Secret`, with the unit's own API token.

Leave Bot Fight Mode off for these hostnames (or skip it for them in a WAF rule): it can challenge the fleet console,
which is not a browser.

## The fleet console behind its own tunnel

The fleet console runs on a server of your own on `127.0.0.1:8080` ([fleet](fleet.md)). Give it a tunnel the same way:

1. A tunnel named eg `tvlink-fleet`, public hostname `tvlink.example.com`, service `HTTP` and `localhost:8080`.
2. On the server, install cloudflared from `pkg.cloudflare.com` (Cloudflare's instructions for Debian and Ubuntu) and
   run it as units do, from this repo's unit file:

   ```bash
   read -rs t && echo "$t" | sudo install -D -m 600 /dev/stdin /etc/tvlink/tunnel-token # paste the token, Enter
   sudo install -m 644 tvlink-tunnel.service /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now tvlink-tunnel
   ```

3. An Access application for `tvlink.example.com` with an Allow policy for the people who manage the fleet only.

SES LHQ's own deployment is the example: its fleet console is `tvlink.seslhq.com`, and each unit has its own tunnel
at a first-level hostname such as `tv-lobby-01.seslhq.com`, all behind Access.
