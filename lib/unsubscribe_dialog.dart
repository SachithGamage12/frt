import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'style_utils.dart';

class UnsubscribeDialog extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const UnsubscribeDialog({super.key, required this.userId, required this.userData});

  @override
  _UnsubscribeDialogState createState() => _UnsubscribeDialogState();
}

class _UnsubscribeDialogState extends State<UnsubscribeDialog> {
  final TextEditingController _feedbackController = TextEditingController();
  bool _isLoading = false;

  Future<void> _processCancellation() async {
    final feedback = _feedbackController.text.trim();
    if (feedback.isEmpty) {
      AppAlerts.show(context, "Please tell us why you are canceling.", isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Save feedback to Firestore
      await FirebaseFirestore.instance.collection('cancellations').add({
        'userId': widget.userId,
        'email': widget.userData['email'] ?? 'Unknown',
        'reason': feedback,
        'timestamp': FieldValue.serverTimestamp(),
      });

      // 2. HTTP POST to Pipedream Backend to hit PayHere Subscription Cancel API
      // You must provide the Webhook URL below
      const String cancellationWebhookUrl = "REPLACE_WITH_PIPEDREAM_CANCEL_WEBHOOK";
      if (cancellationWebhookUrl.startsWith("http")) {
        await http.post(
          Uri.parse(cancellationWebhookUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'userId': widget.userId,
            'reason': feedback,
          }),
        );
      }

      // 3. Don't lock them out instantly, just log the cancellation. The Pipedream webhook 
      // will cancel the PayHere recurrence. They keep access until the month ends.
      await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
        'subscriptionCancelledAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        Navigator.pop(context);
        AppAlerts.show(context, "Subscription Cancelled! You still have access until the end of your billing cycle.");
      }
    } catch (e) {
      setState(() => _isLoading = true);
      if (mounted) {
        AppAlerts.show(context, "Error canceling subscription: $e", isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(24.0),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.cancel_outlined, color: Colors.redAccent, size: 32),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Cancel Subscription",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppColors.textHeading),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              "We're sorry to see you go. Before your premium access is revoked, please tell us why you are leaving and if the app was useful to you?",
              style: TextStyle(fontSize: 14, color: AppColors.textBody),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _feedbackController,
              maxLines: 4,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "Your feedback...",
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Keep Subscription", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(width: 8),
                _isLoading 
                  ? const CircularProgressIndicator(color: Colors.redAccent)
                  : ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _processCancellation,
                      child: const Text("Confirm Cancel", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
              ],
            )
          ],
        ),
      ),
    );
  }
}
