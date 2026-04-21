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
    // v33: Auto-scroll to target if in scrollable
    if (targetKey.currentContext != null) {
      Scrollable.ensureVisible(
        targetKey.currentContext!,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    }

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
    
    // Slight delay to allow scrolling to settle before showing overlay
    Future.delayed(const Duration(milliseconds: 700), () {
      if (context.mounted) {
        Overlay.of(context).insert(_overlayEntry!);
      }
    });
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

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _animation = CurvedAnimation(parent: _controller, curve: Curves.elasticOut);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // v33: Improved responsive positioning - dynamic calculation based on current render position
    final renderBox = widget.targetKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return const SizedBox.shrink();

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    final offset = renderBox.localToGlobal(Offset.zero, ancestor: overlay);
    final targetRect = Rect.fromLTWH(
      offset.dx,
      offset.dy,
      renderBox.size.width,
      renderBox.size.height,
    );

    final screenSize = MediaQuery.of(context).size;
    
    // Determine tooltip position
    bool isTooltipAbove = targetRect.top > screenSize.height / 2;
    double tooltipTop = isTooltipAbove 
        ? targetRect.top - 180 
        : targetRect.bottom + 20;

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Background Blur & Dim with Sharp Hole
          IgnorePointer(
            child: ClipPath(
              clipper: _InvertedRRectClipper(targetRect: targetRect),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                ),
              ),
            ),
          ),

          // Border around the hole (Drawn separately to stay sharp)
          CustomPaint(
            size: screenSize,
            painter: _HoleBorderPainter(targetRect: targetRect),
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
                    color: AppColors.surface.withOpacity(0.95),
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

class _InvertedRRectClipper extends CustomClipper<Path> {
  final Rect targetRect;

  _InvertedRRectClipper({required this.targetRect});

  @override
  Path getClip(Size size) {
    return Path.combine(
      PathOperation.difference,
      Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height)),
      Path()..addRRect(
        RRect.fromRectAndRadius(
          targetRect.inflate(8),
          const Radius.circular(16),
        ),
      ),
    );
  }

  @override
  bool shouldReclip(covariant _InvertedRRectClipper oldClipper) => 
      oldClipper.targetRect != targetRect;
}

class _HoleBorderPainter extends CustomPainter {
  final Rect targetRect;

  _HoleBorderPainter({required this.targetRect});

  @override
  void paint(Canvas canvas, Size size) {
    final borderPaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        targetRect.inflate(8),
        const Radius.circular(16),
      ),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _HoleBorderPainter oldDelegate) => 
      oldDelegate.targetRect != targetRect;
}
