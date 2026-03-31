import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:payhere_mobilesdk_flutter/payhere_mobilesdk_flutter.dart';
import 'dart:math';
import 'dart:io' show Platform;
import 'interface.dart'; // To navigate on success

class PaymentPage extends StatefulWidget {
  final String userId;
  final Map<String, dynamic> userData;

  const PaymentPage({super.key, required this.userId, required this.userData});

  @override
  _PaymentPageState createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  final TextEditingController _promoCodeController = TextEditingController();
  bool _isLoading = false;

  final String merchantId = "1227522";
  
  String get merchantSecret {
    if (Platform.isIOS) {
      return "MjY0MDU4MzAzMDIxMjgzNzY4NjUxODQyMzM5Nzc1ODgxMTgyNjY5";
    } else {
      return "MzQ1NjE1NjgzMDIzOTY0MDQ1MjgzNzk5ODQ5NTMyMTAyMDE3NDA1Nw==";
    }
  }

  void _startPayHerePayment() {
    Map paymentObject = {
      "sandbox": true,                 // true if using Sandbox Merchant ID
      "merchant_id": merchantId,       // Gets a Merchant ID from PayHere Account
      "merchant_secret": merchantSecret, // See step 4e
      "notify_url": "https://ent13ttsy2ig.x.pipedream.net/",
      "order_id": "UnlockApp_${widget.userId}",
      "items": "FRT App Unlock & Code Gen",
      "amount": 350.00,
      "currency": "LKR",
      "first_name": widget.userData['name'] ?? "User",
      "last_name": "",
      "email": widget.userData['email'] ?? "test@test.com",
      "phone": widget.userData['mobile'] ?? widget.userId,
      "address": "Sri Lanka",
      "city": "Colombo",
      "country": "Sri Lanka",
      "delivery_address": "Sri Lanka",
      "delivery_city": "Colombo",
      "delivery_country": "Sri Lanka",
      "custom_1": "",
      "custom_2": ""
    };

    PayHere.startPayment(
      paymentObject, 
      (paymentId) async {
        print("One Time Payment Success. Payment Id: $paymentId");
        await _onPaymentSuccess();
      }, 
      (error) {
        print("One Time Payment Failed. Error: $error");
        _showSnackBar("Payment Failed: $error");
      }, 
      () {
        print("One Time Payment Dismissed");
        _showSnackBar("Payment Dismissed.");
      }
    );
  }

  Future<void> _onPaymentSuccess() async {
    setState(() {
      _isLoading = true;
    });
    try {
      // 1. Generate 6 alphanumeric code
      const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
      Random rnd = Random();
      String code = String.fromCharCodes(Iterable.generate(
        6, (_) => chars.codeUnitAt(rnd.nextInt(chars.length))));

      // 2. Save it to current user's doc
      await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
        'isAppUnlocked': true,
        'generatedPromoCode': code,
        'isPromoCodeUsed': false,
      });

      // 3. Show dialog
      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text("App Unlocked Successfully!", style: TextStyle(color: Colors.black)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text("Thank you for your purchase. Here is your FREE connection code to give to 1 person:"),
                const SizedBox(height: 20),
                SelectableText(
                  code,
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.blueAccent),
                ),
                const SizedBox(height: 10),
                const Text("You can find this code later in your Profile.", style: TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.pop(context); // close dialog
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(builder: (context) => InterfacePage(userId: widget.userId)),
                  );
                },
                child: const Text("Continue to App", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              )
            ],
          ),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _showSnackBar("Error updating status: $e");
    }
  }

  Future<void> _submitPromoCode() async {
    String code = _promoCodeController.text.trim().toUpperCase();
    if (code.isEmpty) {
      _showSnackBar("Please enter a valid connection code.");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      // Find the user who owns this code
      QuerySnapshot query = await FirebaseFirestore.instance
          .collection('users')
          .where('generatedPromoCode', isEqualTo: code)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        _showSnackBar("Invalid Connection Code. Try again.");
        setState(() => _isLoading = false);
        return;
      }

      DocumentSnapshot codeOwnerDoc = query.docs.first;
      Map<String, dynamic> ownerData = codeOwnerDoc.data() as Map<String, dynamic>;

      if (ownerData['isPromoCodeUsed'] == true) {
        _showSnackBar("This Connection Code has already been used by someone else.");
        setState(() => _isLoading = false);
        return;
      }

      // Mark code as used on the owner
      await FirebaseFirestore.instance.collection('users').doc(codeOwnerDoc.id).update({
        'isPromoCodeUsed': true,
      });

      // Mark current user as unlocked
      await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
        'isAppUnlocked': true,
      });

      setState(() {
        _isLoading = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Promo Code Applied! Unlocked successfully.")));
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => InterfacePage(userId: widget.userId)),
        );
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      _showSnackBar("Error applying promo code: $e");
    }
  }

  void _showSnackBar(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Premium Dark Mode Background
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock_outline, size: 80, color: Colors.white70),
                  const SizedBox(height: 20),
                  const Text(
                    "Unlock Family Road Track",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    "Connect with your family members and track them using live tracking. Enhance your app experience by unlocking premium features.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.white70),
                  ),
                  const SizedBox(height: 40),

                  // PayHere Box (Glassmorphism effect)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "LKR 350 One-time",
                          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          "Includes 1 Free Connection Code to share with a partner or family member.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 14, color: Colors.white70),
                        ),
                        const SizedBox(height: 20),
                        _isLoading 
                          ? const CircularProgressIndicator(color: Colors.cyanAccent)
                          : ElevatedButton(
                              onPressed: _startPayHerePayment,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.cyanAccent.shade700,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                elevation: 8,
                              ),
                              child: const Text("Pay with PayHere", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                            ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 30),
                  const Text("OR", style: TextStyle(color: Colors.white54, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 30),

                  // Promo Code Box
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.2)),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          "Have a Connection Code?",
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _promoCodeController,
                          style: const TextStyle(color: Colors.white, letterSpacing: 2.0, fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            filled: true,
                            fillColor: Colors.black26,
                            hintText: "Enter 6-digit Code",
                            hintStyle: const TextStyle(color: Colors.white54, letterSpacing: 1.0, fontWeight: FontWeight.normal),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(16),
                              borderSide: BorderSide.none,
                            ),
                            prefixIcon: const Icon(Icons.vpn_key_outlined, color: Colors.cyanAccent),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _isLoading 
                          ? const CircularProgressIndicator(color: Colors.cyanAccent)
                          : ElevatedButton(
                              onPressed: _submitPromoCode,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                foregroundColor: Colors.cyanAccent,
                                side: const BorderSide(color: Colors.cyanAccent, width: 2),
                                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                              ),
                              child: const Text("Unlock for Free", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
