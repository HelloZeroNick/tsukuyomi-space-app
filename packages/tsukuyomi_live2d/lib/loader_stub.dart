import 'model.dart';

Future<Live2DModel> loadLive2D({
  String manifest = 'assets/live2d/character.model3.json',
  int maxTextureSize = 2048,
  String renderer = 'canvas',
}) => Future.error(UnsupportedError('Web 预览使用角色插画；Cubism Native 仅在原生应用运行。'));
