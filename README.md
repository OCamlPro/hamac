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

```sh
# Validate / plan / resolve manifests
hamac validate manifests/*.sieste.yml
hamac plan     services.sieste.yml
hamac resolve  services.sieste.yml

# Bare-metal provisioning
hamac provision-dryrun --profile=dev-workstation.yaml
hamac provision-push   --profile=dev-workstation.yaml \
                       --mac=aa:bb:cc:dd:ee:ff \
                       --discovery=http://discovery:8877
hamac provision-clear  --mac=aa:bb:cc:dd:ee:ff --discovery=http://discovery:8877
```

Run `hamac --help` for the full command list.

## Bare-metal provisioning (PXE)

`hamac-discovery` runs alongside a PXE stack (`docker/hamac-pxe`, dnsmasq proxy
DHCP + TFTP + iPXE). A machine boots over PXE, fetches its cloud-init from the
discovery server (keyed by MAC), and the OS image is written to disk. See
[`doc/PROVISIONING_SPEC.md`](doc/PROVISIONING_SPEC.md) for the full contract
(image formats, `bmaptool` write path, first-boot resize).

## Documentation

- [`doc/HAMAC_ROADMAP.md`](doc/HAMAC_ROADMAP.md) — milestones.
- [`doc/PROVISIONING_SPEC.md`](doc/PROVISIONING_SPEC.md) — provisioning profile & disk-write spec.

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
