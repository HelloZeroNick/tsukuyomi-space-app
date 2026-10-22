import 'package:flutter/material.dart';

import '../../core/site_localization.dart';
import '../settings/settings_dialog.dart';
import 'room_controller.dart';

Future<void> showRoomHelp(
  BuildContext context,
  RoomController controller, {
  required ValueChanged<String> onGo,
  required VoidCallback onDiary,
}) async {
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const SiteText('开始使用与发现功能'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SiteText(
                '先和八千代说句话',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              const SiteText(
                '① 选择聊天服务 → ② 测试并保存 → ③ 发送第一句话。收到完整回复，才算完成首次对话。语音可以稍后开启。',
                style: TextStyle(height: 1.7),
              ),
              if (controller.settings.demo)
                const SiteText('当前是离线演示，连接模型后才能进行真实对话。'),
              TextButton(
                onPressed: () => Navigator.pop(context, 'setup'),
                child: const SiteText('查看分步配置'),
              ),
              const Divider(),
              for (final item in const [
                ('/game', '辉夜快跑', '跟着音乐跑一局，查看键盘或触屏操作。'),
                ('/live2d', 'Live2D 舞台', '先试表情和动作，无需聊天模型；AI 演出与语音另行配置。'),
                ('/plaza', '月读广场', '看看同好在聊什么，登录后留言、回复或参与话题。'),
                ('/wiki', '作品百科', '查找角色、故事与音乐，继续回味作品。'),
                ('/gallery', '公开图库', '浏览大家分享的图片。'),
                ('/growth', '月契成长', '查看签到、任务与等级；等级与日记好感度分开记录。'),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: SiteText(item.$2),
                  subtitle: SiteText(item.$3),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.pop(context, item.$1),
                ),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const SiteText('好感度为什么没有变化？'),
                children: [
                  const SiteText(
                    '好感度来自当前日记存档，不按消息条数或点击角色次数自动增加。结束聊天并成功生成、保存日记后，会记录本次好感度，也可能保持不变。导入或同步存档后，数值可能改变。',
                    style: TextStyle(height: 1.7),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context, 'diary'),
                    child: const SiteText('查看日记与当前存档'),
                  ),
                ],
              ),
              const ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: SiteText('有文字，但角色没有反应？'),
                children: [
                  SiteText(
                    '文字、角色动作与语音分别运行。先等角色加载完成，在舞台试一次点头；仍无反应时查看加载提示。声音需要单独配置，不是每条文字都会带动作。',
                    style: TextStyle(height: 1.7),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const SiteText('返回房间'),
        ),
      ],
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'setup') {
    await showRoomSettings(context, controller, guidedSetup: true);
  } else if (action == 'diary') {
    onDiary();
  } else {
    onGo(action);
  }
}
