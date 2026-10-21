// WeatherFusion MCP integration for Infer.
//
// Wires the ecosystem's WeatherFusion MCP server (SSE transport, Supabase JWT
// auth) into Kelivo's existing McpProvider instead of re-implementing an MCP
// client. Kelivo already supports SSE + custom headers, which is exactly the
// shape the WeatherFusion server exposes.
//
// Copyright (C) Infer contributors. AGPL-3.0 (inherited from Kelivo).

import 'dart:convert';

import 'package:Kelivo/core/providers/mcp_provider.dart';

/// Canonical endpoints for the wider Infer ecosystem.
///
/// Centralized so a future Cloudflare Workers deployment can be swapped in
/// exactly one place.
class EcosystemEndpoints {
  const EcosystemEndpoints._();

  /// WeatherFusion MCP server (Render free tier: wakes in ~60s when cold).
  static const String weatherFusionSse =
      'https://weatherfusion-mcp.onrender.com/sse';

  /// Liveness probe, used to tell "asleep" apart from "broken".
  static const String weatherFusionHealth =
      'https://weatherfusion-mcp.onrender.com/health';

  /// Shared Supabase project for the whole ecosystem.
  static const String supabaseUrl = 'https://baujyogvccnplzdqwtvc.supabase.co';
}

/// Reachability state of a remote ecosystem service.
enum ServiceHealth { online, waking, degraded, notConfigured }

/// Registers WeatherFusion with Kelivo's MCP manager.
///
/// Deliberately reuses [McpProvider] rather than shipping a second MCP client:
/// Kelivo already implements SSE + custom headers + OAuth + tool approval,
/// which is strictly more than Infer needs today and avoids two competing
/// transports in one binary.
class EcosystemMcpRegistrar {
  EcosystemMcpRegistrar({required this.mcp});

  final McpProvider mcp;

  /// Name shown in Infer's MCP settings list.
  static const String serverName = 'WeatherFusion';

  /// Ensures the server exists and carries a fresh bearer token.
  ///
  /// Idempotent and safe to call on every app start and after every sign-in.
  Future<String?> ensureWeatherFusionRegistered({String? bearerToken}) async {
    await mcp.loaded;

    final matches =
        mcp.servers.where((s) => s.name == serverName).toList(growable: false);

    if (matches.isNotEmpty) {
      final existing = matches.first;
      final want = (bearerToken != null && bearerToken.isNotEmpty)
          ? 'Bearer $bearerToken'
          : null;
      final have = existing.headers['Authorization'];
      if (want != null && want != have) {
        await mcp.updateServer(
          existing.copyWith(
            enabled: true,
            url: EcosystemEndpoints.weatherFusionSse,
            headers: {...existing.headers, 'Authorization': want},
          ),
        );
      }
      return existing.id;
    }

    // Never block the UI on a cold start: connect happens in the background
    // and Kelivo renders its own connection state.
    return mcp.addServer(
      enabled: true,
      name: serverName,
      transport: McpTransportType.sse,
      url: EcosystemEndpoints.weatherFusionSse,
      headers: {
        if (bearerToken != null && bearerToken.isNotEmpty)
          'Authorization': 'Bearer $bearerToken',
      },
    );
  }

  /// The tools WeatherFusion exposes, for the ecosystem status screen.
  static const List<({String name, String description})> weatherFusionTools = [
    (name: 'get_current_weather', description: 'Live conditions right now'),
    (name: 'get_forecast', description: 'Hourly and daily forecast'),
    (name: 'compare_providers', description: 'Same reading across providers'),
    (name: 'get_confidence', description: 'Cross-provider confidence score'),
    (name: 'get_alerts', description: 'Official severe-weather alerts (US)'),
  ];

  /// Renders a tool result for the transcript.
  static String renderToolResult(Object? result) {
    if (result == null) return '(no result)';
    if (result is String) return result;
    try {
      return const JsonEncoder.withIndent('  ').convert(result);
    } catch (_) {
      return result.toString();
    }
  }
}
