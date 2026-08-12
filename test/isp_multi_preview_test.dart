import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:debug_tool_set/providers/isp_studio_state.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-preview node buffer isolation tests', () {
    test('Multiple preview nodes receive independent preview images', () async {
      final state = IspStudioState.empty();

      // Create a test RGB image file (2x2 pixels)
      final tempFile = File('${Directory.systemTemp.path}/test_multi_preview.png');
      // Simple 2x2 PNG or mock image
      // We can use an existing image or create raw RGBA bytes turned into image file
      final imageSourceId = state.graph.addNode('image_source', 0, 0);
      final splitterId = state.graph.addNode('rgb_splitter', 200, 0);

      final prevRId = state.graph.addNode('preview', 400, -100);
      final prevGId = state.graph.addNode('preview', 400, 0);
      final prevBId = state.graph.addNode('preview', 400, 100);
      final prevRgbId = state.graph.addNode('preview', 200, -200);

      // Create a temporary PNG image using Flutter's image painting or file
      // Actually image_source loads an image file; let's point to high_saturation_test.png in G:/DebugToolSet/IspFlow/ if it exists, or create one
      final pngPath = File('G:/DebugToolSet/IspFlow/high_saturation_test.png').existsSync()
          ? 'G:/DebugToolSet/IspFlow/high_saturation_test.png'
          : 'test/test_data/sample.png';

      state.setParam(imageSourceId, 'filePath', pngPath);

      // Connect image_source -> rgb_splitter
      expect(state.graph.connect(imageSourceId, 'out_rgb', splitterId, 'in'), isNull);
      // Connect image_source -> prevRgbId
      expect(state.graph.connect(imageSourceId, 'out_rgb', prevRgbId, 'in'), isNull);

      // Connect splitter outputs -> mono previews
      expect(state.graph.connect(splitterId, 'out_r', prevRId, 'in_mono'), isNull);
      expect(state.graph.connect(splitterId, 'out_g', prevGId, 'in_mono'), isNull);
      expect(state.graph.connect(splitterId, 'out_b', prevBId, 'in_mono'), isNull);

      await state.runPreview();

      // Verify all 4 preview nodes have images in previewImages map
      expect(state.previewImages.length, 4);
      expect(state.previewImages[prevRgbId], isNotNull);
      expect(state.previewImages[prevRId], isNotNull);
      expect(state.previewImages[prevGId], isNotNull);
      expect(state.previewImages[prevBId], isNotNull);

      // Each preview image should be a distinct ui.Image object instance
      final imgRgb = state.previewImages[prevRgbId]!;
      final imgR = state.previewImages[prevRId]!;
      final imgG = state.previewImages[prevGId]!;
      final imgB = state.previewImages[prevBId]!;

      expect(identical(imgRgb, imgR), isFalse);
      expect(identical(imgR, imgG), isFalse);
      expect(identical(imgG, imgB), isFalse);

      if (tempFile.existsSync()) {
        await tempFile.delete();
      }
    });
  });
}
