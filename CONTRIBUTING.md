# Contributing

Issues and pull requests are welcome: bug reports, fixes, and hardware reports (the Pi model, the TV model, and
whether `tvlink on`, `off` and `status` work over its CEC). Before proposing a feature, check the goals and
non-goals in [docs/design.md](docs/design.md).

Before a pull request, run (with shellcheck installed):

```bash
shellcheck tvlink install.sh tests/*.sh
python3 tvlink-power test
python3 tvlink-agent test
```

A change to install.sh, the units, CEC, Wi-Fi or the kiosk also needs `tests/vm.sh`
([docs/testing.md](docs/testing.md)). It runs on an Apple silicon Mac only: if you can't run it, say so in the pull
request and the maintainer will.

Style: bash and Python 3, no new dependencies; lines up to 120 columns; short comments; tests are the assert-based
`test` command in tvlink-power and tvlink-agent.

Contributions are under the repo's licence (Apache-2.0, section 5); there is no CLA. Redact page keys, IP addresses
and Wi-Fi names in anything you post.
