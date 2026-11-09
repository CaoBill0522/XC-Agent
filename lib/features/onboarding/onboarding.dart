import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/chat/conversation_mode.dart';
import '../../data/providers.dart';
import '../../l10n/language.dart';
import '../../l10n/tr.dart';
import '../../ui/app_icons.dart';
import '../../ui/motion.dart';
import '../channels/channels_page.dart';

/// 首次打开时的功能引导。已经配过渠道的老用户（升级上来）不再显示。
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({super.key, required this.child});

  final Widget child;

  static const doneKey = 'onboarded';

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  late bool _done =
      ref.read(prefsProvider).getBool(OnboardingGate.doneKey) ?? false;

  void _finish({bool addChannel = false}) {
    ref.read(prefsProvider).setBool(OnboardingGate.doneKey, true);
    setState(() => _done = true);
    if (addChannel) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const PresetPickerPage()));
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    final channels = ref.watch(channelsProvider);
    return channels.when(
      loading: () => ColoredBox(color: MiuixTheme.of(context).colors.surface),
      error: (_, _) => widget.child,
      data: (list) {
        if (list.isNotEmpty) {
          // 升级上来的老用户：已有渠道，直接进首页，并记下不再显示。
          ref.read(prefsProvider).setBool(OnboardingGate.doneKey, true);
          return widget.child;
        }
        return OnboardingPage(
          onSkip: _finish,
          onAddChannel: () => _finish(addChannel: true),
        );
      },
    );
  }
}

class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({
    super.key,
    required this.onSkip,
    required this.onAddChannel,
  });

  final VoidCallback onSkip;
  final VoidCallback onAddChannel;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final _pages = PageController();
  int _index = 0;

  static const _count = 4;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _next() {
    if (_index == _count - 1) {
      widget.onAddChannel();
      return;
    }
    _pages.nextPage(duration: Motion.medium, curve: Motion.curve);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(languageProvider);
    final colors = MiuixTheme.of(context).colors;
    final last = _index == _count - 1;
    return MiuixScaffold(
      content: (_) => Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedOpacity(
                      opacity: last ? 0 : 1,
                      duration: Motion.fast,
                      child: MiuixTextButton(
                        tr('跳过'),
                        onPressed: last ? () {} : widget.onSkip,
                      ),
                    ),
                  ),
                  Expanded(
                    child: PageView(
                      controller: _pages,
                      onPageChanged: (i) => setState(() => _index = i),
                      children: const [
                        _WelcomePage(),
                        _ModesPage(),
                        _FeaturesPage(),
                        _PrivacyPage(),
                      ],
                    ),
                  ),
                  _Dots(count: _count, index: _index),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
                    child: SizedBox(
                      width: double.infinity,
                      child: MiuixButton(
                        onPressed: _next,
                        colors: MiuixButtonDefaults.buttonColorsPrimary(
                          context,
                        ),
                        child: FadeSwitch(
                          switchKey: last,
                          animateSize: false,
                          alignment: Alignment.center,
                          child: MiuixText(
                            last ? tr('添加第一个渠道') : tr('下一步'),
                            color: colors.onPrimary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 44,
                    child: AnimatedOpacity(
                      opacity: last ? 1 : 0,
                      duration: Motion.fast,
                      child: MiuixTextButton(
                        tr('先随便看看'),
                        onPressed: last ? widget.onSkip : () {},
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Dots extends StatelessWidget {
  const _Dots({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: Motion.medium,
            curve: Motion.curve,
            margin: const EdgeInsets.symmetric(horizontal: 4),
            width: i == index ? 20 : 6,
            height: 6,
            decoration: BoxDecoration(
              color: i == index ? colors.primary : colors.dividerLine,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }
}

/// 一页引导：大图标、标题、说明，下面是若干条要点。
class _Page extends StatelessWidget {
  const _Page({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.items = const [],
    this.footer,
  });

  final MiuixVectorIcon icon;
  final String title;
  final String subtitle;
  final List<(MiuixVectorIcon, String, String)> items;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Container(
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: ShapeDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              shape: const MiuixSquircleBorder(cornerRadius: 18),
            ),
            child: MiuixIcon(vector: icon, size: 32, tint: colors.primary),
          ),
          const SizedBox(height: 24),
          MiuixText(
            title,
            fontSize: 28,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
          const SizedBox(height: 10),
          MiuixText(
            subtitle,
            fontSize: 16,
            color: colors.onSurfaceVariantSummary,
          ),
          const SizedBox(height: 28),
          for (final (i, (icon, t, d)) in items.indexed)
            AppearIn(
              key: ValueKey('$title-$i'),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2, right: 14),
                      child: MiuixIcon(
                        vector: icon,
                        size: 22,
                        tint: colors.primary,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MiuixText(
                            t,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                          const SizedBox(height: 2),
                          MiuixText(
                            d,
                            fontSize: 14,
                            color: colors.onSurfaceVariantSummary,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ?footer,
        ],
      ),
    );
  }
}

class _WelcomePage extends ConsumerWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = MiuixTheme.of(context).colors;
    final lang = ref.watch(languageProvider);
    final en = L10n.isEn;
    Widget chip(String label, AppLanguage value, bool selected) => Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: () => ref.read(languageProvider.notifier).set(value),
        child: AnimatedContainer(
          duration: Motion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: ShapeDecoration(
            color: selected ? colors.primary : colors.surfaceContainerHigh,
            shape: const StadiumBorder(),
          ),
          child: MiuixText(
            label,
            fontSize: 14,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? colors.onPrimary : colors.onSurface,
          ),
        ),
      ),
    );
    return _Page(
      icon: AppIcons.messages,
      title: tr('欢迎使用 XCAgent'),
      subtitle: tr(
        '用你自己的 API Key，在一个 App 里使用 GPT、Claude、Gemini、DeepSeek 等各家模型。',
      ),
      items: [
        (AppIcons.layers, tr('多渠道接入'), tr('官方接口和中转站都能接，同一个模型可以在多个渠道间轮询、自动切换')),
        (
          AppIcons.community,
          tr('OpenAI / Anthropic 两种格式'),
          tr('按厂商文档填地址和 Key 就行，模型列表自动拉取'),
        ),
      ],
      footer: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MiuixText(
              'Language / 语言',
              fontSize: 13,
              color: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                chip('简体中文', AppLanguage.zh, !en),
                chip('English', AppLanguage.en, en),
                if (lang == AppLanguage.system)
                  MiuixText(
                    tr('（当前跟随系统）'),
                    fontSize: 13,
                    color: colors.onSurfaceVariantSummary,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModesPage extends StatelessWidget {
  const _ModesPage();

  @override
  Widget build(BuildContext context) {
    MiuixVectorIcon iconOf(ConversationMode m) => switch (m) {
      ConversationMode.single => AppIcons.reply,
      ConversationMode.multi => AppIcons.replyAll,
      ConversationMode.chain => AppIcons.sort,
      ConversationMode.judge => AppIcons.notes,
      ConversationMode.debate => AppIcons.merge,
    };
    return _Page(
      icon: AppIcons.replyAll,
      title: tr('五种对话方式'),
      subtitle: tr('新建对话时选择；同一个问题可以让多个模型一起想。'),
      items: [
        for (final m in ConversationMode.values)
          (iconOf(m), m.label, m.description),
      ],
    );
  }
}

class _FeaturesPage extends StatelessWidget {
  const _FeaturesPage();

  @override
  Widget build(BuildContext context) {
    return _Page(
      icon: AppIcons.tools,
      title: tr('顺手的小功能'),
      subtitle: tr('聊天时这些都可以直接用。'),
      items: [
        (AppIcons.mic, tr('按住说话'), tr('输入框空着时长按，松手发送；上滑取消或转成文字')),
        (AppIcons.world, tr('联网搜索与工具'), tr('原生联网搜索；模型还能读网页、用计算器、连接 MCP 服务器')),
        (AppIcons.image, tr('图片和文件'), tr('识图、生图，PDF 和代码文件直接发给模型')),
        (AppIcons.reply, tr('选中文字追问'), tr('长按回答选中一段，在当前对话或新对话里继续问')),
        (AppIcons.play, tr('代码预览'), tr('回答里的 HTML、SVG、流程图可以直接预览')),
      ],
    );
  }
}

class _PrivacyPage extends StatelessWidget {
  const _PrivacyPage();

  @override
  Widget build(BuildContext context) {
    return _Page(
      icon: AppIcons.lock,
      title: tr('数据在你手里'),
      subtitle: tr('没有账号，也没有我们的服务器。'),
      items: [
        (AppIcons.lock, tr('只存在本机'), tr('对话在本地数据库，API Key 在系统钥匙串，只发给你配置的模型接口')),
        (
          AppIcons.cloud,
          tr('可选 iCloud 同步'),
          tr('在设置 → 数据里打开，iPhone、iPad、Mac 之间同步'),
        ),
        (AppIcons.show, tr('应用锁'), tr('Face ID / 指纹解锁，切到后台时自动遮住内容')),
      ],
    );
  }
}
