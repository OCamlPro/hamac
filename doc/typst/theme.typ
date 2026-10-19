// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 OCamlPro <contact@ocamlpro.com>
//
// Habillage commun des documents officiels de Hamac : spécifications,
// manuels, livrables. Couleurs et polices de la charte graphique
// (bizdev-docs/commercial/hamac/charte/_palette.typ) ; les logos sont les
// copies versionnées de doc/assets/logo/.
//
// Écrit à la main plutôt qu'importé d'un paquet Typst : la construction des
// PDF ne demande aucun accès réseau.
//
// Les chemins d'images sont absolus depuis la racine `doc/` : compiler avec
// `typst compile --root doc …` (voir doc/Makefile).

// --- Palette de la charte ---------------------------------------------------

#let bleu    = rgb("#192e50")   // hexagone et nom : l'encre des documents
#let orange  = rgb("#f28c28")   // accents
#let ombre   = rgb("#b3601a")   // orange lisible sur papier (texte, filets fins)
#let nuit    = rgb("#0d1b2a")   // fond sombre : couverture, blocs de commandes
#let blanc   = rgb("#f2f5f8")
#let vert    = rgb("#2f7d32")   // autorisé ; assombri pour le papier
#let rouge   = rgb("#b3261e")   // interdit ; assombri pour le papier
#let gris    = rgb("#5d6d7e")
#let filet   = rgb("#d5dce3")
#let lavis   = rgb("#f4f6f8")
#let papier  = white

#let sans = ("Liberation Sans", "DejaVu Sans")
#let mono = ("DejaVu Sans Mono", "Liberation Mono")

// --- Logo -------------------------------------------------------------------

#let logo(hauteur: 1cm, sombre: false) = image(
  if sombre { "/assets/logo/hamac-logo-horizontal-sombre.svg" }
  else { "/assets/logo/hamac-logo-horizontal-clair.svg" },
  height: hauteur)

#let symbole(hauteur: 0.5cm) = image("/assets/logo/hamac-symbole-clair.svg",
  height: hauteur)

// --- Éléments de texte ------------------------------------------------------

// Un terme du vocabulaire, à sa première apparition.
#let terme(body) = text(weight: "bold", fill: bleu, body)

// Mots-clés normatifs (RFC 2119) : en petites capitales grasses, pour qu'une
// obligation ne se lise pas comme une suggestion.
#let doit = text(weight: "bold", [DOIT])
#let doit-pas = text(weight: "bold", [NE DOIT PAS])
#let devrait = text(weight: "bold", [DEVRAIT])
#let peut = text(weight: "bold", [PEUT])

// Niveau de stabilité d'un champ ou d'une section.
#let _badge(label, couleur) = box(
  inset: (x: 4pt, y: 1.5pt), outset: (y: 1pt), radius: 2pt,
  fill: couleur.lighten(85%), stroke: 0.5pt + couleur,
  text(size: 7.5pt, weight: "bold", fill: couleur.darken(20%), label))
#let stable = _badge("stable", vert)
#let experimental = _badge("expérimental", ombre)
#let deprecie = _badge("déprécié", rouge)

// Code d'erreur ou d'avertissement du validateur.
#let code(c) = box(text(font: mono, size: 8.5pt, weight: "bold",
  fill: if c.starts-with("E") { rouge } else { ombre }, c))

// --- Encadrés ---------------------------------------------------------------

#let _encadre(titre, couleur, body) = block(
  width: 100%, inset: (x: 12pt, y: 10pt), radius: 2pt,
  fill: couleur.lighten(93%), stroke: (left: 2.5pt + couleur),
  breakable: true,
  [
    #text(size: 8pt, weight: "bold", fill: couleur.darken(10%),
          tracking: 0.6pt, upper(titre))
    #v(-4pt)
    #body
  ],
)

#let note(body) = _encadre("note", bleu, body)
#let attention(body) = _encadre("attention", ombre, body)
#let regle(body) = _encadre("règle", rouge, body)

// Un manifeste ou une sortie : il se lit, il ne se tape pas.
#let sortie(body) = block(
  width: 100%, inset: (x: 11pt, y: 9pt), radius: 2pt, fill: lavis,
  stroke: (left: 2pt + filet), breakable: true,
  text(size: 8.4pt, body),
)

// Un schéma en caractères : il se relit dans un diff.
#let schema(body) = align(center, block(
  inset: (x: 10pt, y: 12pt), radius: 2pt, fill: white, stroke: 0.4pt + filet,
  text(font: mono, size: 7.5pt, fill: bleu, hyphenate: false, body),
))

// Tableau sobre : filets horizontaux, en-tête sur fond lavé.
#let tableau(colonnes, ..cellules) = {
  set text(size: 8.8pt)
  set par(justify: false)
  table(
    columns: colonnes,
    inset: (x: 6pt, y: 5pt),
    align: left + top,
    stroke: (x, y) => (
      top: if y == 0 { 0.8pt + bleu } else if y == 1 { 0.6pt + bleu }
           else { 0.3pt + filet },
      bottom: 0pt,
    ),
    fill: (x, y) => if y == 0 { lavis },
    table.header(..cellules.pos().slice(0, colonnes.len()).map(c =>
      text(weight: "bold", size: 8.5pt, c))),
    ..cellules.pos().slice(colonnes.len()),
  )
}

// --- Mentions de financement ------------------------------------------------
//
// Contrat d'aide Hyper Open X (clauses particulières, art. 4) et règlement de
// l'AAP (§3.4.3) : trois mentions et quatre logos, cf. doc/assets/SOURCES.md.
// L'emblème européen ne doit être ni moins haut ni moins large que le plus
// grand des autres logos : tous sont posés à la même hauteur, et l'emblème est
// le plus large.

#let financement() = block(width: 100%, breakable: false, {
  set text(size: 8.5pt, fill: gris)
  set par(justify: false)
  line(length: 100%, stroke: 0.4pt + filet)
  v(4pt)
  text(weight: "bold", fill: bleu, size: 9pt, [Financement])
  v(2pt)
  [« Ce projet a été financé par le Gouvernement dans le cadre du plan France
  2030 opéré par Cap Digital et financé par l'Union européenne –
  NextGeneration EU »]
  linebreak()
  [« Ce projet a été financé par le gouvernement dans le cadre de France
  2030 »]
  linebreak()
  [« Financé par l'Union européenne - Next Generation EU dans le cadre du plan
  France Relance »]
  v(8pt)
  let h = 1.1cm
  grid(columns: 4, column-gutter: 14pt, align: horizon,
    image("/assets/france-2030.png", height: h),
    image("/assets/france-relance.png", height: h),
    image("/assets/finance-par-union-europeenne-nextgenerationeu.png", height: h),
    image("/assets/cap-digital.png", height: h),
  )
})

// --- Gabarit de document ----------------------------------------------------

#let document-officiel(
  titre: "",
  sous-titre: none,
  nature: "Spécification",   // Spécification | Manuel | Livrable | Note de conception
  version: "",
  date: "",
  statut: none,              // ex. "brouillon"
  reference: none,           // ex. "Hyper Open X — jalon J2"
  body,
) = {
  set document(title: "Hamac — " + titre, author: "OCamlPro")
  set text(font: sans, size: 10pt, fill: bleu, lang: "fr", hyphenate: true)
  set par(justify: true, leading: 0.62em, spacing: 0.95em)
  // Taille relative : un `code` dans un titre grandit avec le titre.
  show raw: set text(font: mono, size: 0.88em)
  show raw.where(block: false): it => box(
    fill: lavis, outset: (y: 2.5pt), inset: (x: 2pt), radius: 1.5pt, it)
  show raw.where(block: true): it => block(
    width: 100%, inset: (x: 11pt, y: 9pt), radius: 2pt, fill: lavis,
    stroke: (left: 2pt + filet), breakable: true, it)
  show link: set text(fill: ombre)
  set list(indent: 2pt, marker: text(fill: orange, [•]))
  set enum(indent: 2pt)
  set terms(separator: [ #h(0.35em) — #h(0.35em) ], hanging-indent: 1.1em)

  set heading(numbering: "1.1")
  // Un renvoi à une section s'écrit « §5.4 », pas « Chapitre 5.4 ».
  show ref: it => {
    let el = it.element
    if el != none and el.func() == heading and el.numbering != none {
      link(el.location(),
        [§#numbering(el.numbering, ..counter(heading).at(el.location()))])
    } else { it }
  }
  show heading.where(level: 1): it => {
    // Pas de saut avant la première section : ce qui la précède (un encadré
    // de statut, un chapeau) reste sur la même page qu'elle.
    if it.numbering == none or counter(heading).get().first() > 1 {
      pagebreak(weak: true)
    }
    block(above: 0pt, below: 16pt)[
      #text(size: 8.5pt, fill: ombre, weight: "bold", tracking: 1pt,
            if it.numbering != none { [SECTION #counter(heading).display()] })
      #v(-2pt)
      #text(size: 19pt, weight: "bold", it.body)
    ]
  }
  show heading.where(level: 2): it => block(above: 18pt, below: 8pt,
    text(size: 12.5pt, weight: "bold", it))
  show heading.where(level: 3): it => block(above: 13pt, below: 6pt,
    text(size: 10.5pt, weight: "bold", fill: ombre, it))
  show heading.where(level: 4): it => block(above: 11pt, below: 5pt,
    text(size: 10pt, weight: "bold", style: "italic", it.body))

  // Couverture.
  page(fill: nuit, margin: 2.2cm, header: none, footer: none)[
    #set text(fill: blanc)
    #show raw.where(block: false): it => text(font: mono, size: 0.92em,
      fill: orange, it.text)
    #logo(hauteur: 1.5cm, sombre: true)
    #v(1fr)
    #text(size: 9pt, fill: orange, weight: "bold", tracking: 1.6pt, upper(nature))
    #v(4pt)
    #block(below: 18pt, text(size: 30pt, weight: "bold", hyphenate: false, titre))
    #if sous-titre != none {
      block(width: 82%, below: 20pt,
        text(size: 12pt, fill: rgb("#a9b8c8"), hyphenate: false, sous-titre))
    }
    #line(length: 36%, stroke: 1.2pt + orange)
    #v(10pt)
    #text(size: 9.5pt, fill: rgb("#a9b8c8"))[
      Version #version #h(8pt)·#h(8pt) #date
      #if statut != none [ #h(8pt)·#h(8pt) #text(fill: orange, upper(statut)) ]
    ]
    #if reference != none {
      v(4pt)
      text(size: 9pt, fill: rgb("#8095aa"), reference)
    }
    #v(1.4cm)
    #text(size: 8.5pt, fill: rgb("#8095aa"))[
      OCamlPro SAS — `forge.ocamlpro.com/OSS/hamac` — AGPL-3.0
    ]
  ]

  set page(
    paper: "a4", margin: (x: 2.5cm, top: 2.5cm, bottom: 2.3cm), fill: papier,
    header: context {
      // Le titre du sommaire n'est pas une section : seuls les titres qui
      // figurent au sommaire donnent le titre courant.
      let chapitres = query(heading.where(level: 1, outlined: true).before(here()))
      set text(size: 8pt, fill: gris)
      grid(columns: (auto, 1fr),
        align(left + horizon, symbole(hauteur: 0.42cm)),
        align(right + horizon,
          if chapitres.len() > 0 [#chapitres.last().body #h(6pt)·#h(6pt) #titre]
          else [#titre]))
      v(-6pt)
      line(length: 100%, stroke: 0.4pt + filet)
    },
    footer: context {
      set text(size: 8pt, fill: gris)
      grid(columns: (1fr, auto, 1fr),
        align(left, [Hamac — #titre #version]),
        align(center, text(fill: bleu, counter(page).display())),
        align(right, date))
    },
  )
  counter(page).update(1)

  // Sommaire.
  {
    show outline.entry.where(level: 1): set text(weight: "bold")
    outline(title: text(size: 16pt, weight: "bold", [Sommaire]), depth: 2,
      indent: 1.2em)
  }
  pagebreak()

  body

  v(1fr)
  financement()
}
