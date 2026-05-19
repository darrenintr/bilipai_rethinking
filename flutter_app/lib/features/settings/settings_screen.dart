import 'package:bilipai_flutter/domain/settings/playback_speed_policy.dart';
import 'package:flutter/material.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _policy = PlaybackSpeedPolicy();
  double _selected = 1.0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Default playback speed'),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            children: PlaybackSpeedPolicy.allowedSpeeds.map((speed) {
              return ChoiceChip(
                label: Text('${speed}x'),
                selected: _selected == speed,
                onSelected: (_) {
                  setState(() {
                    _selected = _policy.clamp(speed);
                  });
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
