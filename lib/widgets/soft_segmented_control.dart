import 'package:flutter/material.dart';

/// 설정 등에서 쓰는 미니멀한 언더라인 탭 선택 컨트롤.
/// 컨테이너·알약 없이 텍스트만 나열하고, 선택 항목은 코랄(primary) 글자 +
/// 그 아래 코랄 밑줄이 슬라이딩한다. 은은한 베이스라인으로 탭 스트립처럼 grounding.
class SoftSegmentedControl<T> extends StatelessWidget {
  final List<SoftSegment<T>> segments;
  final T selected;
  final ValueChanged<T> onChanged;

  const SoftSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final selectedIndex = segments.indexWhere((s) => s.value == selected);
    const height = 42.0;
    const underlineH = 2.5;

    return LayoutBuilder(
      builder: (context, constraints) {
        final segW = constraints.maxWidth / segments.length;
        final underlineW = (segW * 0.5).clamp(24.0, 72.0);
        return SizedBox(
          height: height,
          child: Stack(
            children: [
              // 은은한 전체 베이스라인
              Positioned(
                left: 0,
                right: 0,
                bottom: (underlineH - 1) / 2,
                child: Container(
                  height: 1,
                  color: cs.onSurfaceVariant.withValues(alpha: 0.12),
                ),
              ),
              // 슬라이딩 코랄 밑줄
              if (selectedIndex >= 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 240),
                  curve: Curves.easeOutCubic,
                  left: selectedIndex * segW + (segW - underlineW) / 2,
                  bottom: 0,
                  width: underlineW,
                  height: underlineH,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: cs.primary,
                      borderRadius: BorderRadius.circular(underlineH),
                    ),
                  ),
                ),
              // 텍스트 라벨
              Row(
                children: [
                  for (final s in segments)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(s.value),
                        child: Center(
                          child: Padding(
                            padding:
                                const EdgeInsets.only(bottom: underlineH + 6),
                            child: AnimatedDefaultTextStyle(
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOutCubic,
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: s.value == selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: s.value == selected
                                    ? cs.primary
                                    : cs.onSurfaceVariant,
                              ),
                              child: Text(s.label, textAlign: TextAlign.center),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class SoftSegment<T> {
  final T value;
  final String label;
  const SoftSegment({required this.value, required this.label});
}
