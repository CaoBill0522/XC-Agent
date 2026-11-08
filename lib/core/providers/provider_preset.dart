import 'dart:convert';

import 'package:flutter/services.dart';

import '../api/protocol.dart';

class PresetEndpoint {
  const PresetEndpoint(this.protocol, this.baseUrl);

  final ApiProtocol protocol;
  final String baseUrl;
}

/// 厂商预设，来自 `assets/presets/providers.json`。
class ProviderPreset {
  const ProviderPreset({
    required this.id,
    required this.name,
    required this.endpoints,
    required this.fallbackModels,
  });

  final String id;
  final String name;

  /// 支持的协议及对应地址，第一项为默认。
  final List<PresetEndpoint> endpoints;
  final List<String> fallbackModels;

  static const customId = 'custom';

  bool get isCustom => id == customId;
  PresetEndpoint get defaultEndpoint => endpoints.first;

  PresetEndpoint? endpointFor(ApiProtocol protocol) {
    for (final e in endpoints) {
      if (e.protocol == protocol) return e;
    }
    return null;
  }

  factory ProviderPreset.fromJson(Map<String, dynamic> json) {
    return ProviderPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      endpoints: [
        for (final e in json['endpoints'] as List)
          PresetEndpoint(
            ApiProtocol.fromId(e['protocol'] as String),
            e['baseUrl'] as String,
          ),
      ],
      fallbackModels: [
        for (final m in (json['fallbackModels'] as List? ?? const []))
          m as String,
      ],
    );
  }

  static List<ProviderPreset> parseAll(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    return [
      for (final p in json['presets'] as List)
        ProviderPreset.fromJson(p as Map<String, dynamic>),
    ];
  }

  static Future<List<ProviderPreset>> load([AssetBundle? bundle]) async {
    final source = await (bundle ?? rootBundle).loadString(
      'assets/presets/providers.json',
    );
    return parseAll(source);
  }
}
