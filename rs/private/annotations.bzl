load("@bazel_skylib//lib:structs.bzl", "structs")

def _crate_annotation(
        additive_build_file = None,
        additive_build_file_content = "",
        gen_build_script = "auto",
        build_script_data = [],
        build_script_data_select = {},
        build_script_env = {},
        build_script_env_select = {},
        build_script_env_files = [],
        allow_build_script_to_detect_nonhermetic_paths = False,
        build_script_tools = [],
        build_script_tools_select = {},
        build_script_toolchains = [],
        build_script_tags = [],
        data = [],
        deps = [],
        link_deps = [],
        tags = [],
        crate_features = [],
        crate_features_select = {},
        gen_binaries = [],
        extra_aliased_targets = {},
        rustc_flags = [],
        rustc_flags_select = {},
        patch_args = [],
        patch_tool = None,
        patches = [],
        strip_prefix = None,
        workspace_cargo_toml = "Cargo.toml"):
    return struct(
        additive_build_file = additive_build_file,
        additive_build_file_content = additive_build_file_content,
        gen_build_script = gen_build_script,
        build_script_data = build_script_data,
        build_script_data_select = build_script_data_select,
        build_script_env = build_script_env,
        build_script_env_select = build_script_env_select,
        build_script_env_files = build_script_env_files,
        allow_build_script_to_detect_nonhermetic_paths = allow_build_script_to_detect_nonhermetic_paths,
        build_script_tools = build_script_tools,
        build_script_tools_select = build_script_tools_select,
        build_script_toolchains = build_script_toolchains,
        build_script_tags = build_script_tags,
        data = data,
        deps = deps,
        link_deps = link_deps,
        tags = tags,
        crate_features = crate_features,
        crate_features_select = crate_features_select,
        gen_binaries = gen_binaries,
        extra_aliased_targets = extra_aliased_targets,
        rustc_flags = rustc_flags,
        rustc_flags_select = rustc_flags_select,
        patch_args = patch_args,
        patch_tool = patch_tool,
        patches = patches,
        strip_prefix = strip_prefix,
        workspace_cargo_toml = workspace_cargo_toml,
    )

_DEFAULT_CRATE_ANNOTATION = _crate_annotation()

_WINDOWS_GNULLVM_ADDITIVE_BUILD_FILE_CONTENT = """
load("@rules_cc//cc:defs.bzl", "cc_import")

cc_import(
    name = "windows_import_lib",
    static_library = glob(["lib/*.a"])[0],
    visibility = ["//visibility:public"],
)
"""

def _windows_gnullvm_implicit_annotation(crate_name, version, hub_name):
    alias_name = crate_name + "_import_lib"
    return _crate_annotation(
        additive_build_file_content = _WINDOWS_GNULLVM_ADDITIVE_BUILD_FILE_CONTENT,
        gen_build_script = "off",
        deps = ["@%s//:%s-%s" % (hub_name, alias_name, version)],
        extra_aliased_targets = {
            alias_name: "windows_import_lib",
        },
    )

_WINDOWS_GNULLVM_CRATES = [
    # These crates publish the needed import library in their package archive.
    # Apply the annotation by default so users do not need to add it.
    "windows_aarch64_gnullvm",
    "windows_x86_64_gnullvm",
]

def annotation_for(annotations_by_crate, crate_name, version, hub_name):
    """Return the annotation matching crate/version, falling back to '*' or default."""
    version_map = annotations_by_crate.get(crate_name, {})
    annotation = version_map.get(version) or version_map.get("*")
    if annotation:
        if crate_name in _WINDOWS_GNULLVM_CRATES:
            implicit = _windows_gnullvm_implicit_annotation(crate_name, version, hub_name)
            values = structs.to_dict(implicit)
            defaults = structs.to_dict(_DEFAULT_CRATE_ANNOTATION)
            for field, value in structs.to_dict(annotation).items():
                # Tag-class string attributes use "" where the internal
                # annotation representation uses None.
                if value == defaults.get(field) or (value == "" and defaults.get(field) == None):
                    continue
                if field == "deps":
                    values[field] += value
                elif field == "extra_aliased_targets":
                    values[field].update(value)
                elif field == "additive_build_file_content":
                    values[field] += value
                else:
                    values[field] = value
            return _crate_annotation(**values)
        return annotation

    if crate_name in _WINDOWS_GNULLVM_CRATES:
        return _windows_gnullvm_implicit_annotation(crate_name, version, hub_name)
    return _DEFAULT_CRATE_ANNOTATION

_SELECTABLE_ANNOTATION_FIELDS = {
    "build_script_data": "build_script_data_select",
    "build_script_env": "build_script_env_select",
    "build_script_tools": "build_script_tools_select",
    "crate_features": "crate_features_select",
    "rustc_flags": "rustc_flags_select",
}

_LIST_SELECT_FIELDS = [
    select_field
    for field, select_field in _SELECTABLE_ANNOTATION_FIELDS.items()
    if field != "build_script_env"
]

_SELECT_MAP_FIELDS = _SELECTABLE_ANNOTATION_FIELDS.values()

def _annotation_values(annotation):
    values = structs.to_dict(annotation)
    for field in ["crate", "repositories", "triples", "version"]:
        values.pop(field, None)
    return values

def _merge_annotation_select(selects, annotation, crate, version, cfg_name):
    selected_values = _annotation_values(annotation)
    for field, select_field in _SELECTABLE_ANNOTATION_FIELDS.items():
        value = selected_values.get(field)
        if not value:
            continue

        # Stringify labels only after tag resolution has anchored them to the
        # module that declared the annotation. Keep environment values as
        # dictionaries so wildcard and exact selections can compose by key.
        selected_value = dict(value) if field == "build_script_env" else [str(item) for item in value]
        platform_values = dict(selects.get(select_field, {}))
        for triple in annotation.triples:
            if triple in platform_values:
                fail("Duplicate crate.annotation_select for %s version %s triple %s field %s in repo %s" % (crate, version, triple, field, cfg_name))
            platform_values[triple] = selected_value
        selects[select_field] = platform_values

def _fill_select_defaults(values, platform_triples):
    # Keep explicitly selected values conditional, including empty branches.
    for field in _LIST_SELECT_FIELDS:
        platform_values = values.get(field)
        if not platform_values:
            continue

        platform_values = dict(platform_values)
        for triple in platform_triples:
            platform_values.setdefault(triple, [])
        values[field] = platform_values

def _merge_select_maps(base, override):
    for field in _SELECT_MAP_FIELDS:
        if field not in override:
            continue
        selected = dict(base.get(field, {}))
        for triple, value in override[field].items():
            if triple not in selected:
                selected[triple] = value
            elif field == "build_script_env_select":
                merged = dict(selected[triple])
                merged.update(value)
                selected[triple] = merged
            else:
                selected[triple] = selected[triple] + value
        base[field] = selected

def _normalize_select_maps(values):
    for field in _LIST_SELECT_FIELDS:
        values[field] = {
            triple: [str(item) for item in items]
            for triple, items in values.get(field, {}).items()
        }
    values["build_script_env_select"] = {
        triple: json.decode(env) if type(env) == "string" else dict(env)
        for triple, env in values.get("build_script_env_select", {}).items()
    }

def _encode_env_select(values):
    values["build_script_env_select"] = {
        triple: json.encode(env)
        for triple, env in values.get("build_script_env_select", {}).items()
    }

def _annotation_entry():
    return {
        "annotation": None,
        "selects": {},
    }

def build_annotation_map(annotation_tags, annotation_select_tags, cfg_name, platform_triples):
    """Build mapping {crate: {version|\"*\": annotation}} for a cfg name.

    Args:
        annotation_tags: annotation records, from crate.annotation tags and/or from
            Cargo.toml metadata. The two are shaped identically on purpose.
        annotation_select_tags: annotation_select records, same.
        cfg_name (string): Hub name being resolved.
        platform_triples (list): Triples the hub resolves for.
    """
    annotations = {}
    for annotation in annotation_tags:
        if annotation.repositories and cfg_name not in annotation.repositories:
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        entry = crate_map.setdefault(version_key, _annotation_entry())
        if entry["annotation"] != None:
            fail("Duplicate crate.annotation for %s version %s in repo %s" % (annotation.crate, version_key, cfg_name))
        entry["annotation"] = _annotation_values(annotation)

    for annotation in annotation_select_tags:
        if annotation.repositories and cfg_name not in annotation.repositories:
            continue

        version_key = annotation.version or "*"
        crate_map = annotations.setdefault(annotation.crate, {})
        entry = crate_map.setdefault(version_key, _annotation_entry())
        _merge_annotation_select(entry["selects"], annotation, annotation.crate, version_key, cfg_name)

    for crate_map in annotations.values():
        wildcard_entry = crate_map.get("*")
        wildcard_annotation = wildcard_entry["annotation"] if wildcard_entry else None
        wildcard_selects = wildcard_entry["selects"] if wildcard_entry else {}
        for version, entry in crate_map.items():
            values = dict(entry["annotation"] or wildcard_annotation or structs.to_dict(_DEFAULT_CRATE_ANNOTATION))
            _normalize_select_maps(values)
            selects = {}
            _merge_select_maps(selects, wildcard_selects)
            if version != "*":
                _merge_select_maps(selects, entry["selects"])
            _merge_select_maps(values, selects)
            _fill_select_defaults(values, platform_triples)
            _encode_env_select(values)
            crate_map[version] = _crate_annotation(**values)
    return annotations

def well_known_annotation_snippet_paths(mctx):
    """Returns {crate: snippet_path} for crates with include.MODULE.bazel snippets."""
    return {
        crate_dir.basename: crate_dir.get_child("include.MODULE.bazel")
        for crate_dir in mctx.path(Label("//:3rd_party")).readdir()
    }

# --- Annotations declared in Cargo.toml -------------------------------------------
#
# Annotations are conventionally declared as crate.annotation tags in MODULE.bazel.
# That puts them in a different file from the [workspace.dependencies] entry they
# modify, and in a large consumer it dominates the module file entirely -- 83% of one
# real MODULE.bazel. Cargo reserves `[workspace.metadata]` for exactly this: it warns
# about nothing, preserves the table verbatim, and `cargo metadata` returns it under
# the top-level "metadata" key.
#
#     [workspace.metadata.rules_rs.annotations."openssl-src"]
#     gen_build_script = "off"
#     patches = ["//third_party/rust_patches/openssl.patch"]
#
#     [[workspace.metadata.rules_rs.annotations."openssl-src".select]]
#     triples = ["aarch64-unknown-linux-gnu"]
#     rustc_flags = ["-Ctarget-feature=+neon"]
#
# These records are shaped exactly like the tag classes, so build_annotation_map and
# everything downstream cannot tell the two sources apart.

# Tag-class defaults, reproduced exactly. Note that string attributes default to ""
# where the internal annotation representation uses None; annotation_for compares
# against these to decide whether a field was set, so a mismatch here silently
# changes wildcard merging rather than failing.
_TAG_FIELD_DEFAULTS = {
    "additive_build_file": None,
    "additive_build_file_content": "",
    "allow_build_script_to_detect_nonhermetic_paths": False,
    "build_script_data": [],
    "build_script_env": {},
    "build_script_env_files": [],
    "build_script_tags": [],
    "build_script_toolchains": [],
    "build_script_tools": [],
    "crate_features": [],
    "data": [],
    "deps": [],
    "extra_aliased_targets": {},
    "gen_binaries": [],
    "gen_build_script": "auto",
    "link_deps": [],
    "patch_args": [],
    "patch_tool": "",
    "patches": [],
    "rustc_flags": [],
    "strip_prefix": "",
    "tags": [],
    "workspace_cargo_toml": "Cargo.toml",
}

# Fields Bazel would have resolved as labels had they come from a tag class.
_LABEL_FIELDS = [
    "additive_build_file",
    "build_script_data",
    "build_script_env_files",
    "build_script_toolchains",
    "build_script_tools",
    "data",
    "deps",
    "patches",
]

_SINGLE_LABEL_FIELDS = ["additive_build_file"]

def _metadata_label(value):
    """Anchor a label string from Cargo.toml to the root module.

    A tag's label attributes are anchored by Bazel to the module that declared the
    tag. A string out of TOML has no such anchor, and resolving it here would anchor
    it to rules_rs instead -- measured, not assumed: a bare `//pkg:x` resolves to the
    extension's own module, and `@//pkg:x` fails outright with "no repository visible
    as '@' in the extension". `@@//` is the canonical main repository and resolves
    correctly, so a leading `//` is rewritten to it and authors keep writing ordinary
    labels.

    Consequence: metadata annotations are a root-module feature, because `@@//` is the
    main repository regardless of which module's manifest they came from.
    """
    if value.startswith("//"):
        return Label("@@" + value)
    return Label(value)

def _annotation_record(crate, values, triples = None):
    fields = dict(_TAG_FIELD_DEFAULTS)

    for key, value in values.items():
        if key == "select":
            continue
        if key not in fields:
            fail("Unknown rules_rs annotation field %r for crate %s in Cargo.toml metadata. Known fields: %s" % (
                key,
                crate,
                ", ".join(sorted(fields)),
            ))
        fields[key] = value

    for field in _LABEL_FIELDS:
        value = fields[field]
        if not value:
            continue
        if field in _SINGLE_LABEL_FIELDS:
            fields[field] = _metadata_label(value)
        else:
            fields[field] = [_metadata_label(item) for item in value]

    # `repositories` is deliberately empty: an annotation in a workspace's Cargo.toml
    # belongs to that workspace's from_cargo repository by construction, so the field
    # that exists to re-attach an annotation to its manifest is unnecessary here.
    fields["crate"] = crate
    fields["version"] = values.get("version", "")
    fields["repositories"] = []
    if triples != None:
        fields["triples"] = triples
    return struct(**fields)

def annotation_records_from_metadata(cargo_toml_json):
    """Build annotation/annotation_select records from a parsed Cargo.toml.

    Args:
        cargo_toml_json (dict): Parsed Cargo.toml of the workspace being resolved.

    Returns:
        A tuple (annotations, selects) of tag-shaped records.
    """
    metadata = {}
    for root in ["workspace", "package"]:
        section = cargo_toml_json.get(root, {}).get("metadata", {}).get("rules_rs", {})
        if section:
            metadata = section
            break

    annotations = []
    selects = []
    for crate, values in metadata.get("annotations", {}).items():
        if type(values) != "dict":
            fail("rules_rs annotation for crate %s must be a table, got %s" % (crate, type(values)))

        annotations.append(_annotation_record(crate, values))

        for select in values.get("select", []):
            triples = select.get("triples")
            if not triples:
                fail("rules_rs annotation select for crate %s must set `triples`" % crate)
            selected = {k: v for k, v in select.items() if k != "triples"}
            selects.append(_annotation_record(crate, selected, triples = triples))

    return annotations, selects
