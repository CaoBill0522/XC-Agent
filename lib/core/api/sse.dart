import 'dart:async';
import 'dart:convert';

class SseEvent {
  const SseEvent(this.event, this.data);

  /// `event:` 字段（OpenAI Chat 没有，Responses / Anthropic 有）。
  final String? event;
  final String data;

  bool get isDone => data.trim() == '[DONE]';
}

/// 把字节流解析成 SSE 事件。兼容 `\r\n`、多行 data、注释行（`:` 开头）。
Stream<SseEvent> parseSse(Stream<List<int>> bytes) async* {
  String? event;
  final data = StringBuffer();
  var hasData = false;

  SseEvent? flush() {
    if (!hasData) {
      event = null;
      return null;
    }
    final e = SseEvent(event, data.toString());
    event = null;
    data.clear();
    hasData = false;
    return e;
  }

  final lines = bytes
      .cast<List<int>>()
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  await for (final line in lines) {
    if (line.isEmpty) {
      if (flush() case final e?) yield e;
      continue;
    }
    if (line.startsWith(':')) continue;
    final idx = line.indexOf(':');
    final field = idx < 0 ? line : line.substring(0, idx);
    var value = idx < 0 ? '' : line.substring(idx + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'event':
        event = value;
      case 'data':
        if (hasData) data.write('\n');
        data.write(value);
        hasData = true;
    }
  }
  if (flush() case final e?) yield e;
}
