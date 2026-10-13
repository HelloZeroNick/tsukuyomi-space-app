import 'package:flutter_test/flutter_test.dart';

import 'support/live2d_render_probe.dart';

void main() {
  testWidgets(
    'async model snapshots preserve masks, opacity and destination blends',
    (tester) async {
      final result = (await tester.runAsync(
        () => probeLive2DBatching(asynchronous: true),
      ))!;
      expect(result['max_channel_delta'], lessThanOrEqualTo(2));
      expect(result['changed_bytes'], greaterThan(0));
    },
  );
  testWidgets('combined vertices split before overflowing 16-bit indices', (
    tester,
  ) async {
    final result = (await tester.runAsync(probeLive2DBatchIndexLimit))!;
    expect(result['different_bytes'], 0);
    expect(result['direct_calls'], 3);
    expect(result['batch_calls'], 2);
    expect(result['batched_meshes'], 2);
  });
  testWidgets(
    'mesh batches preserve pixels and release changing material runs',
    (tester) async {
      final result = (await tester.runAsync(probeLive2DBatching))!;
      expect(result['max_channel_delta'], lessThanOrEqualTo(2));
      expect(result['changed_bytes'], greaterThan(0));
      final runs = (result['runs'] as List).cast<Map>();
      for (final run in runs.where((r) => r['phase'] == 0)) {
        expect(run['batch_calls'], lessThan(run['direct_calls'] as int));
        expect(run['batched_meshes'], greaterThan(12));
      }
      for (final run in runs.where((r) => r['phase'] >= 3)) {
        expect(run['batch_calls'], run['direct_calls']);
        expect(run['batched_meshes'], 0);
      }
      for (final run in runs.where((r) => r['phase'] == 6)) {
        expect(run['batch_calls'], 0);
        expect(run['retained_bytes'], 0);
      }
    },
  );
  testWidgets(
    'transparent margins keep fine details sharp; crop follows deformed geometry',
    (tester) async {
      final result = (await tester.runAsync(probeLive2DCroppedDetail))!;
      expect(result['passes'], [0, 1]);
      expect(result['different_bytes'], 0);
      expect(result['before'][3], 255);
      expect(result['after'], [0, 0, 0, 0]);
    },
  );
  testWidgets('tint shader preserves UV mapping and premultiplied alpha', (
    tester,
  ) async {
    final result = (await tester.runAsync(probeLive2DShaderUvs))!;
    for (var pixel = 0; pixel < 4; pixel++) {
      for (var channel = 0; channel < 4; channel++) {
        expect(
          result['shader']![pixel][channel],
          closeTo(result['image']![pixel][channel], 2),
        );
      }
    }
  });
  testWidgets('bounded passes preserve masks, tint and destination blends', (
    tester,
  ) async {
    final actual = (await tester.runAsync(probeLive2DBoundedPasses))!;
    for (var channel = 0; channel < 4; channel++) {
      expect(
        actual['tint']['direct'][channel],
        closeTo([50, 74, 73, 255][channel], 2),
      );
    }
    for (final entry in actual.entries) {
      expect(entry.value['passes'], greaterThan(0), reason: entry.key);
      expect(entry.value['pixels'], lessThanOrEqualTo(8192));
      for (var channel = 0; channel < 4; channel++) {
        expect(
          entry.value['bounded'][channel],
          closeTo(entry.value['direct'][channel], 2),
          reason: '${entry.key} channel $channel',
        );
      }
    }
  });
  testWidgets(
    'animated opacity attenuates normal and masked additive highlights',
    (tester) async {
      final actual = (await tester.runAsync(probeLive2DOpacity))!;
      for (final entry in expectedLive2DOpacity.entries) {
        for (var channel = 0; channel < 4; channel++) {
          expect(
            actual[entry.key]![channel],
            closeTo(entry.value[channel], 2),
            reason: '${entry.key} channel $channel',
          );
        }
      }
    },
  );
}
