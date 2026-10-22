// Infer core — the ecosystem's agent entry point.
//
// Infer is not a chat app with weather bolted on; it is the *client* for a
// personal agent ecosystem. This file is the seam where a conversation stops
// being "talk to a model" and becomes "talk to an agent that can act".
//
// Design decision (important): this file does NOT implement a tool-calling
// loop. Kelivo already has a battle-tested one in
// `core/services/api/generation/tool_loop_runner.dart`, plus per-provider
// protocol shaping for OpenAI/Claude/Gemini. Writing a second loop here would
// mean two code paths that drift apart — exactly what Infer's ecosystem layer
// is supposed to prevent.
//
// What this file *does* own:
//   1. One canonical handler that resolves a tool name to the right ecosystem
//      service, so callers never hand-roll a provider/adapter per service.
//   2. Ecosystem service enumeration + readiness, so the UI can say what the
//      agent can actually do right now instead of guessing.
//   3. A forward-compatible facade (`InferCore`) that the rest of Infer talks
//      to, so swapping the underlying loop later touches one file.
//
// Copyright (C) Infer contributors. AGPL-3.0 (inherited from Kelivo).

import 'dart:async';

import 'package:Kelivo/core/providers/assistant_provider.dart';
import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/core/services/chat/chat_service.dart';
import 'package:Kelivo/core/services/mcp/mcp_tool_service.dart';
import 'package:Kelivo/utils/mcp_structured_image.dart';

import 'weatherfusion_mcp.dart';

/// A service Infer can drive through tool calls.
class EcosystemService {
  const EcosystemService({
    required this.id,
    required this.displayName,
    required this.description,
    required this.serverName,
    required this.tools,
    required this.requiredScope,
  });

  /// Stable id used in logs, analytics, and future per-service toggles.
  final String id;

  /// Human label for the ecosystem screen.
  final String displayName;

  /// One line, shown under the label.
  final String description;

  /// MCP server name as registered in [McpProvider]. This is the join key
  /// between this catalogue and the live server list.
  final String serverName;

  /// Tool names this service exposes, for capability display.
  final List<String> tools;

  /// Supabase custom-claim scope required to call it. Null = no auth needed.
  final String? requiredScope;
}

/// Readiness of one service, resolved against the live MCP provider.
enum ServiceReadiness {
  /// Registered and connected — tools will work.
  ready,

  /// Registered but not connected (cold start, or connection failed).
  unreachable,

  /// Not registered with MCP at all yet.
  notRegistered,
}

/// Resolved status for one service, for display.
class ServiceStatus {
  const ServiceStatus({
    required this.service,
    required this.readiness,
    this.serverId,
    this.error,
  });

  final EcosystemService service;
  final ServiceReadiness readiness;
  final String? serverId;
  final String? error;

  bool get isReady => readiness == ServiceReadiness.ready;
}

/// The catalogue of ecosystem services Infer knows about.
///
/// Adding a service = adding one entry here plus a registrar method that
/// knows how to register it. Nothing else in the app needs to change, which
/// is the whole point of the seam.
class EcosystemRegistry {
  const EcosystemRegistry._();

  static final List<EcosystemService> services = [
    EcosystemService(
      id: 'weatherfusion',
      displayName: 'WeatherFusion',
      description: 'Live conditions, forecasts and severe-weather alerts',
      serverName: EcosystemMcpRegistrar.serverName,
      tools: [
        for (final t in EcosystemMcpRegistrar.weatherFusionTools) t.name,
      ],
      requiredScope: 'weatherfusion:read',
    ),
  ];

  /// Look up a service by its MCP server name.
  static EcosystemService? byServerName(String serverName) {
    for (final s in services) {
      if (s.serverName == serverName) return s;
    }
    return null;
  }

  /// Every tool name Infer can currently offer, across all services.
  ///
  /// Used to answer "what can the agent do?" without connecting anything.
  static Set<String> get allToolNames => {
    for (final s in services) ...s.tools,
  };
}

/// Result of one tool invocation, normalized for the transcript.
///
/// Deliberately a thin wrapper over [McpToolResult] rather than a parallel
/// type: the value already carries markdown + image URIs + metadata, and
/// duplicating that shape is how two renderers appear and diverge.
class InferToolOutcome {
  const InferToolOutcome({
    required this.toolName,
    required this.ok,
    required this.markdown,
    this.imageUris = const [],
    this.error,
  });

  final String toolName;
  final bool ok;
  final String markdown;
  final List<String> imageUris;

  /// Present when [ok] is false. Already human-readable.
  final String? error;

  /// Metadata to persist alongside the message, matching Kelivo's format.
  Map<String, dynamic>? get metadata =>
      imageUris.isEmpty ? null : mcpResultMetadata(imageUris);

  static InferToolOutcome fromMcp(String toolName, McpToolResult result) {
    return InferToolOutcome(
      toolName: toolName,
      ok: true,
      markdown: result.markdown,
      imageUris: result.imageUris,
    );
  }

  static InferToolOutcome failure(String toolName, String error) {
    return InferToolOutcome(
      toolName: toolName,
      ok: false,
      markdown: '**$toolName** failed: $error',
      error: error,
    );
  }
}

/// Facade over the ecosystem side of Infer.
///
/// The rest of the app talks to this, never to [McpProvider] directly, so the
/// transport choice (MCP today, something else later) stays swappable.
class InferCore {
  InferCore({
    required this.mcp,
    required this.tools,
    required this.chat,
    required this.assistants,
  });

  final McpProvider mcp;
  final McpToolService tools;

  /// Consulted for per-conversation MCP server selection. Read-only here.
  final ChatService chat;

  /// Consulted for per-assistant MCP server selection. Read-only here.
  final AssistantProvider assistants;

  // ---------------------------------------------------------------------
  // Status
  // ---------------------------------------------------------------------

  /// Resolves every registered ecosystem service against live MCP state.
  ///
  /// Cheap and synchronous — reads provider state, does not probe the network.
  /// Callers that want a live probe should use the ecosystem page's health
  /// check instead; this answers "is it wired up?", not "is it awake?".
  List<ServiceStatus> statuses() {
    final byName = <String, McpServerConfig>{
      for (final s in mcp.servers) s.name: s,
    };
    final connectedIds = mcp.connectedServers.map((s) => s.id).toSet();

    return [
      for (final service in EcosystemRegistry.services)
        _statusFor(service, byName[service.serverName], connectedIds),
    ];
  }

  ServiceStatus _statusFor(
    EcosystemService service,
    McpServerConfig? server,
    Set<String> connectedIds,
  ) {
    if (server == null) {
      return ServiceStatus(
        service: service,
        readiness: ServiceReadiness.notRegistered,
      );
    }
    final isConnected = connectedIds.contains(server.id);
    return ServiceStatus(
      service: service,
      readiness: isConnected
          ? ServiceReadiness.ready
          : ServiceReadiness.unreachable,
      serverId: server.id,
      error: isConnected ? null : mcp.errorFor(server.id),
    );
  }

  /// True when at least one ecosystem service can serve a tool call.
  bool get hasAnyReadyService =>
      statuses().any((s) => s.isReady);

  // ---------------------------------------------------------------------
  // Tool execution
  // ---------------------------------------------------------------------

  /// Executes a tool call against whichever ecosystem service owns [toolName].
  ///
  /// Shaped to match Kelivo's `ToolCallHandler` so it can be passed straight
  /// into the existing tool loop with no adapter:
  ///
  /// ```dart
  /// final handler = core.toolHandlerFor(conversationId: id);
  /// // -> Future<Object?> Function(String, Map<String,dynamic>, {String? toolCallId})
  /// ```
  ///
  /// The returned future never throws: a failed tool becomes a failure
  /// [InferToolOutcome] rendered as markdown, because a model that receives a
  /// thrown exception cannot recover, while one that receives an error string
  /// can.
  Future<InferToolOutcome> callTool({
    required String toolName,
    Map<String, dynamic> arguments = const {},
    String? conversationId,
    String? assistantId,
  }) async {
    try {
      final res = conversationId != null
          ? await tools.callFlattenedToolForConversation(
              mcp,
              // Tool routing only reads the conversation's selected servers;
              // it never mutates chat state, so this stays a pure lookup.
              chat,
              conversationId: conversationId,
              toolName: toolName,
              arguments: arguments,
            )
          : await tools.callToolForAssistant(
              mcp,
              assistants,
              assistantId: assistantId,
              toolName: toolName,
              arguments: arguments,
            );
      return InferToolOutcome.fromMcp(toolName, res);
    } catch (e) {
      return InferToolOutcome.failure(toolName, e.toString());
    }
  }

  /// Builds a handler for Kelivo's tool loop.
  ///
  /// This is the function that makes Infer an *agent*: hand it to
  /// `runClientToolFollowUps` / `executeClientTools` and the model's tool
  /// calls start reaching WeatherFusion and future services.
  Future<Object?> Function(
    String name,
    Map<String, dynamic> args, {
    String? toolCallId,
  })
  toolHandlerFor({String? conversationId, String? assistantId}) {
    return (String name, Map<String, dynamic> args, {String? toolCallId}) async {
      final outcome = await callTool(
        toolName: name,
        arguments: args,
        conversationId: conversationId,
        assistantId: assistantId,
      );
      return outcome.markdown;
    };
  }

  // ---------------------------------------------------------------------
  // Registration helpers
  // ---------------------------------------------------------------------

  /// Registers every ecosystem service that is missing, idempotently.
  ///
  /// Safe on every app start and after every sign-in. Returns the ids of
  /// servers that were newly created, so callers can log or toast.
  Future<List<String>> ensureAllRegistered({String? bearerToken}) async {
    final created = <String>[];

    final weatherFusion = EcosystemMcpRegistrar(mcp);
    final alreadyHadWeatherFusion = mcp.servers.any(
      (s) => s.name == EcosystemMcpRegistrar.serverName,
    );
    await weatherFusion.ensureWeatherFusionRegistered(
      bearerToken: bearerToken,
    );
    if (!alreadyHadWeatherFusion) created.add('weatherfusion');

    return created;
  }
}
