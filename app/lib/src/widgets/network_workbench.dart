import 'package:flutter/material.dart';
import 'network_input_controller.dart';

/// What a custom state_network presentation needs from the play screen.
class NetworkWorkbenchRequest {
  final String levelId;
  final Map<String, dynamic> scene;
  final Map<String, dynamic>? config;
  final Map<String, dynamic>? publicCircuit;
  final NetworkInputController? inputController;
  final Map<String, dynamic> variables;
  final int revision;
  final bool enabled;
  final ValueChanged<String> onAction;
  final ValueChanged<bool>? onAnimating;

  const NetworkWorkbenchRequest({
    required this.levelId,
    required this.scene,
    required this.config,
    required this.publicCircuit,
    required this.inputController,
    required this.variables,
    required this.revision,
    required this.enabled,
    required this.onAction,
    required this.onAnimating,
  });
}

/// Extension point for a pack-specific state_network presentation.
///
/// A level opts in by carrying `metadata.mechanismScene`. The public app ships
/// no presentation of its own, so such levels fall back to the generic bench.
/// A distribution that has one replaces this file with an implementation that
/// returns true here and builds the widget below.
bool hasNetworkWorkbench(Map<String, dynamic>? scene) => false;

Widget buildNetworkWorkbench(NetworkWorkbenchRequest request) =>
    throw UnsupportedError('No network workbench is installed');

/// Page colour for a level with a custom presentation; null keeps the default.
Color? networkWorkbenchBackground(Map<String, dynamic>? scene) => null;
