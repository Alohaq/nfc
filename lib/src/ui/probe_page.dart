import 'package:flutter/material.dart';

import '../epd/hex.dart';
import '../epd/protocol.dart';

/// Read-only probe screen.
///
/// Send order is intentionally the same as the reference tool: D1 info, then
/// D8 access check. Nothing here writes to the panel, so it is safe to run
/// repeatedly against an unknown device.
class ProbePage extends StatefulWidget {
  const ProbePage({
    super.key,
    required this.log,
    required this.onSendApdu,
    required this.transportName,
    required this.canUseShortFrames,
  });

  final List<String> log;

  /// Sends one APDU; null result means the transport is gone.
  final Future<ApduResponse?> Function(String hex) onSendApdu;

  final String transportName;
  final bool canUseShortFrames;

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final _controller = TextEditingController(text: '00D1000000');
  final _results = <_ProbeResult>[];
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() => _busy = true);
    final hex = _controller.text.trim().toUpperCase();
    try {
      final response = await widget.onSendApdu(hex);
      setState(() {
        _results.insert(
          0,
          _ProbeResult(
            request: hex,
            response: response == null
                ? 'transport closed'
                : 'SW=${response.swHex}'
                    '${response.payload.isEmpty ? '' : ' data=${Hex.of(response.payload)}'}',
            meaning: response?.swMeaning ?? '',
            ok: response?.isOk ?? false,
          ),
        );
      });
    } catch (e) {
      setState(() {
        _results.insert(0, _ProbeResult(request: hex, response: '$e', meaning: '', ok: false));
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Transport', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(widget.transportName,
                    style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace', color: theme.hintColor)),
                const SizedBox(height: 12),
                if (!widget.canUseShortFrames)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'This transport cannot send 7-bit short frames '
                      '(26 / 52 / 7A / 7D). Panels that need a private wake code '
                      'before ISO-DEP activation will not respond here — '
                      'no phone NFC radio can send those frames.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _controller,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: const InputDecoration(
            labelText: 'APDU (hex)',
            border: OutlineInputBorder(),
            helperText: 'Common: 00D1000000 (info), F0D800000005000000000E (access), '
                'F0DE000001 (status)',
          ),
          onSubmitted: (_) => _send(),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _send,
          icon: _busy
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.send),
          label: const Text('Send'),
        ),
        const SizedBox(height: 16),
        if (_results.isNotEmpty) ...[
          Text('Responses (newest first)', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final r in _results)
            Card(
              color: r.ok ? null : theme.colorScheme.errorContainer,
              child: ListTile(
                dense: true,
                leading: Icon(r.ok ? Icons.check_circle : Icons.error,
                    color: r.ok ? Colors.green : theme.colorScheme.error),
                title: Text(r.request,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                subtitle: Text(
                  '${r.response}${r.meaning.isEmpty ? '' : '\n${r.meaning}'}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _ProbeResult {
  _ProbeResult({
    required this.request,
    required this.response,
    required this.meaning,
    required this.ok,
  });
  final String request;
  final String response;
  final String meaning;
  final bool ok;
}
