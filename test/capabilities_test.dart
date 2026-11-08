import 'package:agent/core/models/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const v = ModelCapability.vision;
  const g = ModelCapability.imageGen;
  const r = ModelCapability.reasoning;

  ModelProfile p(String id) => inferModelProfile(id);

  test('类型：嵌入 / 语音 / 生图默认不当对话模型', () {
    expect(p('text-embedding-3-large').kind, ModelKind.embedding);
    expect(p('whisper-1').kind, ModelKind.audio);
    expect(p('gpt-4o-mini-tts').kind, ModelKind.audio);
    expect(p('omni-moderation-latest').kind, ModelKind.other);
    expect(p('dall-e-3').kind, ModelKind.image);
    expect(p('cogview-4').kind, ModelKind.image);
    expect(p('text-embedding-3-large').selectedByDefault, isFalse);
    expect(p('dall-e-3').selectedByDefault, isTrue);
  });

  test('识图', () {
    for (final id in [
      'gpt-4o',
      'gpt-4.1-mini',
      'gpt-5',
      'o3',
      'claude-sonnet-4-5',
      'claude-3-haiku-20240307',
      'grok-4',
      'glm-4.5v',
      'qwen-vl-max',
      'openai/gpt-4o',
    ]) {
      expect(p(id).capabilities, contains(v), reason: id);
    }
    for (final id in [
      'deepseek-chat',
      'deepseek-v4-flash',
      'glm-4.5',
      'gpt-3.5-turbo',
      'o1-mini',
      'claude-2.1',
    ]) {
      expect(p(id).capabilities, isNot(contains(v)), reason: id);
    }
  });

  test('生图', () {
    expect(p('gpt-image-1').capabilities, {g, v});
    expect(p('dall-e-3').capabilities, {g});
    expect(p('grok-2-image-1212').kind, ModelKind.image);
    final gemini = p('gemini-2.5-flash-image');
    expect(gemini.kind, ModelKind.chat);
    expect(gemini.capabilities, containsAll([g, v]));
    expect(p('gpt-4o').capabilities, isNot(contains(g)));
  });

  test('推理', () {
    for (final id in [
      'o1',
      'o3-mini',
      'o4-mini',
      'gpt-5-mini',
      'deepseek-reasoner',
      'claude-sonnet-4-5',
      'claude-3-7-sonnet-latest',
      'claude-opus-4-1',
      'gemini-2.5-pro',
      'glm-4.5',
      'glm-5',
      'qwq-32b',
      'grok-4',
      'grok-3-mini',
    ]) {
      expect(p(id).capabilities, contains(r), reason: id);
    }
    for (final id in [
      'gpt-4o',
      'deepseek-chat',
      'claude-3-5-sonnet-latest',
      'glm-4-plus',
      'grok-3',
    ]) {
      expect(p(id).capabilities, isNot(contains(r)), reason: id);
    }
  });

  test('能力编码往返，未知值忽略', () {
    expect(ModelCapability.decode(ModelCapability.encode({v, r})), {v, r});
    expect(ModelCapability.decode('["vision","bogus"]'), {v});
    expect(ModelCapability.decode('not json'), isEmpty);
  });
}
