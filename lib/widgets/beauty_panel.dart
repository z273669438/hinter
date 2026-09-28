import 'package:flutter/material.dart';

/// 美颜参数滑杆(带数值)。onChangeStart/changed/end 都会回调,
/// 由页面实时下发到原生渲染管线(原生侧异步处理,UI 不卡)。
class BeautySlider extends StatelessWidget {
  const BeautySlider({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final double value;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: Colors.white70),
              const SizedBox(width: 5),
              Text(label,
                  style: const TextStyle(
                      fontSize: 13, color: Colors.white70)),
              const Spacer(),
              Text('${(value * 100).round()}',
                  style: const TextStyle(
                      fontSize: 12, color: Colors.white54)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 10),
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}

/// 右侧滑出的美颜抽屉(磨皮/美白/瘦脸)。
class BeautyDrawer extends StatelessWidget {
  const BeautyDrawer({
    super.key,
    required this.open,
    required this.smooth,
    required this.whiten,
    required this.slim,
    required this.onSmooth,
    required this.onWhiten,
    required this.onSlim,
    required this.onClose,
    required this.bottomInset,
  });

  final bool open;
  final double smooth;
  final double whiten;
  final double slim;
  final ValueChanged<double> onSmooth;
  final ValueChanged<double> onWhiten;
  final ValueChanged<double> onSlim;
  final VoidCallback onClose;
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      right: open ? 0 : -244,
      top: 0,
      bottom: bottomInset,
      child: SizedBox(
        width: 236,
        child: Material(
          color: const Color(0xE6202020),
          borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              bottomLeft: Radius.circular(16)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 6, 2),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome,
                        size: 16, color: Color(0xFFFFB300)),
                    const SizedBox(width: 6),
                    const Text('美颜',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: onClose),
                  ],
                ),
              ),
              BeautySlider(
                  icon: Icons.face_retouching_natural,
                  label: '磨皮',
                  value: smooth,
                  onChanged: onSmooth),
              BeautySlider(
                  icon: Icons.wb_sunny_outlined,
                  label: '美白',
                  value: whiten,
                  onChanged: onWhiten),
              BeautySlider(
                  icon: Icons.face,
                  label: '瘦脸',
                  value: slim,
                  onChanged: onSlim),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// 提词浮窗的设置弹层(字号 / 透明度)。
class PrompterSettingsPopup extends StatelessWidget {
  const PrompterSettingsPopup({
    super.key,
    required this.fontSize,
    required this.onFontSize,
    required this.opacity,
    required this.onOpacity,
  });

  final double fontSize;
  final ValueChanged<double> onFontSize;
  final double opacity;
  final ValueChanged<double> onOpacity;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xF2262626),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.format_size, size: 15, color: Colors.white70),
              const SizedBox(width: 4),
              const Text('字号', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: fontSize.clamp(16, 48),
                  min: 16,
                  max: 48,
                  divisions: 16,
                  onChanged: onFontSize,
                ),
              ),
            ],
          ),
          Row(
            children: [
              const Icon(Icons.opacity, size: 15, color: Colors.white70),
              const SizedBox(width: 4),
              const Text('透明', style: TextStyle(fontSize: 12)),
              Expanded(
                child: Slider(
                  value: opacity.clamp(0.0, 0.85),
                  min: 0.0,
                  max: 0.85,
                  onChanged: onOpacity,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
