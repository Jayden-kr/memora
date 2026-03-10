import 'dart:math';

import 'package:flutter/material.dart';

class CardFlipWidget extends StatefulWidget {
  final Widget front;
  final Widget back;
  final VoidCallback? onFlip;

  const CardFlipWidget({
    required this.front,
    required this.back,
    this.onFlip,
    super.key,
  });

  @override
  State<CardFlipWidget> createState() => CardFlipWidgetState();
}

class CardFlipWidgetState extends State<CardFlipWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  bool _isFront = true;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void resetToFront() {
    if (!_isFront) {
      _controller.value = 0.0;
      _isFront = true;
      if (mounted) setState(() {});
    }
  }

  void _flip() {
    if (_controller.isAnimating) return;
    if (_isFront) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
    _isFront = !_isFront;
    widget.onFlip?.call();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _flip,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final angle = _controller.value * pi;
          final isFrontVisible = angle <= pi / 2;
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.identity()
              ..setEntry(3, 2, 0.001)
              ..rotateY(angle),
            child: isFrontVisible
                ? widget.front
                : Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()..rotateY(pi),
                    child: widget.back,
                  ),
          );
        },
      ),
    );
  }
}
