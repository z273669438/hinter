import 'package:flutter/material.dart';
import 'dart:math' as math;
import 'package:flutter/scheduler.dart';


/// 提词字幕层(悬浮窗内部)。
///
/// - 整篇文本按宽度自然换行,当前阅读位置起的一小段用琥珀色放大一号显示;
/// - 光标带滞后动画([lagSeconds]),视觉推进比语音更从容;
/// - 点击任意文字可手动跳转;滚动让阅读位置保持在窗口约 42% 高度。
class TeleprompterOverlay extends StatefulWidget {
  const TeleprompterOverlay({
    super.key,
    required this.text,
    required this.currentRawOffset,
    required this.highlightRawEnd,
    required this.fontSize,
    this.cursorRate = 6.0,
    this.scrollEnabled = true,
    this.onSeek,
  });

  final String text;
  final int currentRawOffset;
  final int highlightRawEnd;
  final double fontSize;

  /// 光标追踪速率(归一化字/秒):越大跟随越紧
  final double cursorRate;

  /// 双指捏合时由外层置 false,让出手势竞技场
  final bool scrollEnabled;
  final ValueChanged<int>? onSeek;

  @override
  State<TeleprompterOverlay> createState() => _TeleprompterOverlayState();
}

class _TeleprompterOverlayState extends State<TeleprompterOverlay>
    with SingleTickerProviderStateMixin {
  static const double _hPad = 16;
  static const double _focusRatio = 0.16;

  final _scroll = ScrollController();
  TextPainter? _painter;
  double _layoutWidth = 0;
  double _layoutFontSize = 0;
  TextScaler _layoutScaler = TextScaler.noScaling;
  int _layoutStart = -1;
  int _layoutEnd = -1;
  bool _scheduled = false;

  /// 光标:恒速追踪目标(每帧固定字/秒),永不脉冲/变速
  late final Ticker _ticker;
  Duration _lastTick = Duration.zero;
  double _displayStart = 0; // 平滑后的光标起点
  double _displayEnd = 0; // 平滑后的光标终点
  double _ensureAcc = 0;
  double _vPadTop = 0;
  double _vPadBottom = 0;
  DateTime _userScrollUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// 高亮比正文大一号
  double get _hlSize => widget.fontSize + 4;

  TextScaler get _scaler => MediaQuery.textScalerOf(context);

  @override
  void initState() {
    super.initState();
    _displayStart = widget.currentRawOffset.toDouble();
    _displayEnd = widget.highlightRawEnd.toDouble();
    // 恒速追踪:每帧向目标移动 cursorRate 字/秒(与识别限速同量级),
    // 匀速滑动,替代此前"每次重启 1.5s 缓动"的脉冲式追赶
    _ticker = createTicker((elapsed) {
      final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
      _lastTick = elapsed;
      if (dt <= 0 || dt > 0.2) return;
      // 保证高亮之后始终有 3 行内容可见(用户手动滚动后 12s 内不干预)
      _ensureAcc += dt;
      if (_ensureAcc > 0.6) {
        _ensureAcc = 0;
        if (DateTime.now().isAfter(_userScrollUntil)) _ensureVisible();
      }
      final target =
          widget.currentRawOffset.toDouble().clamp(0.0, widget.text.length.toDouble());
      final diff = target - _displayStart;
      if (diff.abs() < 0.02) return;
      final step = diff.sign * math.min(diff.abs(), widget.cursorRate * dt);
      setState(() {
        _displayStart = (_displayStart + step)
            .clamp(0.0, widget.text.length.toDouble());
        final span =
            (widget.highlightRawEnd - widget.currentRawOffset).clamp(0, 64);
        _displayEnd = _displayStart + span;
      });
    })..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo());
  }

  @override
  void didUpdateWidget(covariant TeleprompterOverlay old) {
    super.didUpdateWidget(old);
    final jump = (widget.currentRawOffset - old.currentRawOffset).abs();
    if (jump > 30) {
      // 大跳(点击跳转/自动重锚定):直接吸附,不从中间爬过去
      _displayStart = widget.currentRawOffset.toDouble();
      _displayEnd = widget.highlightRawEnd.toDouble();
      _scheduleScroll();
    } else if (old.fontSize != widget.fontSize || old.text != widget.text) {
      _disposePainter();
      _displayStart = widget.currentRawOffset.toDouble();
      _displayEnd = widget.highlightRawEnd.toDouble();
      _scheduleScroll();
    }
  }

  void _disposePainter() {
    _painter?.dispose();
    _painter = null;
  }

  bool _layoutValid(double width) {
    return _painter != null &&
        _layoutWidth == width &&
        _layoutFontSize == widget.fontSize &&
        _layoutScaler == _scaler &&
        _layoutStart == _cursorPos &&
        _layoutEnd == _cursorEnd;
  }

  int get _cursorPos => _displayStart.round().clamp(0, widget.text.length);
  int get _cursorEnd {
    final p = _painter;
    var end = _displayEnd.round().clamp(0, widget.text.length);
    if (p == null || widget.text.isEmpty) return end;
    // 高亮窗口最多两行:取"当前行 + 下一行"的末尾作为上限
    try {
      final l1 = p.getLineBoundary(TextPosition(offset: _cursorPos));
      var limit = l1.end;
      if (limit < widget.text.length) {
        final l2 = p.getLineBoundary(TextPosition(offset: limit));
        limit = l2.end;
      }
      if (end > limit) end = limit.clamp(0, widget.text.length);
    } catch (_) {}
    return end;
  }

  TextPainter _getPainter(double textWidth) {
    if (_layoutValid(textWidth)) return _painter!;
    final p = _painter ?? TextPainter(textDirection: TextDirection.ltr);
    p.text = _buildSpan();
    p.textScaler = _scaler;
    p.layout(maxWidth: textWidth);
    _painter = p;
    _layoutWidth = textWidth;
    _layoutFontSize = widget.fontSize;
    _layoutScaler = _scaler;
    _layoutStart = _cursorPos;
    _layoutEnd = _cursorEnd;
    return p;
  }

  /// 三段式样式:已念(暗)/ 当前(琥珀+放大)/ 未念(亮)。
  /// 放大字号会引起重排,但布局与渲染共用同一 span,坐标计算始终一致。
  TextSpan _buildSpan() {
    final base = TextStyle(
      fontSize: widget.fontSize,
      height: 1.6,
      fontWeight: FontWeight.w500,
    );
    final text = widget.text;
    final start = _cursorPos;
    final end = _cursorEnd;
    return TextSpan(
      style: base.copyWith(color: const Color(0xFF8C8C8C)),
      children: [
        if (start > 0)
          TextSpan(
              text: text.substring(0, start),
              style: base.copyWith(color: const Color(0xFF555555))),
        if (end > start)
          TextSpan(
              text: text.substring(start, end),
              style: base.copyWith(
                  fontSize: _hlSize,
                  color: const Color(0xFFFFB300),
                  fontWeight: FontWeight.w700)),
        if (end < text.length)
          TextSpan(
              text: text.substring(end),
              style: base.copyWith(color: const Color(0xFF8C8C8C))),
      ],
    );
  }

  void _scheduleScroll() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      _scrollTo();
    });
  }

  void _scrollTo() {
    if (!_scroll.hasClients || widget.text.isEmpty) return;
    final painter = _painter; // build 阶段已完成布局
    if (painter == null) return;
    final caret = painter
        .getOffsetForCaret(TextPosition(offset: _cursorPos), Rect.zero);
    final target = caret.dy.clamp(0.0, _scroll.position.maxScrollExtent);
    if ((target - _scroll.offset).abs() < 2) return; // 已到位,不反复动画
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
  }

  /// 保证「高亮结束行之后至少 3 行可见」且高亮起点未滚出上方;
  /// 只做最小滚动,不把高亮钉在固定屏幕位置
  void _ensureVisible() {
    if (!_scroll.hasClients || widget.text.isEmpty) return;
    final p = _painter;
    if (p == null) return;
    final vp = _scroll.position.viewportDimension;
    if (vp <= 0) return;
    final lineH = p.preferredLineHeight;
    final endDy =
        p.getOffsetForCaret(TextPosition(offset: _cursorEnd), Rect.zero).dy;
    final startDy =
        p.getOffsetForCaret(TextPosition(offset: _cursorPos), Rect.zero).dy;
    // 可视文本区间(文本坐标):视口与文字实际范围的交集。
    // 注意底部 padding 是滚动内容内的空白,文字在其上方就可见,
    // 不能从可视高度里再扣掉它,否则两个约束会互相打架来回震荡
    final visibleBottom = math.min(_scroll.offset + vp, _vPadTop + p.height) -
        _vPadTop;
    final visibleTop = _scroll.offset - _vPadTop;
    var target = _scroll.offset;
    // 底部约束:高亮结束行底 + 3 行 ≤ 可视下缘
    if (endDy + 3.5 * lineH > visibleBottom) {
      target = _scroll.offset + (endDy + 3.5 * lineH - visibleBottom);
    }
    // 顶部约束:高亮起点不能滚出可视区上方
    if (startDy < visibleTop) {
      target = startDy + _vPadTop;
    }
    final t = target.clamp(0.0, _scroll.position.maxScrollExtent);
    if ((t - _scroll.offset).abs() >= 2) {
      _scroll.animateTo(t,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic);
    }
  }

  void _handleTap(Offset local, double vPadTop) {
    final painter = _painter;
    if (painter == null || widget.text.isEmpty) return;
    final dy = local.dy - vPadTop + _scroll.offset;
    final pos = painter.getPositionForOffset(Offset(local.dx - _hPad, dy));
    widget.onSeek?.call(pos.offset.clamp(0, widget.text.length));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _painter?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scaler = _scaler;
    return widget.text.trim().isEmpty
        ? const Center(
            child: Text('脚本内容为空',
                style: TextStyle(color: Colors.white54)))
        : LayoutBuilder(builder: (context, constraints) {
            final textWidth = constraints.maxWidth - _hPad * 2;
            _getPainter(textWidth); // 布局缓存供 _scrollTo 用
            final vPadTop = constraints.maxHeight * _focusRatio;
            final vPadBottom = constraints.maxHeight * (1 - _focusRatio);
            _vPadTop = vPadTop;
            _vPadBottom = vPadBottom;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _handleTap(d.localPosition, vPadTop),
              child: NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  // 用户手指拖动 → 暂停自动定位 12s,尊重手动调整
                  if ((n is ScrollStartNotification && n.dragDetails != null) ||
                      (n is ScrollUpdateNotification &&
                          n.dragDetails != null)) {
                    _userScrollUntil =
                        DateTime.now().add(const Duration(seconds: 12));
                  }
                  return false;
                },
                child: SingleChildScrollView(
                  controller: _scroll,
                  physics: widget.scrollEnabled
                      ? const AlwaysScrollableScrollPhysics()
                      : const NeverScrollableScrollPhysics(),
                  child: Padding(
                    padding: EdgeInsets.only(
                        left: _hPad,
                        right: _hPad,
                        top: vPadTop,
                        bottom: vPadBottom),
                    child: RichText(
                      text: _buildSpan(),
                      textScaler: scaler,
                    ),
                  ),
                ),
              ),
            );
          });
  }
}
