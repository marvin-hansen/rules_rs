# Vendoring + annotations from Cargo metadata

Working notes for the `feat/vendor` branch. Two separable features; the first is
useful on its own and is the easier one to land.

## 1. Annotations sourced from `[workspace.metadata.rules_rs]`

### Problem

Annotations are declared as `crate.annotation(...)` / `crate.annotation_select(...)`
tags in MODULE.bazel. In a real consumer that section dominates the file --
ServiceRadar's crate configuration is 1835 of 2213 MODULE.bazel lines (83%) -- and it
sits far away from the `Cargo.toml` that declares the dependency it modifies. Bumping
a version and adjusting its annotation touches two files that must agree.

### Proposal

Read annotations from Cargo's own metadata table, in the root `Cargo.toml`:

```toml
[workspace.metadata.rules_rs.annotations."openssl-src"]
gen_build_script = "off"
patches = ["@//third_party/rust_patches:openssl_src.patch"]

[[workspace.metadata.rules_rs.annotations."openssl-src".select]]
triples = ["aarch64-unknown-linux-gnu"]
rustc_flags = ["-Ctarget-feature=+neon"]
```

Verified properties of this location:

* Cargo tolerates the unknown table -- no warning -- and preserves it byte for byte
  across `cargo generate-lockfile`.
* `cargo metadata --format-version 1` returns it verbatim under the top-level
  `"metadata"` key, so the generator gets it from a call it already makes.
* `[[...]]` array-of-tables encodes repeated `annotation_select` tags exactly.
  `annotation_select` keys on `triples`, which are plain strings rather than Bazel
  config labels, so nothing about the select model resists a TOML encoding.

MODULE.bazel tags keep working unchanged; the metadata table is a second source.

### Insertion point

`build_annotation_map(mod, cfg_name, platform_triples)` in
`rs/private/annotations.bzl` is the single place both tag types are consumed. It
reads `mod.tags.annotation` and `mod.tags.annotation_select`, then normalises through
`_annotation_values` / `_merge_annotation_select` / `_fill_select_defaults`.

`_annotation_values` is `structs.to_dict(...)` minus the identity fields, so it does
not care whether a record came from a tag class or from parsed TOML -- provided the
record carries **exactly the tag's field set with tag-shaped defaults**. Note the
existing comment in `annotation_for`: tag string attributes use `""` where the
internal representation uses `None`. A record builder has to reproduce that, or
wildcard merging silently changes behaviour.

Change shape:

1. `build_annotation_map(annotations, annotation_selects, cfg_name, platform_triples)`
   -- take records rather than reaching into `mod.tags` itself.
2. New `annotation_records_from_metadata(metadata)` building those records from the
   `workspace.metadata.rules_rs.annotations` dict.
3. One caller update at `rs/extensions.bzl:688`, passing
   `list(mod.tags.annotation) + metadata_records`.

Everything downstream -- select merging, wildcard versions, `_fill_select_defaults`,
the windows-gnullvm implicit annotations -- is untouched.

### The one hard part: label anchoring

`_merge_annotation_select` carries this comment:

> Stringify labels only after tag resolution has anchored them to the module that
> declared the annotation.

Bazel anchors `attr.label_list` values in a tag to the module that declared the tag.
A string out of TOML has no such anchor, and `patches`, `additive_build_file`, `data`,
`deps` and `build_script_tools` are all label-valued. Resolving them relative to the
`.bzl` file would anchor them to `rules_rs`, which is wrong -- they belong to the root
module, whose `Cargo.toml` this is.

Options, in preference order:

1. Require apparent-repo-qualified labels in metadata (`@//third_party/...`) and
   resolve against the root module's repo mapping.
2. Resolve relative to the directory of the `Cargo.toml` the metadata came from,
   which matches the intuition that these are paths in the consuming workspace.

This needs a spike before the rest is worth writing; it is the only part that can
make the feature unimplementable rather than merely fiddly.

## 2. Vendoring

Deliberately not designed yet. Notes so it is not re-derived:

* `crate_repository` fetches with `rctx.download_and_extract(url, sha256)` and calls
  `patch(rctx)` **after** extraction, so patches and annotations are independent of
  where the bytes come from.
* crates.io's `config.json` has `"dl": "https://static.crates.io/crates"` with no
  placeholders, so rules_rs appends the Cargo-spec `/{crate}/{version}/download`.
  Every crate's URL basename is therefore literally `download`.
* Measured, with an isolated `--repository_cache` per case, whether Bazel's
  `--distdir` can satisfy such a fetch:

  | URLs passed to `download_and_extract`        | distdir |
  | -------------------------------------------- | ------- |
  | `serde-1.0.219.crate` only                    | HIT     |
  | `1.0.219/download` only                       | miss    |
  | `download` first, `.crate` second             | miss    |

  Bazel matches on the **first** URL's basename only; appending an alias does not
  help. `https://static.crates.io/crates/serde/serde-1.0.219.crate` is served (200),
  and is the same name Cargo's own registry cache uses.

* So a `.crate` mirror is viable, but only if the first URL rules_rs emits is
  `{crate}-{version}.crate`. Scale, for one consumer: 746 archives versus 38,949
  files across 745 directories for an exploded `cargo vendor` tree.
* Whatever populates the mirror should be a runnable Bazel target, not a shell
  script -- cargo fetches from the network and writes the source tree, so it is a
  workflow tool in the gazelle category, never a build action.
