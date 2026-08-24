// Copyright 2026 The FlutterTV Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert' show json;

import 'package:code_assets/code_assets.dart';
import 'package:data_assets/data_assets.dart';
import 'package:flutter_tools/src/asset.dart' show FlutterHookResult;
import 'package:flutter_tools/src/base/common.dart' show throwToolExit;
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart' show Logger;
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart' hide BuildResult;
import 'package:flutter_tools/src/build_system/depfile.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart' show MissingDefineException;
import 'package:flutter_tools/src/build_system/targets/native_assets.dart'
    show LinkHooks, createFlutterNativeAssetsBuildRunner;
import 'package:flutter_tools/src/features.dart' show featureFlags;
import 'package:flutter_tools/src/hook_runner.dart' show FlutterHookRunner;
import 'package:flutter_tools/src/isolated/native_assets/dart_hook_result.dart';
import 'package:flutter_tools/src/isolated/native_assets/ios/native_assets.dart'
    show getIOSSdk, targetIOSVersion;
import 'package:flutter_tools/src/isolated/native_assets/macos/native_assets_host.dart'
    show cCompilerConfigMacOS;
import 'package:flutter_tools/src/isolated/native_assets/native_assets.dart'
    show FlutterCodeAsset, FlutterNativeAssetsBuildRunner;
import 'package:flutter_tools/src/macos/xcode.dart' show environmentTypeFromSdkroot;
import 'package:hooks/hooks.dart'
    show BuildInputBuilder, EncodedAsset, LinkInputBuilder, ProtocolExtension;
import 'package:hooks_runner/hooks_runner.dart' show BuildResult;
import 'package:meta/meta.dart' show visibleForTesting;

/// tvOS's name in the Dart hooks protocol.
///
/// The protocol's built-in operating systems are the ones `dart:ffi` can name,
/// and tvOS is not among them: under the `package:code_assets` the Flutter
/// SDK pins, `OS.fromString('tvos')` throws rather than minting a value.
/// (2.0.0 opened that set up, but the tool cannot move to it — it gives `OS` a
/// non-primitive `==`, which makes a `const` map inside flutter_tools fail to
/// compile, and the SDK checkout is never patched.)
///
/// The wire format has no such restriction. `target_os` is a plain string on
/// both sides of the protocol, and a hook resolving code_assets 2.0.0 — which
/// an app is free to do, its dependencies being resolved separately from the
/// tool's — reads an unfamiliar name back as an ordinary [OS]. So tvOS can
/// introduce itself by name even while the tool's own copy of the library has
/// no word for it.
///
/// That distinction is the point. tvOS is an Apple platform and a close
/// relative of iOS, but it is not iOS: different engine, different screen,
/// different SDK, a different set of things a package can do. A hook told
/// `ios` cannot tell the difference and has no way to ask; a hook told
/// `tvos` can.
const String tvOSName = 'tvos';

/// The architecture tvOS builds target.
///
/// Apple TV is arm64, and so is the simulator on every Mac this toolchain
/// supports, so there is one value here rather than a list.
const Architecture tvOSArchitecture = Architecture.arm64;

/// The `buildAssetTypes` name for code assets, which is not exported.
const String _codeAssetType = 'code_assets';

/// The protocol's key for the target operating system.
const String _targetOSKey = 'target_os';

/// The code-asset half of a tvOS hook input.
///
/// This wraps `CodeAssetExtension` rather than being one, for a single reason:
/// that class takes an [OS], and the tool's copy of `package:code_assets`
/// cannot construct one that says tvOS. So the config is built by the real
/// thing — which owns the layout, the C compiler block, and everything else —
/// and then the one field its API cannot express is written directly onto the
/// JSON it produced.
///
/// The `iOS` sub-config the wrapped extension would carry is deliberately not
/// supplied. It describes an iPhone SDK and a deployment target that no tvOS
/// hook should be reading, and leaving it out keeps the input from claiming
/// something untrue alongside a target OS that is true.
///
/// The validation callbacks are left at their defaults, which report nothing,
/// instead of being forwarded. `CodeAssetExtension`'s implementations parse
/// `target_os` back into an [OS] and would throw on a name this version does
/// not know; and there is nothing here for them to check anyway, since no code
/// asset produced under this extension is kept. Data assets are validated by
/// `DataAssetsExtension`, which is untouched by any of this.
final class TvosCodeAssetExtension extends ProtocolExtension {
  TvosCodeAssetExtension({required CCompilerConfig? cCompiler})
    : _codeAssets = CodeAssetExtension(
        targetArchitecture: tvOSArchitecture,
        // Replaced by [tvOSName] as soon as it has been written; see
        // [_nameWatchOS]. Of the operating systems this library can name, the
        // iOS family is the closest to the truth, but no hook ever reads it.
        targetOS: OS.iOS,
        linkModePreference: LinkModePreference.dynamic,
        // Best effort: a hook that knows about tvOS can use the host
        // toolchain, and one that does not will not get as far as reading it.
        cCompiler: cCompiler,
      );

  final CodeAssetExtension _codeAssets;

  @override
  void setupBuildInput(BuildInputBuilder input) {
    _codeAssets.setupBuildInput(input);
    _nameWatchOS(input.config.json);
  }

  @override
  void setupLinkInput(LinkInputBuilder input) {
    _codeAssets.setupLinkInput(input);
    _nameWatchOS(input.config.json);
  }

  /// Replaces the target OS in the code-asset block with [tvOSName].
  ///
  /// `target_os` is a plain string in the protocol's syntax on both sides, so
  /// this produces an input that is well-formed by the schema and reads back as
  /// an ordinary [OS] wherever the library is new enough to mint one.
  static void _nameWatchOS(Map<String, Object?> config) {
    final extensions = config['extensions']! as Map<String, Object?>;
    final code = extensions[_codeAssetType]! as Map<String, Object?>;
    code[_targetOSKey] = tvOSName;
  }
}

/// The iOS-family code config the fallback needs.
///
/// A hook told `ios` goes on to read this — `objective_c` reaches for
/// `code.iOS.targetSdk` — so the fallback has to be a faithful iOS input, not
/// just an iOS name.
IOSCodeConfig _iosFamilyConfig(Environment environment) {
  final String? sdkRoot = environment.defines[kSdkRoot];
  if (sdkRoot == null) {
    throw MissingDefineException(kSdkRoot, 'tvos_build_hooks');
  }
  return IOSCodeConfig(
    targetVersion: targetIOSVersion,
    targetSdk: getIOSSdk(environmentTypeFromSdkroot(sdkRoot, environment.fileSystem)!),
  );
}

/// Runs every package's Dart build hook for a tvOS app, and returns the
/// data assets they produced.
///
/// This is tvOS driving the hooks protocol on its own behalf, rather than
/// borrowing the iOS pipeline's driver. flutter_tools translates its own
/// `TargetPlatform`s into protocol targets through a closed set that has no
/// tvOS in it, so going through that path means being announced as `ios`.
/// Assembling the protocol extensions here instead means a hook is told
/// [tvOSName], which is the truth and is what a package needs in order to
/// pick the right output for this platform.
///
/// Code assets are requested and then dropped. Nothing built by a code-asset
/// hook is installed into a tvOS app — its plugins are native and resolved
/// by the package manager — but the protocol keeps the target OS *inside* the
/// code-asset config, so a hook that is not asked for code assets is not told
/// what it is building for at all. Asking is currently the only way to say
/// `tvos`.
///
/// Whether the name lands is a property of the app's packages, so it is tried
/// and not predicted; the fallback is inline below.
Future<DartHooksResult> runTvosHooks({
  required FlutterNativeAssetsBuildRunner buildRunner,
  required Environment environment,
}) async {
  final buildStart = DateTime.now();

  final List<String> packagesWithHooks = await buildRunner.packagesWithNativeAssets();
  if (packagesWithHooks.isEmpty) {
    environment.logger.printTrace('No packages with Dart build hooks. Skipping.');
    return DartHooksResult.empty();
  }

  if (!featureFlags.isNativeAssetsEnabled && !featureFlags.isDartDataAssetsEnabled) {
    throwToolExit(
      'Package(s) ${packagesWithHooks.join(' ')} require the dart assets feature '
      'to be enabled.\n'
      '  Enable data assets using `flutter config --enable-dart-data-assets`.',
    );
  }

  final CCompilerConfig? cCompiler = await cCompilerConfigMacOS(throwIfNotFound: false);
  final DataAssetsExtension? dataAssets = featureFlags.isDartDataAssetsEnabled
      ? DataAssetsExtension()
      : null;

  // Ask as tvOS first. Whether that works is a property of the app's
  // packages, not something this build can look up: the name is read on the
  // *hook's* side, by the `package:code_assets` the app resolved, and before
  // 2.0.0 that library's set of operating systems was closed — `config.code`
  // parses `target_os` eagerly and throws on a name it does not know. A hook as
  // ordinary as `objective_c`'s dies on its first line, not with "tvOS is
  // unsupported", which it would handle, but before it can look.
  //
  // A package can be fine on an old code_assets by reading the name off the
  // config JSON, which is a plain string on both sides — flutter_scene does
  // exactly that — so the resolved version does not answer the question either.
  // Asking and seeing is the only thing that does.
  BuildResult? result = await buildRunner.build(
    extensions: <ProtocolExtension>[
      TvosCodeAssetExtension(cCompiler: cCompiler),
      if (dataAssets != null) dataAssets,
    ],
    // Linking only ever concerns code assets, and none survive this function.
    linkingEnabled: false,
  );

  if (result == null) {
    // Fall back to what builds for this platform said before it could name
    // itself. The hooks just printed why they stopped, so say what happens now:
    // an unexplained retry after a stack trace reads as a broken build.
    environment.logger.printStatus(
      'A build hook could not be run for tvOS by name. Retrying as the iOS '
      'family, which is what tvOS builds asked for before this platform '
      'could introduce itself.\n'
      'A package holding this back is one that reads its target OS through '
      "code_assets' typed accessor on a code_assets older than 2.0.0, which "
      'throws on any OS it does not already know.',
    );
    result = await buildRunner.build(
      extensions: <ProtocolExtension>[
        CodeAssetExtension(
          targetArchitecture: tvOSArchitecture,
          targetOS: OS.iOS,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: cCompiler,
          iOS: _iosFamilyConfig(environment),
        ),
        if (dataAssets != null) dataAssets,
      ],
      linkingEnabled: false,
    );
  }
  if (result == null) {
    _throwHookFailed(packagesWithHooks);
  }

  return DartHooksResult(
    buildStart: buildStart,
    buildEnd: DateTime.now(),
    // Deliberately empty; see the note on requesting code assets above.
    codeAssets: const <FlutterCodeAsset>[],
    dataAssets: <DataAsset>[
      for (final EncodedAsset asset in result.encodedAssets)
        if (asset.isDataAsset) DataAsset.fromEncoded(asset),
    ],
    dependencies: result.dependencies,
  );
}

/// Explains a hook failure in terms of what was actually asked for.
///
/// The generic message reads as though the app requested a native build it
/// never requested, which sends people looking in the wrong place. Say why the
/// hooks ran, and what the ways out are, because the answer is a judgement
/// about a dependency rather than something to fix in this build.
Never _throwHookFailed(List<String> packagesWithHooks) {
  throwToolExit(
    'A Dart build hook failed while building for tvOS, both as tvOS and '
    'as the iOS family.\n'
    '\n'
    'Packages with build hooks in this app: ${packagesWithHooks.join(', ')}.\n'
    '\n'
    'The hooks run so that packages generating per-platform *data* — shader\n'
    'bundles and the like — are told which platform. The protocol only carries\n'
    'that alongside a code-asset request, which is why one was made. Nothing a\n'
    'code-asset hook produces is installed into a tvOS app, whose plugins are\n'
    'native and resolved by the package manager, so this failure does not mean\n'
    'the app is missing something it needs.\n'
    '\n'
    'The second attempt built exactly what an iOS build of this app builds, so\n'
    'an iOS build is the quickest way to tell a missing toolchain (a Rust hook\n'
    'wants cargo, a C hook wants its compiler) from something specific to this\n'
    'platform. Either install the toolchain the hook wants, or drop the\n'
    'dependency, whose native half this app cannot use anyway.',
  );
}

/// Runs the Dart build hooks as part of the tvOS build graph.
///
/// The tvOS pipeline skips upstream's native-asset targets: their code-asset
/// half is iOS/macOS-only and a tvOS app does not use those FFI
/// implementations anyway (see `TvosCopyFlutterBundle`). Data assets were a
/// different thing that happened to share the same pass — produced on the host
/// by ordinary Dart, which is how a package compiles its GPU shader bundles for
/// the platform it is going to run on.
///
/// Skipping them wholesale meant such a package silently shipped whatever its
/// generated directory happened to contain — assets left behind by a macOS or
/// simulator build of the same tree, or nothing at all. Neither failed the
/// build; the app just rendered a black scene on device. So this target runs
/// them, through [runTvosHooks].
class TvosBuildHooks extends Target {
  const TvosBuildHooks({@visibleForTesting FlutterNativeAssetsBuildRunner? buildRunner})
    : _buildRunner = buildRunner;

  /// Injected by tests, which have no hooks to run and want to drive the
  /// result. Mirrors upstream `BuildHooks`' seam.
  final FlutterNativeAssetsBuildRunner? _buildRunner;

  @override
  String get name => 'tvos_build_hooks';

  @override
  List<Target> get dependencies => const <Target>[];

  @override
  List<Source> get inputs => const <Source>[
    Source.pattern('{WORKSPACE_DIR}/.dart_tool/package_config.json'),
  ];

  /// Written where [LinkHooks] would have written it, because that is where
  /// `CopyFlutterBundle` looks for the hooks' result. There is no link phase
  /// here — linking only concerns code assets — so the build result is the
  /// whole result.
  @override
  List<Source> get outputs => const <Source>[
    Source.pattern('{BUILD_DIR}/${LinkHooks.resultFilename}'),
  ];

  @override
  List<String> get depfiles => const <String>[depFilename];

  static const depFilename = 'tvos_hooks.d';

  @override
  Future<void> build(Environment environment) async {
    final FileSystem fileSystem = environment.fileSystem;

    if (environment.defines[kBuildMode] == null) {
      throw MissingDefineException(kBuildMode, name);
    }

    final FlutterNativeAssetsBuildRunner buildRunner =
        _buildRunner ?? await createFlutterNativeAssetsBuildRunner(environment);

    final DartHooksResult buildResult = await runTvosHooks(
      buildRunner: buildRunner,
      environment: environment,
    );

    final File resultFile = environment.buildDir.childFile(LinkHooks.resultFilename);
    if (!resultFile.parent.existsSync()) {
      resultFile.parent.createSync(recursive: true);
    }
    resultFile.writeAsStringSync(json.encode(buildResult.toJson()));

    final Set<Uri> buildDependencies = buildResult.dependencies.toSet();
    final depfile = Depfile(
      <File>[for (final Uri dependency in buildResult.dependencies) fileSystem.file(dependency)],
      <File>[
        resultFile,
        for (final Uri uri in buildResult.filesToBeBundled)
          if (!buildDependencies.contains(uri)) fileSystem.file(uri),
      ],
    );
    final File outputDepfile = environment.buildDir.childFile(depFilename);
    if (!outputDepfile.parent.existsSync()) {
      outputDepfile.parent.createSync(recursive: true);
    }
    environment.depFileService.writeToFile(depfile, outputDepfile, filterOutputs: true);
  }
}

/// Runs the same hooks during a resident session, so hot reload rebuilds
/// generated assets the way a full build does.
///
/// Upstream's runner exists and `RunCommand` already threads it through to the
/// resident runner, which calls it whenever the asset bundle needs rebuilding —
/// but it reads the implementation out of the context, so a CLI that does not
/// register one skips the call for the whole session, and a package that
/// generates its assets from a hook keeps serving whatever the last full build
/// left behind.
///
/// This registers one that goes through [runTvosHooks], so a reload names
/// the same target OS a build does. Upstream's own implementation would name a
/// different one — it asks for data assets alone, which carries no target OS at
/// all — and a package choosing an output from it would swap in a different
/// one every time the two paths took turns.
class TvosHookRunner implements FlutterHookRunner {
  FlutterHookResult? _lastResult;

  @override
  Future<FlutterHookResult> runHooks({
    required TargetPlatform targetPlatform,
    required Environment environment,
    Logger? logger,
  }) async {
    final FlutterHookResult? cached = _lastResult;
    if (cached != null && !cached.hasAnyModifiedFiles(environment.fileSystem)) {
      logger?.printTrace('runTvosHooks() - up-to-date already');
      return cached;
    }
    logger?.printTrace('runTvosHooks() - will perform dart build');

    final DartHooksResult result = await runTvosHooks(
      buildRunner: await createFlutterNativeAssetsBuildRunner(environment),
      environment: environment,
    );
    return _lastResult = result.asFlutterResult;
  }
}
