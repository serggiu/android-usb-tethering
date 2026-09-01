# samsung-tethering

Turn an Android phone (Samsung S24+ etc.) into an internet connection for a
Mac over USB. Uses [TetherKit](https://github.com/XiaoMiku01/TetherKit), a
**kext-free, user-space RNDIS driver** — no kernel extensions, no SIP
changes, no reduced security, works on Apple Silicon (M1–M4) and Intel,
macOS 13.3+.

## Why this exists

macOS ships **no RNDIS driver**. When you enable USB tethering, most Android
phones present themselves as a Windows-style RNDIS ethernet device; on a Mac
the built-in ECM driver fails and no network interface ever appears (the log
shows something like `AppleUserECMData::start(RNDIS Ethernet Data...) fail`).

TetherKit sidesteps this: it speaks RNDIS in **user space** over libusb and
hands the resulting Ethernet frames to macOS through a `feth` virtual
interface pair. Result: the phone shows up as a normal network interface
(`feth0`) and this repo's scripts wire it up (DHCP lease) and test it.

## Requirements

- macOS 13.3 or newer (Apple Silicon or Intel)
- [Homebrew](https://brew.sh)
- Phone with USB tethering, connected with a **data-capable** USB-C cable

## One-time install

```bash
git clone <this-repo> ~/Projects/samsung-tethering   # or copy the folder
cd ~/Projects/samsung-tethering
./bin/setup
```

`bin/setup` checks prerequisites, installs TetherKit via Homebrew, scans
for your phone, and **installs the USB-event auto-start daemon** (asks for
your admin password once). You can re-run `./bin/setup --check` anytime just
to verify the device is detected (no installs happen in `--check` mode).

Next: **`./bin/tether start`** (needs your admin password — the driver must
create a virtual interface) — or just plug the phone and enable USB
tethering: the daemon brings the connection up automatically.

## Phone setup (once)

1. Plug the phone into the Mac.
2. Make sure the phone itself has internet:
   - **Cellular data ON**, **not** in Airplane Mode **or**
   - Phone on Wi-Fi and you want to share that Wi-Fi: enable the phone's
     **Wi-Fi sharing** option (Samsung: Settings → Connections → Mobile
     hotspot and tethering → Wi-Fi sharing). *Note:* when sharing Wi-Fi, some
     carriers / Android versions still route through the cellular interface —
     turn cellular data on too if tethering looks dead.
3. Enable **USB tethering**:
   Settings → Connections → Mobile hotspot and tethering → **USB tethering**
   (toggle ON). Accept any "Use USB for …" dialog on the phone.

> ⚠️ Toggling USB tethering off/on **re-enumerates the USB device**, which
> makes the driver exit (it treats the link as dead). That is normal — with
> the auto-start daemon the link comes back by itself; otherwise just run
> `./bin/tether start` again.

## Daily use

```bash
./bin/setup            # one-time: install the TetherKit driver (needs Homebrew)
./bin/tether start      # start driver + get IP from the phone (admin pw)
./bin/tether status     # driver, feth0, IP/gateway, link reachability
./bin/tether test       # DNS + ping 8.8.8.8 + HTTPS through the phone
./bin/tether stop       # tear everything down (admin pw)
./bin/tether route      # optional: make the phone the default route
./bin/tether autostart on|off   # toggle the USB-event auto-start (setup installs it)
./bin/cleanup           # full reset: driver, feth, service, logs + stale services
```

### Reset / cleanup

`./bin/cleanup` removes everything this repo may have set up (driver, `feth0`/
`feth1`, the persistent "USB Tethering" service, the auto-start daemon if
installed, logs and SystemConfiguration backups) **and** deletes stale network
services left behind by other devices (old phones, USB ethernet adapters).
System services (`Wi-Fi`, `Thunderbolt*`, `Bluetooth*`) and any service whose
device currently has an IP are never touched.

```bash
./bin/cleanup            # full reset (admin pw)
./bin/cleanup --dry-run  # preview only, changes nothing
./bin/cleanup --repo-only# only this repo's footprint, keep other devices' services
```

After a cleanup the auto-start daemon is removed too. Either reinstall it
(`./bin/setup` or `./bin/tether autostart on`) and just plug the phone, or
use the manual flow: plug the phone → enable **USB tethering** on it →
`./bin/tether start`.

`status` and `test` work without admin rights; `start`/`stop`/`route`/
`autostart` prompt for an admin password.

### What "works" looks like

```
[tether] Connected: address 10.133.173.224, gateway/DNS 10.133.173.8
...
 ./bin/tether test
  DNS    : resolved
  Ping   : 8.8.8.8 reachable
  HTTPS  : 200 (0.23s)
```

### Browsers and default route

`./bin/tether start` gives the phone link an address **and registers a persistent
network service** ("USB Tethering" on `feth0`) so the system — System Settings,
VPN clients, reachability checks — sees it as a real connection. Without that
service, apps report "no internet" even though raw routing works (this is what
made NordVPN fail until we added `scripts/service.sh`).

It does **not** change your default route — only traffic explicitly bound to
`feth0` uses it (e.g. `curl --interface feth0 https://api.ipify.org`). To route
*all* Mac internet through the phone (and away from the wired/other network):

```bash
./bin/tether route
# or manually:  sudo route -n change default $(ipconfig getoption feth0 router)
```

Reverse it with `sudo route -n change default <old-gateway>`.

### Auto-start when the phone connects (optional)

`bin/setup` installs this for you; toggle it anytime with:

```bash
./bin/tether autostart on|off
```

Instead of polling, it runs a tiny IOKit watcher (`samsung-tethering-watch`,
~1 MB, compiled with clang during install) that blocks in a kernel USB
notification — event-driven, **no polling, 0% CPU** — until an Android
phone (any major vendor: Samsung, Google/Pixel, Xiaomi, Huawei,
OnePlus/Oppo/realme/vivo, Sony, LG, Motorola, ZTE, HTC, Lenovo, Nokia,
ASUS) appears. It then starts the driver, gets a lease, and registers the
"USB Tethering" service (or refreshes it — a configd restart re-associates
the service with the recreated `feth0`). When you unplug or toggle tethering
off, it tears down and exits and the watcher goes back to waiting. A phone
already connected when the daemon starts is picked up immediately (no replug
needed), and if the link dies while the phone is still attached it retries
automatically. It takes ~10–20 s for the service to show as **Connected** in
System Settings (driver attach + DHCP + configd restart — normal). Logs:
`/var/log/samsung-tethering.log`.

Requires Xcode Command Line Tools (for clang) at install time — Homebrew
already depends on them.

### Uninstall

```bash
./bin/cleanup                 # removes driver, feth, service, daemon, logs, stale services
./bin/tether autostart off    # (cleanup does this too)
brew uninstall XiaoMiku01/tap/tetherkit-cli
brew untap XiaoMiku01/tap
```

## Firewalls & VPNs — read this

VPN apps with a **kill switch** (NordVPN, Mullvad, Proton, …) and strict
firewalls (Little Snitch etc.) insert an pf rule like `block drop all` plus
pass rules only for their own tunnel and known interfaces. `feth0` is not in
that allow-list, so **all tether traffic is silently dropped** even though
the link to the phone is perfectly healthy. Symptom: DHCP + gateway ping
work, but ping/curl/DNS through the phone time out and the driver's TX
counter stays at 0.

Check with:

```bash
sudo pfctl -s rules        # look for 'block drop all' / missing feth0 pass
sudo lsof /dev/pf          # which app owns the firewall
```

Fix: disable the VPN / kill switch (or allow-list the `feth0` interface),
then re-run `./bin/tether test`.

If a VPN daemon (e.g. Mullvad's `mullvad-daemon`, which keeps `/dev/pf` open
even when idle) holds the ruleset, its kill switch may pass only *root*
traffic on `feth0` (`pass on feth0 ... user = 0`). Effect: VPN tunnel traffic
over the phone works fine, but a non-root `curl --interface feth0` times out.
That is intentional leak protection — to have the raw phone path work for
unprivileged apps too, disable the kill switch or uninstall the idle daemon.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `tetherkit-cli --list` shows nothing | cable is charge-only; USB tethering off; "Use USB for …" dialog not confirmed |
| Driver starts but `feth0` never appears | phone re-toggled tethering mid-start — run `./bin/tether start` again |
| Tethering doesn't auto-start when enabled on the phone | event daemon not installed (`./bin/tether autostart on`) — check `/var/log/samsung-tethering.log`; fall back to `./bin/tether start` |
| `feth0` loses its IP / no internet after you unplug ethernet or join a Wi-Fi | Older versions dropped the *temporary* DHCP service on network changes. With the persistent "USB Tethering" service (`scripts/service.sh`) the lease survives — re-run `./bin/tether start` if it ever drops |
| DHCP lease but everything times out | **VPN/firewall kill switch** (see above); or phone has no uplink (cellular data off, airplane mode) |
| No DNS reply from phone | phone's DNS server not forwarding; check `ipconfig getoption feth0 router` and retest |
| Slow throughput | userspace driver caps at USB 2.0 HS (≈300–420 Mbps); expected |
| `feth0` MAC is `00:00:00:00:00:00` | driver normally fixes this; if not, add `--keep-feth-mac` while diagnosing |

Driver logs: `/tmp/tetherkit-cli.log` (manual) or `/var/log/samsung-tethering.log`
(auto-start).

## Layout

```
samsung-tethering/
├── README.md
├── bin/
│   ├── setup        # one-time installer (Homebrew + TetherKit + device scan + event daemon)
│   ├── tether       # daily driver: start|stop|status|test|route|autostart
│   └── cleanup      # full reset: driver, feth, service, logs + stale services
└── scripts/
    ├── daemon-wrapper.sh   # tether wrapper (driver + DHCP + service), run by the watcher
    ├── service.sh          # register/remove/refresh the persistent network service
    └── usb-watch.c         # IOKit watcher daemon source (compiled at install)
```

## License & credits

This project — the scripts in `bin/` and `scripts/` — is MIT-licensed (see
[LICENSE](LICENSE)). The scripts are original and do not contain TetherKit
code; they only orchestrate the `tetherkit-cli` binary they install.

The actual USB driver is [TetherKit](https://github.com/XiaoMiku01/TetherKit)
by XiaoMiku01 (also MIT-licensed), installed via Homebrew from the
`XiaoMiku01/tap` tap; the driver binary and any libraries it bundles are
governed by their own licenses.