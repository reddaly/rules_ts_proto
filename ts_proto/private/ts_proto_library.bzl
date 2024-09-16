"""Define a ts_project library from a proto_library."""

load(
    "@rules_proto_grpc//:defs.bzl",
    "ProtoPluginInfo",
    "proto_compile",
    "proto_compile_attrs",
    "proto_compile_toolchains",
)
load("@aspect_rules_js//js:libs.bzl", "js_library_lib")

#load("@aspect_rules_js//js:defs.bzl", "js_library")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@aspect_bazel_lib//lib:base64.bzl", "base64")
load("@aspect_rules_ts//ts:defs.bzl", "ts_project")
load(":filtered_files.bzl", "filtered_files")
load(":utils.bzl", "relative_path")

# TODO - reddaly: JS_IMPORT_BAZEL_TARGET_MAP used to be configured when ts_proto_library
# was installed. We need to find another way to set this value.
JS_IMPORT_BAZEL_TARGET_MAP = {}

TsProtoInfo = provider(
    "Describes a generated proto library for TypeScript.",
    fields = {
        "proto_info": "ProtoInfo for the library.",
        "ts_proto_library_label": "Label of the ts_proto_library that produced the generated code.",
        #"js_info": "JsInfo for the library",
        "primary_js_file": "JavaScript file that should be imported when depending on this library to import messages, enums, etc.",
        "grpc_web_js_file": "JavaScript file that should be imported when depending on this library to import messages, enums, etc.",
        #"ts_proto_info_deps": "depset of TsProtoInfos needed by this library",
    },
)

GeneratedCodeInfo = provider(
    "Describes the generated TypeScript files that need to be compiled by tsc.",
    fields = {
        "ts_files": "ProtoInfo for the library.",
        "js_files": "Label of the ts_proto_library that produced the generated code.",
    },
)

def _ts_proto_library_protoc_plugin_compile_impl(ctx):
    """Implementation function for google_js_plugin_compile.

    Args:
        ctx: The Bazel rule execution context object.

    Returns:
        Providers:
            - ProtoCompileInfo
            - DefaultInfo
    """
    # Generate a mapping from proto import path to JS import path.
    #
    # To do this, we need to get the primary_js_file for each proto
    # file in deps and figure out how it would be imported from
    # a .js file within the directory of the BUILD file where the
    # rule appears.

    generated_code_dir = paths.join(ctx.bin_dir.path, ctx.label.package)

    map_entries = [_import_map_entry(generated_code_dir, dep) for dep in ctx.attr.deps]
    map_entries = [x for x in map_entries if x != None]
    map_entries.append(_this_rule_import_map_entry(ctx))

    config_json = json.encode(struct(
        action_description = "Generating JS/TS code as part of {}".format(ctx.label),
        mapping_entries = map_entries,
    ))

    options = {
        Label("//ts_proto/codegen:delegating_plugin"): [
            "config=" + base64.encode(config_json),
        ],
    }

    # Execute with extracted attrs
    usual_providers = proto_compile(
        ctx,
        options = options,
        extra_protoc_args = [],
        extra_protoc_files = [],
    )

    # Go through the declared outputs to extract a GeneratedCodeInfo.
    #default_info = [x for x in usual_providers if typeof]
    #fail("could not extract DefaultInfo from providers {}", usual_providers)

    # The first provider is a ProtoCompileInfo.
    all_files = usual_providers[0].output_files.to_list()

    return usual_providers + [
        GeneratedCodeInfo(
            ts_files = [f for f in all_files if _has_typescript_extension(f.path)],
            js_files = [f for f in all_files if not _has_typescript_extension(f.path)],
        ),
    ]

def _has_typescript_extension(path_string):
    return (
        path_string.endswith(".ts") or
        path_string.endswith(".mts") or
        path_string.endswith(".cts")
    )

def _this_rule_import_map_entry(ctx):
    """Returns an object that specifies how to import the current rule's messages.

    The returned struct must match the JSON spec in protoc_plugin.go.
    """
    proto_info = ctx.attr.protos[0][ProtoInfo]
    proto_filename = _import_paths_of_direct_sources(proto_info)[0]
    js_import = "./" + paths.basename(proto_filename).removesuffix(".proto") + "_pb"
    if _INCLUDE_SUFFIX_IN_IMPORT:
        js_import += ".mjs"
    return struct(
        proto_import = proto_filename,
        js_import = js_import,
        ts_proto_library_label = _label_for_printing(ctx.label),
    )

def _import_map_entry(generated_code_dir, dep):
    """Returns an object that specifies how to import a dep.

    The returned struct must match the JSON spec in protoc_plugin.go.
    """
    if not (TsProtoInfo in dep):
        return None
    ts_proto_info = dep[TsProtoInfo]
    proto_info = ts_proto_info.proto_info
    relative_import = _relative_path_for_import(
        ts_proto_info.primary_js_file.path,
        generated_code_dir,
    )

    #fail("relative_import = {}\ntarget = {}\ndir =    {}".format(relative_import, ts_proto_info.primary_js_file.path, generated_code_dir))
    return struct(
        proto_import = _import_paths_of_direct_sources(proto_info)[0],
        js_import = relative_import,
        ts_proto_library_label = _label_for_printing(
            ts_proto_info.ts_proto_library_label,
        ),
    )

# based on https://github.com/aspect-build/rules_js/issues/397
_ts_proto_library_protoc_plugin_compile = rule(
    doc = """Generates JavaScript and TypeScript files from a .proto file.""",
    provides = [
        DefaultInfo,
        GeneratedCodeInfo,
    ],
    implementation = _ts_proto_library_protoc_plugin_compile_impl,
    attrs = dict(
        proto_compile_attrs,
        deps = attr.label_list(
            providers = [
                # ts_proto_library deps should be be used to provide the mapping
                # from proto file -> generated js file.
                #
                # The ts_proto_library rule provide everything that js_library
                # does and the TsProtoInfo provider.
                [TsProtoInfo] + js_library_lib.provides,

                # js_library deps are permitted.
                js_library_lib.provides,
            ],
            doc = "js_library and ts_proto_library dependencies",
        ),
        _plugins = attr.label_list(
            providers = [ProtoPluginInfo],
            default = [
                Label("//ts_proto/codegen:delegating_plugin"),
            ],
            doc = "List of protoc plugins to apply",
        ),
    ),
    toolchains = proto_compile_toolchains,
    #[str(Label("@rules_proto_grpc//protobuf:toolchain_type"))],
)

def _ts_proto_library_rule_impl(ctx):
    """Implementation function for ts_proto_library_rule.

    Args:
        ctx: The Bazel rule execution context object.

    Returns:
        Providers:
            - ProtoCompileInfo
            - DefaultInfo
    """

    # Could probably also use ctx.attr.js_library[DefaultInfo].files.to_list()
    js_library_files = ctx.attr.js_library[DefaultInfo].files.to_list()

    main_library_file = [
        f
        for f in js_library_files
        if f.path.endswith("_pb.mjs") and not (f.path.endswith("grpc_web_pb.mjs"))
    ]
    if len(main_library_file) != 1:
        fail("expected exactly one file from {} to end in _pb.mjs not not grpc_web_pb.mjs, got {}: {} from {}".format(
            ctx.attr.js_library,
            len(main_library_file),
            main_library_file,
            js_library_files,
        ))
    main_library_file = main_library_file[0]

    grpc_web_library_file = [
        f
        for f in js_library_files
        if f.path.endswith("_grpc_web_pb.mjs")
    ]
    if len(grpc_web_library_file) != 1:
        fail("expected exactly one file from {} to end in _grpc_web_pb.mjs, got {}: {}".format(
            ctx.attr.js_library,
            len(grpc_web_library_file),
            grpc_web_library_file,
        ))
    grpc_web_library_file = grpc_web_library_file[0]

    proto_info = ctx.attr.proto[ProtoInfo]
    if len(proto_info.direct_sources) != 1:
        fail(
            "expected proto_library {} to have exactly 1 srcs, got {}: {}",
            ctx.attr.proto,
            len(proto_info.direct_sources),
            proto_info.direct_sources,
        )

    return [
        # Provide everything from the js_library of generated files.
        ctx.attr.js_library[provider]
        for provider in js_library_lib.provides
    ] + [
        # Also provide TsProtoInfo.
        TsProtoInfo(
            proto_info = ctx.attr.proto[ProtoInfo],
            ts_proto_library_label = ctx.label,
            #js_info = ctx.attr.js_library[JsInfo],
            primary_js_file = main_library_file,
            grpc_web_js_file = grpc_web_library_file,
        ),
    ]

# based on https://github.com/aspect-build/rules_js/issues/397
_ts_proto_library_rule = rule(
    implementation = _ts_proto_library_rule_impl,
    attrs = {
        "proto": attr.label(
            mandatory = True,
            providers = [ProtoInfo],
            doc = "Label that that provides ProtoInfo such as proto_library from rules_proto.",
        ),
        "js_library": attr.label(
            mandatory = True,
            providers = js_library_lib.provides,
            doc = "Label that provides JsInfo for the generated JavaScript for this rule.",
        ),
    },
    toolchains = [],
    provides = [TsProtoInfo] + js_library_lib.provides,
)

def default_tsconfig():
    return {
        "compilerOptions": {
            #"allowSyntheticDefaultImports": true,
            "strict": True,
            "sourceMap": True,
            "declaration": True,
            "declarationMap": True,
            "importHelpers": True,
            "target": "es2020",
            "traceResolution": False,
            "lib": [
                "dom",
                "es5",
                "es2015.collection",
                "es2015.iterable",
                "es2015.promise",
                "es2019",
                "es2021",
                "es2022",
            ],
            "module": "ES6",
            # "moduleResolution": "nodenext", // ECMAScript Module Support.
            "moduleResolution": "Node",
            "baseUrl": ".",
            "paths": {},
            "typeRoots": [
                "./node_modules/@types",
            ],
        },
    }

def ts_proto_library(
        name,
        proto,
        visibility = None,
        deps = [],
        implicit_deps = {},
        tsconfig = None):
    """A rule for compiling protobufs into a ts_project.

    Args:
        name: Name of the ts_project to produce.
        proto: proto_library rule to compile.
        visibility: Visibility of output library.
        deps: TypeScript dependencies.
        implicit_deps: A map from NPM package name to the bazel label of a

        tsconfig: The tsconfig to be passed to ts_project rules.
    """
    if tsconfig == None:
        tsconfig = default_tsconfig()

    # Generate the JavaScript and TypeScript code from the protos by running the
    # protoc_plugin.go code.
    _ts_proto_library_protoc_plugin_compile(
        name = name + "_compile",
        protos = [
            proto,
        ],
        # visibility = visibility,
        #verbose = 4,
        deps = deps,
        output_mode = "NO_PREFIX_FLAT",
    )

    ts_files = name + "_ts_files"
    non_ts_files = name + "_js_files"

    filtered_files(
        name = ts_files,
        srcs = [name + "_compile"],
        filter = "ts",
    )

    filtered_files(
        name = non_ts_files,
        srcs = [name + "_compile"],
        filter = "ts",
        invert = True,
    )

    implicit_deps_list = []
    REQUIRED_NPM_PACKAGE_NAMES = [
        "grpc-web",
        "google-protobuf",
        "@types/google-protobuf",
    ]
    unsatisfied_npm_packages = [
        npm_package
        for npm_package in REQUIRED_NPM_PACKAGE_NAMES
        if npm_package not in implicit_deps
    ]
    if len(unsatisfied_npm_packages) > 0:
        fail("implicit_deps is missing entries for {}".format(unsatisfied_npm_packages))

    for dep_package_name in REQUIRED_NPM_PACKAGE_NAMES:
        implicit_deps_list += implicit_deps[dep_package_name]

    deps = [x for x in deps]
    for want_dep in implicit_deps_list:
        if want_dep not in deps:
            deps.append(want_dep)

    ts_project(
        name = name + "_ts_project",
        srcs = [
            ts_files,
        ],
        assets = [
            non_ts_files,
        ],
        deps = deps,
        tsconfig = tsconfig,
    )

    _ts_proto_library_rule(
        name = name,
        proto = proto,
        js_library = name + "_ts_project",
        visibility = visibility,
    )

    # TypeScript import resolution description:
    # https://www.typescriptlang.org/docs/handbook/module-resolution.html

def _import_paths_of_direct_sources(proto_info):
    """Extracts the path used to import srcs of ProtoInfo.

    Args:
        proto_info: A ProtoInfo instance.

    Returns:
        A list of strings with import paths
    """
    return [
        # TODO(reddaly): This won't work on windows.
        # _relative_path_for_import just happens to do the right thing for .protos, but it
        # was written for resolving relative TypeScript imports. The leading ./ must be removed,
        # which is necessary in TypeScript imports.
        _relative_path_for_import(src.path, proto_info.proto_source_root).removeprefix("./")
        for src in proto_info.direct_sources
    ]

# TODO: Come up with a principled way of deciding whether imports get a suffix or not.
_INCLUDE_SUFFIX_IN_IMPORT = True

def _relative_path_for_import(target, start):
    """JS import path to `target` from `start`.

    Args:
      target: path that we want to get relative path to.
      start: path to directory from which we are starting.

    Returns:
      string: relative path to `target`.
    """
    p = relative_path(target, start)
    if _INCLUDE_SUFFIX_IN_IMPORT:
        #fail("relative_path({}, {}) = {}".format(target, start, p))
        return p

    if p.endswith(".mjs"):
        return p.removesuffix(".mjs")
    if p.endswith(".cjs"):
        return p.removesuffix(".cjs")
    if p.endswith(".js"):
        return p.removesuffix(".js")

    fail("Unknown file extension of JavaScript dependency - likely an error in rules_ts_proto: {}".format(p))

def _label_for_printing(label):
    return "{}".format(label)
