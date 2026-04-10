import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFFCE93D8); // Light Purple (Purple 200)
  static const Color secondary = Color(0xFF00B4D8);
  static const Color background = Color(0xFF0F2027); // Deep Navy
  static const Color surface = Color(0xFF1E1E1E); // Dark Gray
  static const Color error = Color(0xFFFF5252);
  static const Color textBody = Colors.white70;
  static const Color textHeading = Colors.white;
}

class AppAlerts {
  static void show(BuildContext context, String message, {bool isError = false}) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: AppColors.surface.withOpacity(0.95),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isError ? AppColors.error.withOpacity(0.5) : AppColors.primary.withOpacity(0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: (isError ? AppColors.error : AppColors.primary).withOpacity(0.1),
                blurRadius: 20,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.info_outline,
                color: isError ? AppColors.error : AppColors.primary,
                size: 48,
              ),
              const SizedBox(height: 16),
              Text(
                isError ? 'Oops!' : 'Notice',
                style: const TextStyle(
                  color: AppColors.textHeading,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textBody,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isError ? AppColors.error : AppColors.primary,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AppTheme {
  static BoxDecoration glassmorphic = BoxDecoration(
    color: Colors.white.withOpacity(0.05),
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: Colors.white.withOpacity(0.1)),
  );
}
