import 'package:flutter/material.dart';

import '../epd/hex.dart';
import '../epd/protocol.dart';

/// 只读探测页。
///
/// 发送顺序与参考实现一致：先 D1 读信息，再 D8 查权限。这里不会写入屏幕，
/// 因此可以放心重复执行。
class ProbePage extends StatefulWidget {
  const ProbePage({
    super.key,
    required this.log,
    required this.onSendApdu,
    required this.transportName,
    required this.canUseShortFrames,
  });

  final List<String> log;

  /// 发送一条 APDU；返回 null 表示链路已断开。
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
                ? '链路已关闭'
                : 'SW=${response.swHex}'
                    '${response.payload.isEmpty ? '' : ' 数据=${Hex.of(response.payload)}'}',
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
                Text('当前链路', style: theme.textTheme.titleMedium),
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
                      '当前链路无法发送 7 位短帧（26 / 52 / 7A / 7D）。'
                      '若屏幕需要私有唤醒码才能进入 ISO-DEP，那么在这里不会有任何响应——'
                      '手机的 NFC 射频本身就不支持发送这类帧。',
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
            labelText: 'APDU（十六进制）',
            border: OutlineInputBorder(),
            helperText: '常用：00D1000000（读信息）、'
                'F0D800000005000000000E（查权限）、F0DE000001（查状态）',
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
          label: const Text('发送'),
        ),
        const SizedBox(height: 16),
        if (_results.isNotEmpty) ...[
          Text('响应（最新在上）', style: theme.textTheme.titleSmall),
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
