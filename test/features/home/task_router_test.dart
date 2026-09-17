import 'package:flutter_test/flutter_test.dart';
import 'package:solab/features/home/services/task_router.dart';

void main() {
  group('TaskRouter 意图分类', () {
    test('APK 修改意图', () {
      final r = TaskRouter.route('帮我把这个apk去广告');
      expect(r['intent'], 'solab_apk');
      expect(
        (r['recommendedTools'] as List).contains('patch_apk_dex_methods'),
        isTrue,
      );
      expect(
        (r['recommendedTools'] as List),
        isNot(contains('get_apk_knowledge')),
      );
      expect((r['memoryToCheck'] as List), contains('apk_note_read'));
    });

    test('会员任务先分析，不直接进入补丁', () {
      final r = TaskRouter.route('解锁这个 APK 的会员');
      final tools = r['recommendedTools'] as List;
      expect(tools, contains('analyze_apk_workspace'));
      expect(tools, isNot(contains('patch_apk_dex_methods')));
    });

    test('会员和广告任务同时保留两个执行轨道', () {
      final r = TaskRouter.route('把这个 APK 解锁会员并去广告');
      final tools = r['recommendedTools'] as List;
      expect(tools, contains('analyze_apk_workspace'));
      expect(tools, contains('dex_search'));
      expect(tools, contains('patch_apk_dex_methods'));
      expect(tools, contains('patch_apk_manifest'));
      expect(r['requiredSkills'], contains('apk_apply_patch'));
    });

    test('逆向混淆任务启用核心逆向技能', () {
      final r = TaskRouter.route('分析 APK 中的混淆代码和方法调用');
      expect(r['requiredSkills'], contains('apk_reverse_playbook'));
      expect(r['requiredSkills'], isNot(contains('apk_apply_patch')));
    });

    test('SO 分析意图', () {
      final r = TaskRouter.route('分析这个 so 的加密函数交叉引用');
      expect(r['intent'], 'so_analysis');
      expect((r['recommendedTools'] as List).contains('so_analyze'), isTrue);
      expect((r['recommendedTools'] as List), contains('get_apk_knowledge'));
    });

    test('Flutter 分析意图', () {
      final r = TaskRouter.route('分析这个 flutter 包的 libapp');
      expect(r['intent'], 'flutter_analysis');
      expect((r['recommendedTools'] as List).contains('so_analyze'), isTrue);
    });

    test('文件操作意图', () {
      final r = TaskRouter.route('把分析结果写成 md 文档放到工作目录');
      expect(r['intent'], 'file_ops');
      expect((r['recommendedTools'] as List).contains('file'), isTrue);
    });

    test('压缩解压意图', () {
      final r = TaskRouter.route('把工作目录打包成 zip');
      expect(r['intent'], 'file_ops');
      expect((r['recommendedTools'] as List).contains('file'), isTrue);
    });

    test('未接入的脱壳能力不暴露工具', () {
      final r = TaskRouter.route('给这个加固包脱壳');
      expect(r['intent'], 'chat');
      expect((r['recommendedTools'] as List), isEmpty);
    });

    test('通用问答意图', () {
      final r = TaskRouter.route('今天天气怎么样');
      expect(r['intent'], 'chat');
      expect((r['recommendedTools'] as List), isEmpty);
    });

    test('空目标', () {
      final r = TaskRouter.route('');
      expect(r['intent'], 'chat');
    });
  });
}
