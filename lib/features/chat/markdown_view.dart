import '../../ui/motion.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../core/api/adapters/adapter.dart';
import '../../ui/app_icons.dart';
import '../../ui/links.dart';
import 'code_preview.dart';

/// 模型回答的 Markdown 渲染：代码块（可复制）、LaTeX、链接、data: 图片。
class MarkdownView extends StatelessWidget {
  const MarkdownView(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  /// 标题等样式默认取自 Material 文字主题，深色模式下可能和背景同色（看不见），
  /// 这里统一按 miuix 配色给出。
  static GptMarkdownThemeData _theme(MiuixThemeData t) {
    final c = t.colors;
    TextStyle h(double size) => TextStyle(
      fontSize: size,
      height: 1.4,
      fontWeight: FontWeight.w600,
      color: c.onSurface,
    );
    return GptMarkdownThemeData(
      brightness: t.brightness,
      highlightColor: c.onSurface.withValues(alpha: 0.08),
      h1: h(22),
      h2: h(20),
      h3: h(18),
      h4: h(16),
      h5: h(15),
      h6: h(15),
      hrLineColor: c.dividerLine,
      hrLineThickness: 1,
      linkColor: c.primary,
      linkHoverColor: c.primary.withValues(alpha: 0.7),
      // 不在一级标题下自动加分隔线，避免版面太碎。
      autoAddDividerLineAfterH1: false,
      inlineCode: InlineCodeStyle(
        color: c.onSurface,
        backgroundColor: c.onSurface.withValues(alpha: 0.08),
        fontFamilyFallback: const [
          'Menlo',
          'Consolas',
          'Roboto Mono',
          'monospace',
        ],
      ),
      styleSheet: GptMarkdownStyleSheet(
        blockQuote: BlockQuoteStyle(
          barColor: c.primary.withValues(alpha: 0.5),
          textStyle: TextStyle(color: c.onSurfaceVariantSummary),
        ),
        table: TableStyle(
          borderColor: c.dividerLine,
          headerBackground: c.onSurface.withValues(alpha: 0.05),
          headerTextStyle: TextStyle(
            fontWeight: FontWeight.w600,
            color: c.onSurface,
          ),
          // 宽表格横向滚动，不撑出屏幕。
          overflow: TableOverflow.scroll,
        ),
        // 长公式横向滚动，不撑出卡片。
        latex: LatexStyle(
          scrollBlockHorizontally: true,
          textStyle: TextStyle(color: c.onSurface),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = MiuixTheme.of(context);
    final colors = theme.colors;
    return GptMarkdownTheme(
      gptThemeData: _theme(theme),
      child: GptMarkdown(
        text,
        // 模型常用 $...$ / $$...$$ 写公式。
        useDollarSignsForLatex: true,
        style: TextStyle(
          fontSize: 15,
          height: 1.6,
          color: color ?? colors.onSurface,
        ),
        // 回答里的链接与搜索来源一致：应用内浏览器打开。
        onLinkTap: (url, _) => openLink(url),
        codeBuilder: (context, name, code, closed) =>
            CodeBlock(language: name, code: code, closed: closed),
        imageBuilder: (context, url, width, height) {
          if (splitDataUrl(url) case final p?) {
            return Image.memory(
              base64Decode(p.base64),
              width: width,
              height: height,
            );
          }
          return Image.network(
            url,
            width: width,
            height: height,
            errorBuilder: (_, _, _) => MiuixText(
              url,
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
          );
        },
      ),
    );
  }
}

class CodeBlock extends StatelessWidget {
  const CodeBlock({
    super.key,
    required this.language,
    required this.code,
    this.closed = true,
  });

  final String language;
  final String code;

  /// 代码块已经结束（流式输出时还没结束的块不显示「预览」）。
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final dark = MiuixTheme.of(context).brightness == Brightness.dark;
    final preview = closed ? previewKindOf(language, code) : null;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: ShapeDecoration(
        color: dark ? const Color(0xFF1E1F22) : const Color(0xFFF3F4F6),
        shape: const MiuixSquircleBorder(cornerRadius: 12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 4, 0),
            child: Row(
              children: [
                Expanded(
                  child: MiuixText(
                    language.isEmpty ? 'code' : language,
                    fontSize: 12,
                    color: colors.onSurfaceVariantSummary,
                  ),
                ),
                if (preview case final kind?)
                  Tap(
                    onTap: () => openCodePreview(context, kind, code),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          MiuixIcon(
                            vector: AppIcons.play,
                            size: 14,
                            tint: colors.primary,
                          ),
                          const SizedBox(width: 4),
                          MiuixText('预览', fontSize: 12, color: colors.primary),
                        ],
                      ),
                    ),
                  ),
                Tap(
                  onTap: () => Clipboard.setData(ClipboardData(text: code)),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: MiuixIcon(
                      vector: AppIcons.copy,
                      size: 16,
                      tint: colors.onSurfaceVariantSummary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
            child: SelectableText(
              code,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontFamilyFallback: const [
                  'Consolas',
                  'Roboto Mono',
                  'monospace',
                ],
                fontSize: 13,
                height: 1.5,
                color: colors.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
