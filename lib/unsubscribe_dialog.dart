import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Please tell us why you are canceling.")));
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
        // Close dialog
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Subscription Cancelled! You still have access until the end of your billing cycle.", style: TextStyle(color: Colors.white))));
      }
    } catch (e) {
      setState(() => _isLoading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error canceling subscription: $e")));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.white.withOpacity(0.9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
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
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              "We're sorry to see you go. Before your premium access is revoked, please tell us why you are leaving and if the app was useful to you?",
              style: TextStyle(fontSize: 14, color: Colors.black54),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _feedbackController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: "Your feedback...",
                filled: true,
                fillColor: Colors.black12,
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
