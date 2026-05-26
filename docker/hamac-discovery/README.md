# hamac-discovery Docker image

Image runtime pour le serveur de découverte de hamac (REST API pour
l'enregistrement des nodes et le service des profils de provisioning).

Tag canonique : `registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:0.1.0` + `latest`.

## Build

```sh
./build.sh                                  # tag par défaut
./build.sh registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:dev   # tag custom
```

Le `build.sh` :
1. Compile le binaire OCaml en release localement (`dune build --profile=release`)
   — nécessite l'environnement opam du repo SIESTE déjà configuré
2. Copie le binaire dans le contexte Docker
3. Lance `docker build` avec deux tags (`:0.1.0` + `:latest`)
4. Nettoie l'artefact temporaire en sortie (trap)

Pas de build OCaml dans Docker : ça nécessiterait l'auth GitLab pour les
pins `ocamlpro-cli` / `ocamlpro-codec`, ce qui complique inutilement le
Dockerfile. Le binaire OCaml est self-contained (deps = glibc + libm
seulement), donc une image runtime `debian:bookworm-slim` suffit.

## Run

```sh
docker run --rm -p 8877:8877 \
  -v /var/lib/hamac-discovery:/var/lib/hamac-discovery \
  registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:0.1.0
```

Variables d'environnement :
- `PORT` : port HTTP (défaut `8877`)
- `HAMAC_DISCOVERY_STATE` : chemin du state dir (défaut
  `/var/lib/hamac-discovery`, volume déclaré dans le Dockerfile)

Healthcheck : `curl http://localhost:8877/health` doit renvoyer
`{"status":"ok",...}`. Le `HEALTHCHECK` du Dockerfile fait ça toutes les
30 secondes.

## Sécurité

- Tourne en user non-root `hamac` (UID dynamique, image-built)
- Pas de port autre que 8877
- Image rebuild régulièrement recommandée (CVE Debian patchées via
  `apt-get upgrade` au prochain build)

## Push

```sh
docker login registry.ocamlpro.com    # creds via ansible vault chez OCP-SI
docker push registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:0.1.0
docker push registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:latest
```

## Voir aussi

- [`doc/PROVISIONING_SPEC.md`](../../doc/PROVISIONING_SPEC.md) : spec REST
- [`doc/OCPSI_DEPLOY_PLAN.md`](../../doc/OCPSI_DEPLOY_PLAN.md) : déploiement
