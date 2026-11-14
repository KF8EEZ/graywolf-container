# Graywolf container

This is a container for running the [Graywolf APRS software](https://github.com/chrissnell/graywolf).

It builds for both `amd64` and `arm64` (Raspberry Pi 5) and can pass a
[Digirig](https://digirig.net) through to the container, both its sound card
and its serial port.

**Documentation: <https://KF8EEZ.github.io/graywolf-container/>**

## Interfaces

- APRS-IS connection with no RF (standalone).
- Radio via a Digirig over USB (audio and serial PTT).

## Quick start

```bash
podman compose up -d --build                                          # no radio
podman compose -f compose.yaml -f compose.digirig.yaml up -d --build  # Digirig
```

The web UI is at <http://localhost:8080>. See the
[documentation](https://KF8EEZ.github.io/graywolf-container/) for Digirig
setup, host group requirements and troubleshooting.

## Publishing the documentation

The docs in `docs/` are a [Quarto](https://quarto.org) website, published to
the `gh-pages` branch and served by GitHub Pages. Publishing is manual: after
changing the docs and committing them to `main`, run

```bash
cd docs
quarto publish gh-pages --no-prompt --no-browser
```

This renders the site and pushes the HTML to `gh-pages`. The site updates a few
minutes later. To preview changes locally first, run `quarto preview` in `docs/`.
