// Infer: BYOK (bring-your-own-key) onboarding.
//
// Infer never ships an API key and never proxies requests through a server we
// control. That is the whole point of the fork: the user owns the model
// credential, it lands in the device database, and every request goes straight
// from the phone to the provider.
//
// This widget is the first-run gate. It exists so a fresh install is not a
// dead-end chat box; it points at the three provider shapes Infer actually
// supports (OpenAI-compatible, Anthropic, Gemini) and hands off to the existing
// provider editor for the actual credential entry.
//
// Copyright (C) Infer contributors. AGPL-3.0 (inherited from Kelivo).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:Kelivo/core/providers/settings_provider.dart';
import 'package:Kelivo/features/provider/pages/providers_page.dart';

/// A provider the user is likely to have a key for.
class _KeyOption {
  const _KeyOption({
    required this.name,
    required this.blurb,
    required this.icon,
  });

  final String name;
  final String blurb;
  final IconData icon;
}

/// Shown when Infer has no usable model configured yet.
///
/// Deliberately a blocking-but-dismissible card rather than a full wizard: a
/// user who already knows what they are doing should be able to push past it in
/// one tap and paste a key into the normal provider screen.
class ByokOnboardingCard extends StatelessWidget {
  const ByokOnboardingCard({super.key});

  static const List<_KeyOption> _options = [
    _KeyOption(
      name: 'OpenAI-compatible',
      blurb: 'OpenAI, Groq, Together, OpenRouter, a local server — anything '
          'that speaks the /chat/completions API.',
      icon: Icons.hub_outlined,
    ),
    _KeyOption(
      name: 'Anthropic',
      blurb: 'Claude models, native messages API.',
      icon: Icons.auto_awesome_outlined,
    ),
    _KeyOption(
      name: 'Google Gemini',
      blurb: 'Gemini models via the AI Studio key.',
      icon: Icons.diamond_outlined,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasModel = context.watch<SettingsProvider>().hasAnyActiveModel;

    // Once a model exists the gate has done its job and gets out of the way.
    if (hasModel) return const SizedBox.shrink();

    return Card(
      elevation: 0,
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.primary.withValues(alpha: 0.25)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined, size: 20, color: scheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Bring your own key',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Infer has no server of its own. Your API key is stored on this '
              'device and requests go straight from here to the provider.',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 12),
            for (final option in _options)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 28,
                      child: Icon(option.icon, size: 17, color: scheme.primary),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(
                              text: '${option.name}\n',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            TextSpan(
                              text: option.blurb,
                              style: theme.textTheme.bodySmall?.copyWith(
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.add_circle_outline, size: 18),
                label: const Text('Add a provider'),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ProvidersPage()),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
