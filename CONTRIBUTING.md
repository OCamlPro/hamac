# Contributing to hamac

Contributions are welcome — a few things to know first.

## Licensing of contributions (CLA required)

hamac is **dual-licensed** (AGPL-3.0 + commercial — see [`LICENSING.md`](LICENSING.md)).
For OCamlPro to offer the commercial license, it must be able to distribute
**every** part of hamac — including your contribution — under **both** licenses.

Before a contribution can be merged, you must therefore sign OCamlPro's **Individual Contributor License Agreement** ([`CLA.md`](CLA.md)), which grants OCamlPro the
right to license your contribution under the AGPL and under a commercial
license. This is a one-time step per contributor; contributions without a signed
CLA cannot be merged.

Contributing on behalf of a company? A **Corporate CLA** may be required — contact **contact@ocamlpro.com**.

## Where to contribute

The **canonical repository is on Forgejo** — issues and merge requests go there.
The GitHub repository is a **read-only mirror**: please do not open pull requests
on it (they cannot be merged from the mirror).

## Development

    opam install --deps-only .
    dune build
    dune runtest

Build files (`dune`, `dune-project`, `opam/*.opam`) are generated from
`recipe.yaml` by marmiton — edit the recipe, then run `marmiton build`.
