# hamac

*Zero-touch infrastructure orchestration: turn declarative service manifests into resolved, deployed infrastructure — with security zones inferred from your data, not bolted on.*

> **Canonical repository:** https://forge.ocamlpro.com/OSS/hamac — the GitHub repository is a read-only mirror. Please file issues and merge requests on Forgejo.

**hamac** is an infrastructure orchestrator for **SIESTE** manifests. It reads
declarative `.sieste.yml` manifests describing services and infrastructure,
resolves their dependencies to concrete providers, and provisions/deploys them —
including **bare-metal provisioning over PXE**.

Developed by [OCamlPro](https://www.ocamlpro.com) and released under the
**GNU Affero General Public License v3.0** (see [`LICENSE`](LICENSE)).

## Components

| Package | Path | Role |
|---|---|---|
| `hamac` | `pkgs/hamac` | CLI: `validate` / `plan` / `resolve` / `simulate` / `deploy`, and `provision-*` (render + push cloud-init/iPXE to the discovery server). |
| `hamac-provisioning` | `pkgs/hamac-provisioning` | Library: manifest parsing, provisioning-profile rendering (cloud-init + iPXE). |
| `hamac-discovery` | `pkgs/hamac-discovery` | Discovery server: stores a provisioning record per MAC and serves the aggregated cloud-init to PXE-booting machines. |

## Build

Requires OCaml, opam and dune. **All dependencies are public opam packages.**

```sh
opam install --deps-only .
dune build
```

Build files (`dune`, `dune-project`, `opam/*.opam`) are generated from
`recipe.yaml` by [marmiton](https://ocaml.org). Edit the recipe, then run
`marmiton build` to regenerate them (maintainer flow only — the generated files
are committed, so building does not require marmiton).

## Usage

The commands below run as-is from the root of this repository, against the
example manifests it ships.

```sh
# Validate / plan / resolve manifests
hamac validate examples/enterprise-stack/*.sieste.yml
hamac plan     examples/enterprise-stack/*.sieste.yml
hamac resolve  examples/enterprise-stack/*.sieste.yml

# Credentials come from the system CSPRNG. --seed makes them reproducible for
# tests and demos, and therefore predictable: never use it for a real deployment.
hamac resolve --seed 42 examples/enterprise-stack/*.sieste.yml

# Bare-metal provisioning
hamac provision-dryrun --profile=provisioning-profiles/dev-workstation-demo.yaml
hamac provision-push   --profile=provisioning-profiles/dev-workstation.yaml \
                       --mac=aa:bb:cc:dd:ee:ff \
                       --discovery=http://discovery:8877
hamac provision-clear  --mac=aa:bb:cc:dd:ee:ff --discovery=http://discovery:8877
```

Run `hamac --help` for the full command list.

### Files hamac looks for

| Directory | Contents | Looked up |
|---|---|---|
| `providers/` | Provider manifests (`postgresql`, `redis`) — a provider is a `kind: service` manifest, not a compiled plugin. | `./providers`, then `~/.hamac/providers` |
| `templates/bundles/<name>/` | Provisioning bundles: `bundle.yaml` + cloud-init Jinja2 templates. | `./templates/bundles`, `/usr/share/hamac/bundles`, or `--bundles-dir` |
| `provisioning-profiles/` | `kind: provisioning_profile` manifests. `dev-workstation.yaml` takes its parameters from the machine record; `dev-workstation-demo.yaml` carries them inline so a dry run needs nothing else. | passed with `--profile` |
| `examples/enterprise-stack/` | Three services across three security zones, consuming a database and a cache. | passed on the command line |

## Bare-metal provisioning (PXE)

`hamac-discovery` runs alongside a PXE stack (`docker/hamac-pxe`, dnsmasq proxy
DHCP + TFTP + iPXE). A machine boots over PXE, fetches its cloud-init from the
discovery server (keyed by MAC), and the OS image is written to disk. See
[`doc/PROVISIONING_SPEC.md`](doc/PROVISIONING_SPEC.md) for the full contract
(image formats, `bmaptool` write path, first-boot resize).

## Documentation

- [`doc/HAMAC_ROADMAP.md`](doc/HAMAC_ROADMAP.md) — milestones.
- [`doc/PROVISIONING_SPEC.md`](doc/PROVISIONING_SPEC.md) — provisioning profile & disk-write spec.

## Funding

<p>
  <img src="doc/assets/france-2030.png" alt="France 2030" height="64">
  &nbsp;&nbsp;
  <img src="doc/assets/france-relance.png" alt="France Relance" height="64">
  &nbsp;&nbsp;
  <img src="doc/assets/finance-par-union-europeenne-nextgenerationeu.png"
       alt="Financé par l'Union européenne — NextGenerationEU" height="64">
</p>

> « Ce projet a été financé par le gouvernement dans le cadre de France 2030 »
>
> « Financé par l'Union européenne - Next Generation EU dans le cadre du plan
> France Relance »

*This project was funded by the French Government under France 2030, and by the
European Union – NextGenerationEU under the France Relance plan.*

## Licensing

hamac is **dual-licensed** by OCamlPro:

- **Open source** — [GNU AGPL-3.0](LICENSE). Free to use, modify and
  redistribute under the AGPL's terms, **including its network-copyleft**: if
  you run a modified version as a network service, you must offer its users the
  complete corresponding source.
- **Commercial** — for organizations that cannot or do not wish to comply with
  the AGPL (e.g. embedding hamac in a proprietary product or a closed-source
  SaaS), a commercial license is available from OCamlPro.

See [`LICENSING.md`](LICENSING.md) for details. Contributions require a signed
CLA so they can be offered under both licenses — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

Commercial licensing & questions: **contact@ocamlpro.com**.
