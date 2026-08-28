// Copyright 2026 The FlutterTV Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:meta/meta.dart';

// Rendered manifests intentionally start with `// swift-tools-version:` (which
// must be the first line of a Package.swift), not a blank line.
// ignore_for_file: leading_newlines_in_multiline_strings

/// Generates the Swift Package Manager packages a tvOS app build needs to
/// consume federated `*_tvos` plugins (Flutter 3.44+ default), mirroring how
/// stock Flutter wires SPM for iOS/macOS — but reimplemented here because the
/// upstream orchestration (`FlutterDarwinPlatform`) only knows iOS/macOS and we
/// don't patch the SDK.
///
/// Two generated packages, written under `tvos/Flutter/ephemeral/Packages/`:
///
/// 1. **`FlutterFramework`** — an intentionally **empty** package (a product and
///    a target with no sources). It exists so the `../FlutterFramework` path
///    dependency every federated plugin manifest declares keeps resolving; it
///    vends no engine of its own. Plugin targets `import Flutter` against the
///    `Flutter.framework` staged into `BUILT_PRODUCTS_DIR` before the build —
///    the framework search path every SwiftPM target compiles with. This
///    mirrors upstream Flutter, which dropped the `.binaryTarget` on
///    `Flutter.xcframework` in flutter/flutter#181739 after Xcode's handling of
///    it produced App Store rejections, and has stayed on the staged-framework
///    model since.
///
/// 2. **`FlutterGeneratedPluginSwiftPackage`** — the umbrella. Its single target
///    depends on `FlutterFramework` plus each discovered plugin's product, so
///    linking the umbrella into Runner pulls in every plugin (and Flutter). The
///    product is `static` so the plugins' symbols land in the Runner binary.
///
/// This is a pure generator: it only writes manifests, sources and symlinks.
/// Staging the engine into `BUILT_PRODUCTS_DIR` (the Runner scheme's "Prepare
/// Flutter framework" pre-action, plus a CLI-side copy for `flutter-tvos
/// build/run`) and embedding it into the bundle (the "Embed Flutter.framework"
/// build phase) are the project-integration steps.
class TvosSwiftPackageManager {
  TvosSwiftPackageManager({required FileSystem fileSystem}) : _fs = fileSystem;

  final FileSystem _fs;

  /// Name of the umbrella package/target, matching stock Flutter so the Xcode
  /// integration objects line up.
  static const String kGeneratedPluginsPackageName = 'FlutterGeneratedPluginSwiftPackage';

  /// Name of the package/target that vends `Flutter.xcframework`.
  static const String kFlutterFrameworkPackageName = 'FlutterFramework';

  /// tvOS deployment floor the generated packages declare. Must be ≤ the app's
  /// `TVOS_DEPLOYMENT_TARGET` or SwiftPM rejects the dependency graph.
  static const String kDefaultDeploymentTarget = '15.0';

  /// Writes the `FlutterFramework` package into [packageDirectory].
  ///
  /// The package is empty by design (see the class doc): the engine reaches the
  /// compiler through `BUILT_PRODUCTS_DIR` and the app bundle through the
  /// Runner target's "Embed Flutter.framework" phase, not through SwiftPM.
  ///
  /// Pass [legacyXcframework] to render the pre-1.5 manifest that vends that
  /// xcframework as a `.binaryTarget` instead. A project generated before the
  /// prepare/embed phases existed has no other way to get the engine into the
  /// build, so it stays on that path until it is regenerated.
  ///
  /// Re-runnable: the manifest, sources and symlink are refreshed each call.
  void generateFlutterFrameworkPackage({
    required Directory packageDirectory,
    Directory? legacyXcframework,
  }) {
    packageDirectory.createSync(recursive: true);
    final Link xcframeworkLink = packageDirectory.childLink('Flutter.xcframework');

    if (legacyXcframework != null) {
      packageDirectory
          .childFile('Package.swift')
          .writeAsStringSync(renderLegacyFlutterFrameworkManifest());
      if (xcframeworkLink.existsSync()) {
        xcframeworkLink.deleteSync();
      }
      xcframeworkLink.createSync(legacyXcframework.absolute.path);
      return;
    }

    packageDirectory
        .childFile('Package.swift')
        .writeAsStringSync(renderFlutterFrameworkManifest());

    // A project that used to be on the binary-target path leaves this symlink
    // behind. Left in place it is merely stale, but it is also the one piece of
    // evidence that would make a future reader think SwiftPM still vends the
    // engine, so drop it with the manifest that used it.
    if (xcframeworkLink.existsSync()) {
      xcframeworkLink.deleteSync();
    }

    // SwiftPM requires a target to have a sources directory, empty target or
    // not — same reason the umbrella carries a placeholder file.
    final Directory sources = packageDirectory
        .childDirectory('Sources')
        .childDirectory(kFlutterFrameworkPackageName);
    sources.createSync(recursive: true);
    sources.childFile('$kFlutterFrameworkPackageName.swift').writeAsStringSync(
      '// Generated by flutter-tvos. Intentionally empty — this package vends no\n'
      '// code. It only keeps the `../FlutterFramework` dependency in every\n'
      '// federated plugin manifest resolvable; the engine itself is staged into\n'
      '// BUILT_PRODUCTS_DIR and embedded by the Runner target.\n',
    );
  }

  /// Writes the `FlutterGeneratedPluginSwiftPackage` umbrella into
  /// [packageDirectory], symlinking each plugin under `.packages/<name>` and
  /// depending on [flutterFrameworkRelativePath] (the path to the
  /// `FlutterFramework` package, relative to [packageDirectory]).
  ///
  /// Returns the rendered umbrella manifest (also written to disk).
  String generatePluginsSwiftPackage({
    required Directory packageDirectory,
    required List<TvosSpmPlugin> plugins,
    required String flutterFrameworkRelativePath,
    String deploymentTarget = kDefaultDeploymentTarget,
  }) {
    packageDirectory.createSync(recursive: true);

    // SwiftPM requires a target to have a sources directory. The umbrella has
    // no code of its own — a single empty file satisfies the toolchain.
    final Directory sources = packageDirectory
        .childDirectory('Sources')
        .childDirectory(kGeneratedPluginsPackageName);
    sources.createSync(recursive: true);
    sources.childFile('$kGeneratedPluginsPackageName.swift').writeAsStringSync(
      '// Generated by flutter-tvos. This package brings together the tvOS\n'
      '// implementations of every federated plugin the app depends on.\n',
    );

    // Symlink each plugin package under `.packages/<name>` so the manifest can
    // reference a stable relative path regardless of where the plugin lives.
    final Directory packagesDir = packageDirectory.childDirectory('.packages');
    packagesDir.createSync(recursive: true);
    final pluginRefs = <_PluginRef>[];
    for (final plugin in plugins) {
      final Link link = packagesDir.childLink(plugin.name);
      if (link.existsSync()) {
        link.deleteSync();
      }
      link.createSync(_fs.directory(plugin.packagePath).absolute.path);
      pluginRefs.add(
        _PluginRef(
          name: plugin.name,
          relativePath: '.packages/${plugin.name}',
          productName: plugin.libraryName,
        ),
      );
    }

    final String manifest = renderPluginsUmbrellaManifest(
      plugins: pluginRefs,
      flutterFrameworkRelativePath: flutterFrameworkRelativePath,
      deploymentTarget: deploymentTarget,
    );
    packageDirectory.childFile('Package.swift').writeAsStringSync(manifest);
    return manifest;
  }

  /// Renders the `FlutterFramework` package manifest. Static content: an empty
  /// package that exists only to keep every plugin's `../FlutterFramework`
  /// dependency resolvable.
  @visibleForTesting
  static String renderFlutterFrameworkManifest() {
    return '''// swift-tools-version: 5.9
// Generated by flutter-tvos. Do not edit.
//
// Intentionally empty. Federated tvOS plugins declare a dependency on this
// package so their targets can `import Flutter`, but the engine itself is not
// vended here: flutter-tvos stages Flutter.framework into BUILT_PRODUCTS_DIR
// before the build (the Runner scheme's "Prepare Flutter framework"
// pre-action), which is where every SwiftPM target looks for frameworks, and
// the Runner target embeds and code-signs it into the app bundle.
import PackageDescription

let package = Package(
  name: "$kFlutterFrameworkPackageName",
  products: [
    .library(name: "$kFlutterFrameworkPackageName", targets: ["$kFlutterFrameworkPackageName"]),
  ],
  targets: [
    .target(name: "$kFlutterFrameworkPackageName"),
  ]
)
''';
  }

  /// Renders the pre-1.5 `FlutterFramework` manifest, which vends the symlinked
  /// `Flutter.xcframework` as a binary target.
  ///
  /// Only for projects whose Runner target predates the "Embed
  /// Flutter.framework" build phase: there, Xcode's implicit embed of the
  /// binary target is the only thing putting the engine in the bundle.
  @visibleForTesting
  static String renderLegacyFlutterFrameworkManifest() {
    return '''// swift-tools-version: 5.9
// Generated by flutter-tvos. Do not edit.
//
// Vends the tvOS Flutter engine (Flutter.xcframework) to the Swift package
// graph so federated plugin targets can `import Flutter` without declaring a
// dependency of their own.
//
// Legacy layout, kept for projects generated before the "Prepare Flutter
// framework" pre-action and "Embed Flutter.framework" build phase existed.
// Regenerate the project ("flutter-tvos create .") to move to the staged
// framework model upstream Flutter also uses.
import PackageDescription

let package = Package(
  name: "$kFlutterFrameworkPackageName",
  products: [
    .library(name: "$kFlutterFrameworkPackageName", targets: ["$kFlutterFrameworkPackageName"]),
  ],
  targets: [
    .binaryTarget(name: "$kFlutterFrameworkPackageName", path: "Flutter.xcframework"),
  ]
)
''';
  }

  /// Renders the umbrella `FlutterGeneratedPluginSwiftPackage` manifest.
  ///
  /// SwiftPM derives a dynamic library's `CFBundleIdentifier` from the product
  /// name and rejects underscores, so plugin *product* names are hyphenated
  /// (e.g. `shared_preferences_tvos` → `shared-preferences-tvos`), matching the
  /// library name federated plugins declare. The package name (used for the
  /// path dependency) keeps the underscores.
  @visibleForTesting
  static String renderPluginsUmbrellaManifest({
    required List<_PluginRef> plugins,
    required String flutterFrameworkRelativePath,
    String deploymentTarget = kDefaultDeploymentTarget,
  }) {
    final dependencies = <String>[
      '    .package(name: "$kFlutterFrameworkPackageName", path: "$flutterFrameworkRelativePath"),',
      for (final _PluginRef p in plugins)
        '    .package(name: "${p.name}", path: "${p.relativePath}"),',
    ];
    final targetDependencies = <String>[
      '        .product(name: "$kFlutterFrameworkPackageName", package: "$kFlutterFrameworkPackageName"),',
      for (final _PluginRef p in plugins)
        '        .product(name: "${p.productName}", package: "${p.name}"),',
    ];
    return '''// swift-tools-version: 5.9
// Generated by flutter-tvos. Do not edit.
import PackageDescription

let package = Package(
  name: "$kGeneratedPluginsPackageName",
  platforms: [
    .tvOS("$deploymentTarget"),
  ],
  products: [
    .library(name: "$kGeneratedPluginsPackageName", type: .static, targets: ["$kGeneratedPluginsPackageName"]),
  ],
  dependencies: [
${dependencies.join('\n')}
  ],
  targets: [
    .target(
      name: "$kGeneratedPluginsPackageName",
      dependencies: [
${targetDependencies.join('\n')}
      ]
    ),
  ]
)
''';
  }
}

/// A federated tvOS plugin to include in the umbrella package: its [name]
/// (matching the SwiftPM package name in its `tvos/Package.swift`), the
/// [libraryName] (the `.library(name:)` product the umbrella links), and the
/// path to the directory containing that `Package.swift`.
@immutable
class TvosSpmPlugin {
  TvosSpmPlugin({required this.name, required this.packagePath, String? libraryName})
      : libraryName = libraryName ?? name.replaceAll('_', '-');

  final String name;
  final String packagePath;

  /// The SwiftPM product name the umbrella references. Defaults to the
  /// hyphenated package name (the porter convention), but a hand-authored
  /// plugin may declare any product name, so callers that read the manifest
  /// pass the parsed `.library(name:)` here rather than assuming the form.
  final String libraryName;
}

/// Internal: a resolved plugin reference for manifest rendering.
@immutable
class _PluginRef {
  const _PluginRef({
    required this.name,
    required this.relativePath,
    required this.productName,
  });

  final String name;
  final String relativePath;

  /// SwiftPM product (library) name the umbrella links against.
  final String productName;
}
