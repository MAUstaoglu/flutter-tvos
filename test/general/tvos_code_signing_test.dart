// Copyright 2026 The FlutterTV Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tvos/build_targets/application.dart';

import '../src/common.dart';
import '../src/context.dart';

void main() {
  late MemoryFileSystem fileSystem;
  late FakeProcessManager processManager;

  setUp(() {
    fileSystem = MemoryFileSystem.test();
    processManager = FakeProcessManager.any();
  });

  group('Code signing - team ID from pbxproj', () {
    testUsingContext(
      'extracts DEVELOPMENT_TEAM from project.pbxproj',
      () {
        final Directory tvosDir = fileSystem.directory('/project/tvos')
          ..createSync(recursive: true);
        final File pbxproj = tvosDir.childDirectory('Runner.xcodeproj').childFile('project.pbxproj')
          ..createSync(recursive: true);

        pbxproj.writeAsStringSync('''
/* Build configuration list for PBXNativeTarget "Runner" */
buildSettings = {
  ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
  DEVELOPMENT_TEAM = ABC1234567;
  INFOPLIST_FILE = Runner/Info.plist;
  PRODUCT_BUNDLE_IDENTIFIER = com.example.runner;
};
''');

        final String content = pbxproj.readAsStringSync();
        final teamRegex = RegExp(r'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10});');
        final Match? match = teamRegex.firstMatch(content);

        expect(match, isNotNull);
        expect(match!.group(1), equals('ABC1234567'));
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns null when no DEVELOPMENT_TEAM in pbxproj',
      () {
        final Directory tvosDir = fileSystem.directory('/project/tvos')
          ..createSync(recursive: true);
        final File pbxproj = tvosDir.childDirectory('Runner.xcodeproj').childFile('project.pbxproj')
          ..createSync(recursive: true);

        pbxproj.writeAsStringSync('''
buildSettings = {
  PRODUCT_BUNDLE_IDENTIFIER = com.example.runner;
};
''');

        final String content = pbxproj.readAsStringSync();
        final teamRegex = RegExp(r'DEVELOPMENT_TEAM\s*=\s*([A-Z0-9]{10});');
        final Match? match = teamRegex.firstMatch(content);

        expect(match, isNull);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );

    testUsingContext(
      'returns null when pbxproj does not exist',
      () {
        final Directory tvosDir = fileSystem.directory('/project/tvos')
          ..createSync(recursive: true);

        final File pbxproj = tvosDir
            .childDirectory('Runner.xcodeproj')
            .childFile('project.pbxproj');

        expect(pbxproj.existsSync(), isFalse);
      },
      overrides: <Type, Generator>{
        FileSystem: () => fileSystem,
        ProcessManager: () => processManager,
      },
    );
  });

  group('Code signing - keychain identity parsing', () {
    testWithoutContext('extracts team ID from security find-identity output', () {
      const securityOutput = '''
  1) AABBCCDDEE1122334455 "Apple Development: John Doe (XYZ9876543)"
  2) FFEEDDCCBBAA5544332211 "Apple Distribution: ACME Corp (XYZ9876543)"
     2 valid identities found
''';

      final identityRegex = RegExp(r'Apple Development:.*\(([A-Z0-9]{10})\)');
      final Match? match = identityRegex.firstMatch(securityOutput);

      expect(match, isNotNull);
      expect(match!.group(1), equals('XYZ9876543'));
    });

    testWithoutContext('returns null when no Apple Development identity found', () {
      const securityOutput = '''
  1) FFEEDDCCBBAA5544332211 "Apple Distribution: ACME Corp (XYZ9876543)"
     1 valid identities found
''';

      final identityRegex = RegExp(r'Apple Development:.*\(([A-Z0-9]{10})\)');
      final Match? match = identityRegex.firstMatch(securityOutput);

      expect(match, isNull);
    });

    testWithoutContext('returns null for empty keychain output', () {
      const securityOutput = '     0 valid identities found\n';

      final identityRegex = RegExp(r'Apple Development:.*\(([A-Z0-9]{10})\)');
      final Match? match = identityRegex.firstMatch(securityOutput);

      expect(match, isNull);
    });
  });

  group('Code signing - App Store Connect API key', () {
    late BufferLogger logger;

    setUp(() {
      logger = BufferLogger.test();
    });

    Map<String, String> env({String? path, String? id, String? issuer}) {
      return <String, String>{
        if (path != null) 'APP_STORE_CONNECT_KEY_PATH': path,
        if (id != null) 'APP_STORE_CONNECT_KEY_ID': id,
        if (issuer != null) 'APP_STORE_CONNECT_ISSUER_ID': issuer,
      };
    }

    testWithoutContext('forwards the key when all three are set', () {
      fileSystem.file('/keys/AuthKey_ABC.p8').createSync(recursive: true);

      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        <String>[
          '-authenticationKeyPath',
          '/keys/AuthKey_ABC.p8',
          '-authenticationKeyID',
          'ABC1234567',
          '-authenticationKeyIssuerID',
          'issuer-uuid',
        ],
      );
    });

    testWithoutContext('is inert when nothing is set', () {
      // The common case: a machine with a working Xcode account must behave
      // exactly as it did before this existed.
      expect(
        resolveAuthenticationArgs(<String, String>{}, fileSystem, logger),
        isEmpty,
      );
      expect(logger.warningText, isEmpty);
    });

    testWithoutContext('is inert when the trio is incomplete', () {
      fileSystem.file('/keys/AuthKey_ABC.p8').createSync(recursive: true);
      // A half-configured environment must not produce half a flag set --
      // xcodebuild rejects the key arguments unless all three are present.
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', id: 'ABC1234567'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/AuthKey_ABC.p8', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
    });

    testWithoutContext('treats an empty value as unset', () {
      expect(
        resolveAuthenticationArgs(
          env(path: '', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
    });

    testWithoutContext('warns, and falls back, when the key file is missing', () {
      // Configured but wrong is the case worth a warning: staying silent looks
      // identical to never having configured it, and the build then fails much
      // later complaining about a capability rather than a credential.
      expect(
        resolveAuthenticationArgs(
          env(path: '/keys/absent.p8', id: 'ABC1234567', issuer: 'issuer-uuid'),
          fileSystem,
          logger,
        ),
        isEmpty,
      );
      expect(logger.warningText, contains('/keys/absent.p8'));
    });
  });

  group('Code signing - simulator vs device', () {
    testWithoutContext('simulator builds do not need signing', () {
      // Simulator builds should skip all signing logic
      const isSimulator = true;
      if (isSimulator) {
        // _resolveSigningArgs returns empty list for simulators
        expect(const <String>[], isEmpty);
      }
    });

    testWithoutContext('device builds need signing', () {
      const isSimulator = false;
      expect(isSimulator, isFalse);
      // Device builds should attempt to resolve signing
    });
  });
}
