import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tsukuyomi_space_app/core/app_release.dart';
import 'package:tsukuyomi_space_app/core/app_update_controller.dart';
import 'package:tsukuyomi_space_app/core/app_update_installer.dart';
import 'package:tsukuyomi_space_app/core/app_update_release.dart';
import 'package:tsukuyomi_space_app/core/app_update_service.dart';

const _tag = 'v0.6.12-beta.1';
final _bytes = utf8.encode('a verified native installer fixture');
final _hash = sha256.convert(_bytes).toString();
Map<String, Object?> _asset(String name, {int? size, String? digest}) => {
  'name': name,
  'state': 'uploaded',
  'size': size ?? _bytes.length,
  'browser_download_url': '$appDistributionOrigin/releases/$_tag/$name',
  'digest': digest == null ? null : 'sha256:$digest',
};
Map<String, Object?> _release({
  String tag = _tag,
  UpdatePlatform platform = UpdatePlatform.windows,
}) {
  final version = AppVersion.parse(tag)!;
  // A HAP carries the build number in its name, like the published artifacts.
  final file = platform == UpdatePlatform.ohos
      ? 'tsukuyomi-space-${version.base}-42-${platform.suffix}'
      : 'tsukuyomi-space-${version.base}-${platform.suffix}';
  return {
    'tag_name': tag,
    'draft': false,
    'prerelease': version.pre.isNotEmpty,
    'html_url': '$appRepository/releases/tag/$tag',
    'body': '- A useful improvement',
    'published_at': '2026-10-10T00:00:00Z',
    'assets': [
      for (final asset in [
        _asset(file, digest: _hash),
        _asset(platform.checksumsName, size: 200),
      ])
        {
          ...asset,
          'browser_download_url':
              '$appDistributionOrigin/releases/$tag/${asset['name']}',
        },
    ],
  };
}

AppUpdateRelease _parsed([UpdatePlatform platform = UpdatePlatform.windows]) =>
    AppUpdateRelease.parse(_release(platform: platform), platform)!;

class _Transport implements UpdateTransport {
  _Transport();
  Object catalog = [_release()];
  String? checksum;
  List<int> data = _bytes;
  int requests = 0;
  bool failed = false;
  Completer<void>? gate;
  @override
  Stream<List<int>> read(Uri url, UpdateCancellation token) async* {
    requests++;
    if (failed) throw const UpdateFailure('network');
    if (gate != null) await gate!.future;
    token.check();
    if (url == appReleasesApi) {
      yield utf8.encode(jsonEncode(catalog));
    } else if (url.path.endsWith('SHA256SUMS.txt')) {
      yield utf8.encode(checksum ?? '$_hash  ${_parsed().installer.name}\n');
    } else {
      yield data.sublist(0, data.length ~/ 2);
      token.check();
      yield data.sublist(data.length ~/ 2);
    }
  }
}

class _Installer implements UpdateInstaller {
  int calls = 0;
  UpdateInstallResult result = UpdateInstallResult.opened;
  @override
  Future<UpdateInstallResult> install(
    File file,
    UpdatePlatform platform,
  ) async {
    calls++;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('baked release version agrees with pubspec', () {
    final version = RegExp(
      r'^version: (.+)\+',
      multiLine: true,
    ).firstMatch(File('pubspec.yaml').readAsStringSync())![1];
    expect(AppVersion.parse(appReleaseTag)!.base, version);
  });
  test(
    'semantic versions compare numeric components and prerelease identifiers',
    () {
      final versions = [
        'v0.6.9-beta.1',
        'v0.6.10-alpha.1',
        'v0.6.10-beta.2',
        'v0.6.10-beta.10',
        'v0.6.10-rc.1',
        'v0.6.10',
        'v0.10.0',
        'v1.0.0',
      ];
      for (var i = 1; i < versions.length; i++) {
        expect(
          AppVersion.parse(versions[i])!
              .compareTo(AppVersion.parse(versions[i - 1])!),
          greaterThan(0),
        );
      }
      for (final invalid in [
        '0.06.1',
        'v1.0',
        'v1.2.3-beta.01',
        '../../1.0.0',
        'v1.0.0\n',
      ]) {
        expect(AppVersion.parse(invalid), isNull, reason: invalid);
      }
    },
  );
  test(
    'newest usable version selected with stable / preview channel rules',
    () {
      final catalog = [
        _release(tag: 'v0.6.11'),
        _release(tag: 'v0.6.12-beta.2'),
        _release(tag: 'v0.6.12-beta.10'),
      ];
      expect(
        selectAppUpdate(
          catalog,
          AppVersion.parse('0.6.10')!,
          UpdatePlatform.windows,
          previews: true,
        )!.tag,
        'v0.6.12-beta.10',
      );
      expect(
        selectAppUpdate(
          catalog,
          AppVersion.parse('0.6.10')!,
          UpdatePlatform.windows,
          previews: false,
        )!.tag,
        'v0.6.11',
      );
      expect(
        selectAppUpdate(
          catalog,
          AppVersion.parse('0.6.12')!,
          UpdatePlatform.windows,
          previews: true,
        ),
        isNull,
      );
      expect(
        selectAppUpdate(
          [_release(tag: 'v0.6.11-beta.1')],
          AppVersion.parse(appReleaseTag)!,
          UpdatePlatform.windows,
          previews: true,
        ),
        isNull,
      );
    },
  );
  for (final platform in UpdatePlatform.values) {
    test('select exact installer for ${platform.name}', () {
      final r = AppUpdateRelease.parse(_release(platform: platform), platform)!;
      expect(r.installer.name, endsWith(platform.suffix));
      expect(r.installer.url.host, 'downloads.yachiyo.hk');
      expect(r.checksums.name, platform.checksumsName);
    });
  }
  test('HarmonyOS release requires the HAP and its own checksum manifest', () {
    final hap = _release(platform: UpdatePlatform.ohos);
    expect(AppUpdateRelease.parse(hap, UpdatePlatform.ohos), isNotNull);
    // The generic manifest is not enough for HarmonyOS, and a HAP is not a
    // valid installer for the other platforms.
    final generic = {
      ...hap,
      'assets': [
        for (final asset in (hap['assets'] as List).cast<Map>())
          if (asset['name'] != 'OHOS-SHA256SUMS.txt')
            {...asset, 'name': 'SHA256SUMS.txt'}
          else
            asset,
      ],
    };
    expect(AppUpdateRelease.parse(generic, UpdatePlatform.ohos), isNull);
    expect(AppUpdateRelease.parse(hap, UpdatePlatform.windows), isNull);
    // Two HAPs for the same version are ambiguous and must be rejected.
    final ambiguous = {
      ...hap,
      'assets': [
        ...hap['assets'] as List,
        {
          ...(hap['assets'] as List).first as Map,
          'name': 'tsukuyomi-space-0.6.12-43-ohos-arm64-unsigned.hap',
        },
      ],
    };
    expect(AppUpdateRelease.parse(ambiguous, UpdatePlatform.ohos), isNull);
  });
  test('reject draft, mismatched repository, duplicates, missing checksums and malformed assets', () {
    final valid = _release();
    final assets = valid['assets'] as List;
    for (final bad in [
      {...valid, 'draft': true},
      {...valid, 'prerelease': false},
      {...valid, 'html_url': 'https://evil.example/releases/tag/$_tag'},
      {
        ...valid,
        'assets': [assets.first],
      },
      {
        ...valid,
        'assets': [...assets, assets.first],
      },
      {
        ...valid,
        'assets': [
          {...assets.first as Map, 'size': 0},
          assets.last,
        ],
      },
      {
        ...valid,
        'assets': [
          {...assets.first as Map, 'size': 3 * 1024 * 1024 * 1024},
          assets.last,
        ],
      },
      {
        ...valid,
        'assets': [
          {...assets.first as Map, 'state': 'new'},
          assets.last,
        ],
      },
      {
        ...valid,
        'assets': [
          {...assets.first as Map, 'digest': 'sha256:bad'},
          assets.last,
        ],
      },
      {
        ...valid,
        'assets': [
          {
            ...assets.first as Map,
            'browser_download_url': 'http://github.com/file.apk',
          },
          assets.last,
        ],
      },
    ]) {
      expect(AppUpdateRelease.parse(bad, UpdatePlatform.windows), isNull);
    }
  });
  test('SHA256SUMS exact filename and digest agreement required', () {
    final asset = _parsed().installer;
    expect(updateChecksum('$_hash *${asset.name}\n', asset), _hash);
    for (final source in [
      '',
      '$_hash  wrong.exe',
      '$_hash  ${asset.name}\n$_hash  ${asset.name}',
      '${'f' * 64}  ${asset.name}',
    ]) {
      expect(
        () => updateChecksum(source, asset),
        throwsA(isA<UpdateFailure>()),
      );
    }
  });
  test('reject untrusted download hosts, credentials, ports and insecure URLs', () {
    for (final value in [
      'http://downloads.yachiyo.hk/releases.json',
      'https://downloads.yachiyo.hk.evil.example/releases.json',
      'https://downloads.yachiyo.hk:444/releases.json',
      'https://user:secret@downloads.yachiyo.hk/releases.json',
      'file:///tmp/file',
      '$appDistributionOrigin/releases.json#fragment',
      '$appDistributionOrigin/releases.json?redirect=evil',
      '$appDistributionOrigin/private/file',
      '$appDistributionOrigin/releases/v1.0.0/../../secret',
      'https://github.com/file',
      'https://api.github.com/releases',
      'https://release-assets.githubusercontent.com/file?sig=public',
      'https://objects.githubusercontent.com/file',
    ]) {
      expect(
        DistributionUpdateTransport.trusted(Uri.parse(value)),
        false,
        reason: value,
      );
    }
    for (final value in [
      appReleasesApi.toString(),
      '$appDistributionOrigin/releases/v0.6.27-beta.1/SHA256SUMS.txt',
      '$appDistributionOrigin/releases/v0.6.27-beta.1/tsukuyomi-space-0.6.27-android-arm64-v8a.apk',
    ]) {
      expect(DistributionUpdateTransport.trusted(Uri.parse(value)), true);
    }
  });

  group('download and install pipeline', () {
    late Directory temp;
    late _Transport transport;
    late AppUpdateService service;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tsukuyomi-update-test-');
      transport = _Transport();
      service = AppUpdateService(
        transport: transport,
        cacheDirectory: () async => temp,
      );
    });
    tearDown(() async => temp.delete(recursive: true));
    test(
      'download verifies, reuses completed file and rechecks before install',
      () async {
        final states = <bool>[];
        final file = await service.download(
          _parsed(),
          UpdateCancellation(),
          (_, _, verifying) => states.add(verifying),
        );
        expect(await file.readAsBytes(), _bytes);
        expect(states, containsAll([false, true]));
        final first = transport.requests;
        await service.download(_parsed(), UpdateCancellation(), (_, _, _) {});
        expect(
          transport.requests,
          first + 1,
        ); // checksums only; installer reused
        await service.verify(file, _parsed(), UpdateCancellation());
        await file.writeAsBytes(List.filled(_bytes.length, 0));
        await expectLater(
          service.verify(file, _parsed(), UpdateCancellation()),
          throwsA(
            isA<UpdateFailure>().having((e) => e.code, 'code', 'integrity'),
          ),
        );
      },
    );
    test('corrupt, truncated and oversized downloads are deleted and never installed', () async {
      for (final data in [
        List.filled(_bytes.length, 0),
        _bytes.sublist(1),
        [..._bytes, 1],
      ]) {
        transport.data = data;
        await expectLater(
          service.download(_parsed(), UpdateCancellation(), (_, _, _) {}),
          throwsA(
            isA<UpdateFailure>().having((e) => e.code, 'code', 'integrity'),
          ),
        );
        expect(
          await Directory('${temp.path}/tsukuyomi-updates').list().toList(),
          isEmpty,
        );
      }
    });
    test('cancellation removes partial file', () async {
      final token = UpdateCancellation();
      await expectLater(
        service.download(_parsed(), token, (bytes, _, _) {
          if (bytes > 0) token.cancel();
        }),
        throwsA(
          isA<UpdateFailure>().having((e) => e.code, 'code', 'cancelled'),
        ),
      );
      expect(
        await Directory('${temp.path}/tsukuyomi-updates').list().toList(),
        isEmpty,
      );
    });
    test('symlink targets cannot be written or passed to installer', () async {
      final root = await Directory('${temp.path}/tsukuyomi-updates').create();
      final other = await File('${temp.path}/precious').writeAsString('keep');
      final link = await Link('${root.path}/${_parsed().installer.name}')
          .create(other.path);
      await expectLater(
        service.download(_parsed(), UpdateCancellation(), (_, _, _) {}),
        throwsA(isA<UpdateFailure>()),
      );
      expect(await other.readAsString(), 'keep');
      await expectLater(
        service.verify(File(link.path), _parsed(), UpdateCancellation()),
        throwsA(isA<UpdateFailure>()),
      );
    });
    test('public metadata is bounded and malformed JSON is rejected', () async {
      for (final catalog in [
        'x' * (1024 * 1024),
        {'message': 'not a release list'},
      ]) {
        transport.catalog = catalog;
        await expectLater(
          service.check(
            AppVersion.parse('0.6.10')!,
            UpdatePlatform.windows,
            previews: true,
            token: UpdateCancellation(),
          ),
          throwsA(isA<UpdateFailure>()),
        );
      }
    });
    test('daily background checks, version-specific dismissal, no automatic download', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var clock = DateTime(2026, 10, 10);
      final c = AppUpdateController(
        preferences: prefs,
        service: service,
        installedApp: () async => InstalledApp(
          AppVersion.parse('v0.6.11-beta.1')!,
          '17',
          UpdatePlatform.windows,
        ),
        now: () => clock,
      );
      addTearDown(c.dispose);
      await c.checkAutomatically();
      expect(c.notification, 1);
      expect(c.phase, AppUpdatePhase.available);
      expect(transport.requests, 1);
      expect(c.downloaded, isNull);
      await c.checkAutomatically();
      expect(transport.requests, 1);
      await c.remindLater();
      clock = clock.add(const Duration(days: 1));
      await c.checkAutomatically();
      expect(c.notification, 1);
      transport.catalog = [_release(tag: 'v0.6.13-beta.1')];
      clock = clock.add(const Duration(days: 1));
      await c.checkAutomatically();
      expect(c.notification, 2);
      // Closing an older popup must not dismiss a newly fetched release.
      await c.remindLater(tag: 'v0.6.12-beta.1');
      expect(prefs.getString('app-update.dismissed'), 'v0.6.12-beta.1');
      expect(c.release!.tag, 'v0.6.13-beta.1');
      await c.setAutomatic(false);
      clock = clock.add(const Duration(days: 1));
      await c.checkAutomatically();
      expect(transport.requests, 3);
    });
    test(
      'network failure uses one-hour backoff; manual check retries immediately',
      () async {
        SharedPreferences.setMockInitialValues({});
        final c = AppUpdateController(
          preferences: await SharedPreferences.getInstance(),
          service: service,
          installedApp: () async => InstalledApp(
            AppVersion.parse('0.6.10')!,
            '16',
            UpdatePlatform.windows,
          ),
        );
        addTearDown(c.dispose);
        transport.failed = true;
        await c.checkAutomatically();
        expect(c.error, 'network');
        await c.checkAutomatically();
        expect(transport.requests, 1);
        transport.failed = false;
        await c.check();
        expect(c.error, isNull);
        expect(c.hasUpdate, true);
      },
    );
    test('installation requires download, blocks tampering, and supports permission retry', () async {
      SharedPreferences.setMockInitialValues({});
      final installer = _Installer();
      final c = AppUpdateController(
        preferences: await SharedPreferences.getInstance(),
        service: service,
        installer: installer,
        installedApp: () async => InstalledApp(
          AppVersion.parse('0.6.10')!,
          '16',
          UpdatePlatform.windows,
        ),
      );
      addTearDown(c.dispose);
      await c.check();
      await c.install();
      expect(installer.calls, 0);
      await c.download();
      expect(c.phase, AppUpdatePhase.ready);
      await c.downloaded!.writeAsBytes(List.filled(_bytes.length, 0));
      await c.install();
      expect(installer.calls, 0);
      expect(c.error, 'integrity');
      await c.download();
      installer.result = UpdateInstallResult.permissionRequired;
      await c.install();
      expect(c.phase, AppUpdatePhase.permissionRequired);
      installer.result = UpdateInstallResult.opened;
      await c.install();
      expect(c.phase, AppUpdatePhase.opened);
      expect(installer.calls, 2);
    });
    test(
      'concurrent checks are coalesced and disposed work cannot publish',
      () async {
        SharedPreferences.setMockInitialValues({});
        final c = AppUpdateController(
          preferences: await SharedPreferences.getInstance(),
          service: service,
          installedApp: () async => InstalledApp(
            AppVersion.parse('0.6.10')!,
            '16',
            UpdatePlatform.windows,
          ),
        );
        transport.gate = Completer<void>();
        final first = c.check();
        await c.check();
        await Future<void>.delayed(Duration.zero);
        expect(transport.requests, 1);
        c.dispose();
        transport.gate!.complete();
        await first;
        expect(c.release, isNull);
      },
    );
  });
  test(
    'installed package info uses baked prerelease tag only for matching base',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Tsukuyomi',
        packageName: 'space.tsukuyomi.tsukuyomi_space_app',
        version: appReleaseTag.substring(1).split('-').first,
        buildNumber: '17',
        buildSignature: '',
      );
      final info = await InstalledApp.load();
      expect(info.version.value, appReleaseTag);
      PackageInfo.setMockInitialValues(
        appName: 'Tsukuyomi',
        packageName: 'space.tsukuyomi.tsukuyomi_space_app',
        version: '9.0.0',
        buildNumber: '90',
        buildSignature: '',
      );
      expect((await InstalledApp.load()).version.value, '9.0.0');
    },
  );
}
