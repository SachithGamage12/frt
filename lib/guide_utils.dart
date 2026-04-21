import 'dart:ui';
import 'package:flutter/material.dart';
import 'style_utils.dart';

class OnboardingGuide {
  static OverlayEntry? _overlayEntry;

  static void show({
    required BuildContext context,
    required GlobalKey targetKey,
    required String message,
    required VoidCallback onOk,
    bool showOk = true,
  }) {
    _overlayEntry?.remove();
    _overlayEntry = OverlayEntry(
      builder: (context) => _OnboardingOverlay(
        targetKey: targetKey,
        message: message,
        onOk: () {
          _overlayEntry?.remove();
          _overlayEntry = null;
          onOk();
        },
        showOk: showOk,
      ),
    );
    Overlay.of(context).insert(_overlayEntry!);
  }

  static void hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }
}

class _OnboardingOverlay extends StatefulWidget {
  final GlobalKey targetKey;
  final String message;
  final VoidCallback onOk;
  final bool showOk;

  const _OnboardingOverlay({
    required this.targetKey,
    required this.message,
    required this.onOk,
    required this.showOk,
  });

  @override
  State<_OnboardingOverlay> createState() => _OnboardingOverlayState();
}

class _OnboardingOverlayState extends State<_OnboardingOverlay> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  Rect? _targetRect;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
    _controller.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _calculateTargetRect();
    });
  }

  void _calculateTargetRect() {
    final renderBox = widget.targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null) {
      final offset = renderBox.localToGlobal(Offset.zero);
      setState(() {
        _targetRect = Rect.fromLTWH(
          offset.dx,
          offset.dy,
          renderBox.size.width,
          renderBox.size.height,
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_targetRect == null) return const SizedBox.shrink();

    final screenSize = MediaQuery.of(context).size;
    
    // Determine tooltip position
    bool isTooltipAbove = _targetRect!.top > screenSize.height / 2;
    double tooltipTop = isTooltipAbove 
        ? _targetRect!.top - 180 
        : _targetRect!.bottom + 20;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Background Blur & Dim
          GestureDetector(
            onTap: () {}, // Blocks touches to underlying UI
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: CustomPaint(
                size: screenSize,
                painter: _GuidePainter(targetRect: _targetRect!),
              ),
            ),
          ),

          // Tooltip Box
          Positioned(
            top: tooltipTop.clamp(20, screenSize.height - 200),
            left: 20,
            right: 20,
            child: FadeTransition(
              opacity: _animation,
              child: ScaleTransition(
                scale: _animation,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.surface.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: AppColors.primary.withOpacity(0.5), width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 20,
                        spreadRadius: 5,
                      )
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Accent line animation simulation via decoration
                      Container(
                        height: 2,
                        width: 40,
                        margin: const EdgeInsets.only(bottom: 15),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(colors: [AppColors.primary, Colors.blue]),
                          borderRadius: BorderRadius.circular(1),
                        ),
                      ),
                      Text(
                        widget.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (widget.showOk) ...[
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primary,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            onPressed: widget.onOk,
                            child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GuidePainter extends CustomPainter {
  final Rect targetRect;

  _GuidePainter({required this.targetRect});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.black.withOpacity(0.75);
    
    // Create a path for the full screen with a hole for the target
    final backgroundPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    
    // Add rounded rectangle hole for the target widget
    final targetPath = Path()..addRRect(
      RRect.fromRectAndRadius(
        targetRect.inflate(10), // Add some padding around the widget
        const Radius.circular(16),
      ),
    );

    // Combine using XOR to create the hole
    final finalPath = Path.combine(PathOperation.difference, backgroundPath, targetPath);
    
    canvas.drawPath(finalPath, paint);

    // Add a glowing border around the hole
    final borderPaint = Paint()
      ..color = AppColors.primary.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        targetRect.inflate(10),
        const Radius.circular(16),
      ),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
