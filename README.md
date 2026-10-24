# TorScale

A tiny Docker container that joins your Tailscale network as a regular device
and acts as an **exit node that sends all traffic through Tor**. Pick it as the
exit node on your phone or laptop and you are on Tor, no extra apps needed.

The network topology will look roughly like this:
```
  +---------+
  | device1 |\
  +---------+ \                  VPS / home server
  +---------+  \ +-----------+    +-----------+    +-----+    +----------+
  | device2 |----| Tailscale |<-->| TorScale  |<-->| Tor |<-->| Internet |
  +---------+  / +-----------+    +-----------+    +-----+    +----------+
  +---------+ /
  | device3 |/
  +---------+
```

TorScale is a fork of [TailGuard](https://github.com/juhovh/tailguard), with the
WireGuard tunnel replaced by Tor.

Your devices talk to TorScale over the usual encrypted WireGuard tunnel of
Tailscale. TorScale hands every TCP connection and DNS query to Tor and drops
everything else, so nothing ever leaves the container outside of Tor.

## Benefits

- one tap in the Tailscale app switches a device to Tor, and back
- works on devices that can't run Tor themselves (phones, TVs, consoles, iOS)
- doesn't take your only VPN slot on mobile: you keep your tailnet as well
- `.onion` sites work in any browser while the exit node is selected
- fail-closed: if Tor is down, connections fail instead of leaking
- small: Alpine, a single stripped `tailscaled` binary with only the features
  an exit node needs, and Tor
- always up to date: a new image and GitHub release are published automatically
  whenever Tailscale ships a new version

## Installation

Generate an [auth key](https://login.tailscale.com/admin/settings/keys) (or skip
it and log in through the URL printed in the logs), then start the container:

```
docker run -d \
  -e TS_AUTHKEY=tskey-auth-XXXXXXXX \
  -v ./state/tailscale:/var/lib/tailscale -v ./state/tor:/var/lib/tor \
  --cap-add NET_ADMIN --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
  -p 41641:41641/udp \
  --restart unless-stopped \
  --name torscale ghcr.io/eurocruz/torscale:latest
```

Or with `docker compose`: edit `docker-compose.yml`, then run
`docker compose up -d` (add `--build` to build the image yourself).

Then, in the Tailscale admin console, open the `torscale` machine, choose
**Edit route settings** and enable **Use as exit node**. To approve it
automatically, tag the node and add an auto approver to your ACL:

```
"autoApprovers": { "exitNode": ["tag:torscale"] }
```

Finally, select `torscale` as the exit node on any device and visit
<https://check.torproject.org>.

That's it, happy browsing!

### Configuration

Supported configuration parameters through environment:
- `TS_AUTHKEY` - Tailscale auth key, if not set a login URL is printed to the log
- `TS_HOSTNAME` - Tailscale hostname for this device (**default:** torscale)
- `TS_LOGIN_SERVER` - URL of the control server if not using Tailscale default (e.g. Headscale)
- `TS_PORT` - Tailscale UDP port, should be exposed by Docker (**default:** 41641)
- `TS_DEVICE` - Tailscale TUN device name (**default:** tailscale0)
- `TS_EXTRA_ARGS` - Any additional `tailscale up` flags, e.g. `--advertise-tags=tag:torscale`
- `TOR_<Option>` - Any [torrc option](https://2019.www.torproject.org/docs/tor-manual.html.en), see below
- `TORRC_EXTRA` - Raw multi-line torrc snippet appended as is
- `TOR_BOOTSTRAP_TIMEOUT` - Seconds to wait for Tor to bootstrap (**default:** 300)

The `TS_*` parameters follow the naming of the official Tailscale Docker image
[parameters](https://tailscale.com/kb/1282/docker) where possible.

### Tor options

Every environment variable named `TOR_<Option>` becomes a line `<Option> <value>`
in torrc. Anything after a second underscore is ignored, which allows repeating
an option:

| environment                         | torrc                        |
|-------------------------------------|------------------------------|
| `TOR_ExitNodes={de},{nl},{ch}`      | `ExitNodes {de},{nl},{ch}`   |
| `TOR_ExcludeExitNodes={??}`         | `ExcludeExitNodes {??}`      |
| `TOR_StrictNodes=1`                 | `StrictNodes 1`              |
| `TOR_MaxCircuitDirtiness=300`       | `MaxCircuitDirtiness 300`    |
| `TOR_Bridge_1=1.2.3.4:443 FINGERPR` | `Bridge 1.2.3.4:443 FINGERPR`|
| `TOR_Bridge_2=5.6.7.8:9001 FINGERPR`| `Bridge 5.6.7.8:9001 FINGERPR`|

If any `Bridge` is set, `UseBridges 1` is added automatically. The generated
torrc is printed to the log on every start.

Don't override `TransPort`, `DNSPort`, `User` or `DataDirectory`, the firewall
rules depend on them.

### How it works

- `tailscaled` runs with a real TUN device and advertises itself as an exit
  node with `--netfilter-mode=off`, so Tailscale itself never forwards or NATs
  anything.
- iptables rules on `tailscale0`:
  - every TCP connection is redirected to Tor's `TransPort`;
  - DNS (UDP/TCP 53) is redirected to Tor's `DNSPort`;
  - everything else (UDP, ICMP, IPv6) is dropped, and forwarding is disabled.
- `/etc/resolv.conf` points to Tor, so the DNS queries that Tailscale clients
  send to the exit node over PeerAPI (MagicDNS) are resolved through Tor too.
- `.onion` names resolve to addresses in `10.192.0.0/10`, which are redirected
  into Tor like any other TCP connection.
- Streams are isolated per client and destination (`IsolateClientAddr
  IsolateDestAddr`).

### Limitations

- Only TCP and DNS go through Tor. UDP (QUIC, voice/video calls, games) and
  ping don't work. Browsers fall back from QUIC to TCP automatically.
- IPv6 is not supported, it is rejected so clients fall back to IPv4.
- Pluggable transports (obfs4, snowflake) are not included to keep the image
  small, only plain bridges work.
- This is not Tor Browser. Your browser fingerprint, cookies and logins still
  identify you. Use Tor Browser when you need real anonymity.

### Updates

`.github/workflows/update.yml` checks for a new Tailscale release every day.
When one is out, it bumps `TS_VERSION` in the Dockerfile, tags the commit with
the same version, publishes `ghcr.io/eurocruz/torscale:<version>` and `:latest`
for `amd64`, `arm64` and `arm/v7`, and creates a GitHub release. The image is
also rebuilt weekly to pick up Alpine and Tor security updates.

To update a running container, pull the new image and recreate it, or let
[Watchtower](https://github.com/containrrr/watchtower) do it for you.
