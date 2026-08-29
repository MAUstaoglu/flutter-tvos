// Signs the tvOS engine with the *app developer's* own identity, locally, at
// build time.
//
// Why here and not in the published artifact:
//
// Apple's commonly-used-SDK check (ITMS-91065) looks at the Flutter engine that
// ships inside an app. Satisfying it requires the engine bundle to carry a
// signature before Xcode embeds it. The obvious place to put that signature is
// the published artifact — but flutter-tvos is a public project, and signing
// releases there would stamp the maintainer's Developer ID onto every download
// and make cutting a release depend on one person's certificate.
//
// Signing locally instead produces the same bytes for Apple while keeping the
// published artifacts identity-free: every developer's build carries that
// developer's own signature, and the repo has no signing obligation at all.
//
// This runs against the extracted engine cache (engine_artifacts/<variant>/),
// so it covers both embed paths — the explicit "Embed Flutter.framework" phase,
// which copies from tvos/Flutter/Flutter.framework, and the legacy SwiftPM
// binary target, which resolves a symlink straight into the cache.

import 'dart:convert' show LineSplitter;

import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:process/process.dart';

/// Signs engine artifacts with a Developer ID from the local keychain.
class TvosEngineSigner {
  TvosEngineSigner({
    required FileSystem fileSystem,
    required ProcessManager processManager,
    required Logger logger,
    required Platform platform,
  }) : _fs = fileSystem,
       _processManager = processManager,
       _logger = logger,
       _platform = platform;

  final FileSystem _fs;
  final ProcessManager _processManager;
  final Logger _logger;
  final Platform _platform;

  /// Overrides identity selection. Accepts either a SHA-1 hash or a display
  /// name; a name that matches more than one certificate is rejected rather
  /// than guessed at.
  static const String kIdentityEnvVar = 'TVOS_ENGINE_SIGNING_IDENTITY';

  /// Set to `1` to skip signing entirely.
  static const String kSkipEnvVar = 'TVOS_ENGINE_SKIP_SIGNING';

  /// A codesigning identity in the login keychain.
  ///
  /// [hash] is the SHA-1. Everything downstream signs by hash, never by name:
  /// duplicate certificates sharing a display name are common (a renewed cert
  /// sits alongside the one it replaced), and `codesign --sign <name>` fails
  /// with "ambiguous (matches ... and ...)" when that happens.
  static ({String hash, String name})? _parseIdentity(String line) {
    final RegExpMatch? m = RegExp(r'\)\s+([0-9A-F]{40})\s+"([^"]+)"').firstMatch(line);
    if (m == null) {
      return null;
    }
    return (hash: m.group(1)!, name: m.group(2)!);
  }

  /// Every valid codesigning identity in the login keychain.
  List<({String hash, String name})> _availableIdentities() {
    final ProcessResult result = _processManager.runSync(<String>[
      'security',
      'find-identity',
      '-v',
      '-p',
      'codesigning',
    ]);
    if (result.exitCode != 0) {
      return const <({String hash, String name})>[];
    }
    return LineSplitter.split(result.stdout.toString())
        .map(_parseIdentity)
        .nonNulls
        .toList();
  }

  /// The identity to sign the engine with, or `null` when there is none and the
  /// build should proceed unsigned.
  ///
  /// Prefers `Developer ID Application`, which is what flutter.dev uses on its
  /// own engine artifacts. Falls back to nothing rather than to a development
  /// certificate: a wrong-type signature is not obviously better than none, and
  /// silently picking one would hide the real problem.
  ({String hash, String name})? resolveIdentity() {
    final List<({String hash, String name})> identities = _availableIdentities();

    final String? override = _platform.environment[kIdentityEnvVar];
    if (override != null && override.isNotEmpty) {
      if (RegExp(r'^[0-9A-Fa-f]{40}$').hasMatch(override)) {
        final String wanted = override.toUpperCase();
        for (final id in identities) {
          if (id.hash == wanted) {
            return id;
          }
        }
        throw StateError(
          '$kIdentityEnvVar is set to $override, which is not a valid codesigning '
          'identity in the login keychain. Run "security find-identity -v -p codesigning" '
          'to list the available ones.',
        );
      }
      final List<({String hash, String name})> named = identities
          .where((({String hash, String name}) id) => id.name == override)
          .toList();
      if (named.isEmpty) {
        throw StateError(
          '$kIdentityEnvVar is set to "$override", which matches no codesigning '
          'identity in the login keychain.',
        );
      }
      if (named.length > 1) {
        throw StateError(
          '$kIdentityEnvVar is set to "$override", which matches ${named.length} '
          'certificates. Set it to the SHA-1 hash instead:\n'
          '${named.map((({String hash, String name}) i) => '  ${i.hash}').join('\n')}',
        );
      }
      return named.single;
    }

    final List<({String hash, String name})> developerIds = identities
        .where((({String hash, String name}) id) => id.name.startsWith('Developer ID Application:'))
        .toList();
    if (developerIds.isEmpty) {
      return null;
    }
    // Duplicates here are the renewed-certificate case: same subject, different
    // hash, either will verify. Signing by hash means picking one is safe.
    return developerIds.first;
  }

  /// Signs the engine bundles under [variantDir] (an `engine_artifacts/<variant>`
  /// directory) unless they already carry [identity]'s signature.
  ///
  /// Order matters: the frameworks inside `Flutter.xcframework` are signed
  /// first, then the xcframework bundle itself, so the outer seal covers the
  /// inner signatures. Signing the outer bundle first would invalidate it.
  ///
  /// Hardened runtime and a secure timestamp match how flutter.dev signs its own
  /// engine, so a tvOS artifact is not weaker than the iOS one it mirrors.
  void signVariant(Directory variantDir, ({String hash, String name}) identity) {
    final frameworks = <Directory>[];

    final Directory xcframework = variantDir.childDirectory('Flutter.xcframework');
    if (xcframework.existsSync()) {
      for (final FileSystemEntity slice in xcframework.listSync()) {
        if (slice is Directory) {
          final Directory inner = slice.childDirectory('Flutter.framework');
          if (inner.existsSync()) {
            frameworks.add(inner);
          }
        }
      }
    }
    final Directory standalone = variantDir.childDirectory('Flutter.framework');
    if (standalone.existsSync()) {
      frameworks.add(standalone);
    }

    if (frameworks.isEmpty) {
      return;
    }
    if (frameworks.every((Directory d) => _isSignedBy(d, identity.name))) {
      _logger.printTrace('tvOS engine already signed by ${identity.name}.');
      return;
    }

    for (final framework in frameworks) {
      _codesign(framework.path, identity.hash, hardenedRuntime: true);
    }
    if (xcframework.existsSync()) {
      // The xcframework wrapper is a bundle of bundles with no Mach-O of its
      // own, so the runtime hardening flag does not apply to it.
      _codesign(xcframework.path, identity.hash, hardenedRuntime: false);
    }
    _logger.printTrace('Signed tvOS engine in ${variantDir.path} with ${identity.name}.');
  }

  bool _isSignedBy(Directory bundle, String identityName) {
    if (!bundle.childDirectory('_CodeSignature').existsSync()) {
      return false;
    }
    // codesign writes its display output to stderr.
    final ProcessResult result = _processManager.runSync(<String>[
      'codesign',
      '-dvv',
      bundle.path,
    ]);
    return result.stderr.toString().contains('Authority=$identityName');
  }

  void _codesign(String path, String identityHash, {required bool hardenedRuntime}) {
    final ProcessResult result = _processManager.runSync(<String>[
      'codesign',
      '--force',
      // A secure timestamp is a synchronous call to timestamp.apple.com. It is
      // what makes the signature outlive the certificate, and flutter.dev's
      // artifacts carry one.
      '--timestamp',
      if (hardenedRuntime) ...<String>['--options', 'runtime'],
      '--sign',
      identityHash,
      path,
    ]);
    if (result.exitCode != 0) {
      throw StateError('codesign failed for $path:\n${result.stderr}');
    }
  }

  /// Signs [variantDir] with the developer's own identity, reporting rather than
  /// failing when there is nothing to sign with.
  ///
  /// Never throws for a missing certificate: a developer without a Developer ID
  /// can still build and run locally, and only App Store submission needs this.
  void signIfPossible(Directory variantDir) {
    if (_platform.environment[kSkipEnvVar] == '1') {
      _logger.printTrace('tvOS engine signing skipped ($kSkipEnvVar=1).');
      return;
    }
    if (!_fs.directory(variantDir.path).existsSync()) {
      return;
    }

    final ({String hash, String name})? identity;
    try {
      identity = resolveIdentity();
    } on StateError catch (e) {
      throw StateError('${e.message}\n');
    }

    if (identity == null) {
      _logger.printStatus(
        'Warning: no "Developer ID Application" certificate found, so the Flutter '
        'engine is being embedded unsigned.\n'
        'Local builds and internal TestFlight work, but App Store and external '
        'TestFlight submissions are rejected with ITMS-91065 ("Missing signature").\n'
        'Create one at https://developer.apple.com/account/resources/certificates, '
        'or set $kIdentityEnvVar to the identity to use. '
        'Set $kSkipEnvVar=1 to silence this.',
      );
      return;
    }

    try {
      signVariant(variantDir, identity);
    } on StateError catch (e) {
      // Signing the engine is not worth failing an otherwise good build over —
      // a debug run on a device does not care. Say plainly what it costs.
      _logger.printError(
        'Warning: could not sign the Flutter engine with ${identity.name}: ${e.message}\n'
        'The build continues, but a submission built from it will be rejected '
        'with ITMS-91065.',
      );
    }
  }
}
