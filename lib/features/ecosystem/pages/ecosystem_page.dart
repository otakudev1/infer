// Infer: ecosystem status page.
//
// This is the screen that makes Infer an *ecosystem client* rather than yet
// another chat app: it shows which of Hardik's services are wired in, how to
// reach them, and what Infer can do with each one.
//
// Copyright (C) Infer contributors. AGPL-3.0 (inherited from Kelivo).

import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/mcp_provider.dart';
import 'package:Kelivo/features/ecosystem/services/weatherfusion_mcp.dart';

class EcosystemPage extends StatefulWidget {
  const EcosystemPage({super.key});

  @override
  State<EcosystemPage> createState() => _EcosystemPageState();
}

class _EcosystemPageState extends State<EcosystemPage> {
  ServiceHealth _health = ServiceHealth.notConfigured;
  String? _detail;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkHealth());
  }

  Future<void> _checkHealth() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _health = ServiceHealth.notConfigured;
      _detail = null;
    });
    try {
      final res = await http
          .get(Uri.parse(EcosystemEndpoints.weatherFusionHealth))
          .timeout(const Duration(seconds: 75));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body);
        setState(() {
          _health = ServiceHealth.online;
          _detail = 'service: ${body['service'] ?? 'weatherfusion-mcp'}';
        });
      } else {
        setState(() {
          _health = ServiceHealth.degraded;
          _detail = 'HTTP ${res.statusCode}';
        });
      }
    } on TimeoutException {
      if (!mounted) return;
      // Render free tier: sleeping container takes up to ~60s to wake. That is
      // expected behaviour, not a failure, so it gets its own state.
      setState(() {
        _health = ServiceHealth.waking;
        _detail = 'Free tier cold start — retry in a moment';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _health = ServiceHealth.degraded;
        _detail = e.toString();
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mcp = context.watch<McpProvider>();
    final registered = mcp.servers.any((s) => s.name == EcosystemMcpRegistrar.serverName);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Infer ecosystem'),
        actions: [
          IconButton(
            tooltip: 'Re-check services',
            onPressed: _checking ? null : _checkHealth,
            icon: _checking
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HealthCard(
            health: _health,
            detail: _detail,
            checking: _checking,
            onRetry: _checkHealth,
          ),
          const SizedBox(height: 20),
          Text('Connected services', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('WeatherFusion'),
                  subtitle: Text(
                    registered
                        ? 'Registered as an MCP server — ${EcosystemMcpRegistrar.weatherFusionTools.length} tools'
                        : 'Not registered yet',
                  ),
                  trailing: Switch(
                    value: registered,
                    onChanged: (want) async {
                      final registrar = EcosystemMcpRegistrar(mcp: mcp);
                      if (want) {
                        await registrar.ensureWeatherFusionRegistered();
                      } else {
                        final match = mcp.servers
                            .where((s) => s.name == EcosystemMcpRegistrar.serverName)
                            .toList();
                        for (final s in match) {
                          await mcp.removeServer(s.id);
                        }
                      }
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Tools Infer can call',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 6),
                      for (final t in EcosystemMcpRegistrar.weatherFusionTools)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.build_outlined, size: 16),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: t.name,
                                        style: const TextStyle(
                                          fontFeatures: [FontFeature.tabularFigures()],
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      TextSpan(text: '  ${t.description}'),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('Infrastructure', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('WeatherFusion MCP endpoint'),
                  subtitle: const Text(EcosystemEndpoints.weatherFusionSse),
                  isThreeLine: false,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('Supabase project'),
                  subtitle: const Text(EcosystemEndpoints.supabaseUrl),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Infer stores your API keys on this device only. Nothing is sent '
            'to a server you do not control.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({
    required this.health,
    required this.detail,
    required this.checking,
    required this.onRetry,
  });

  final ServiceHealth health;
  final String? detail;
  final bool checking;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, color, label) = switch (health) {
      ServiceHealth.online => (Icons.check_circle, Colors.green, 'Online'),
      ServiceHealth.waking => (Icons.hourglass_top, Colors.orange, 'Waking up'),
      ServiceHealth.degraded => (Icons.error_outline, scheme.error, 'Degraded'),
      ServiceHealth.notConfigured => (Icons.help_outline, scheme.outline, 'Not checked'),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 2),
                  Text(
                    detail ?? 'WeatherFusion MCP',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (!checking)
              TextButton(onPressed: onRetry, child: const Text('Check')),
          ],
        ),
      ),
    );
  }
}
