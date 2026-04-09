import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'interface.dart';

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
  File? _selectedFile;
  String? _fileName;
  final PageController _pageController = PageController();
  int _currentPage = 0;
  Timer? _sliderTimer;

  final List<Map<String, String>> _trustInfo = [
    {
      'title': 'Real-Time Family Safety',
      'description': 'Our app provides 99.9% uptime for live tracking, ensuring you always know your loved ones are safe.',
      'icon': '🛡️'
    },
    {
      'title': 'Trusted by 10,000+ Users',
      'description': 'We are a registered service in Sri Lanka, committed to providing secure and reliable family tracking.',
      'icon': '⭐'
    },
    {
      'title': 'Direct Support',
      'description': 'Any issues? Our team is available 24/7 to assist you. Your trust is our priority.',
      'icon': '🤝'
    },
  ];

  @override
  void initState() {
    super.initState();
    _startSlider();
  }

  void _startSlider() {
    _sliderTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (_currentPage < _trustInfo.length - 1) {
        _currentPage++;
      } else {
        _currentPage = 0;
      }
      if (_pageController.hasClients) {
        _pageController.animateToPage(
          _currentPage,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _sliderTimer?.cancel();
    _pageController.dispose();
    _promoCodeController.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('Pick Image (JPG, PNG, JPEG)'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
                if (picked != null) {
                  setState(() {
                    _selectedFile = File(picked.path);
                    _fileName = picked.name;
                  });
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf),
              title: const Text('Pick PDF Document'),
              onTap: () async {
                Navigator.pop(context);
                FilePickerResult? result = await FilePicker.platform.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: ['pdf'],
                );
                if (result != null) {
                  setState(() {
                    _selectedFile = File(result.files.single.path!);
                    _fileName = result.files.single.name;
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submitPayment() async {
    if (_selectedFile == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please upload your payment slip')));
      return;
    }

    setState(() => _isLoading = true);

    try {
      // 1. Upload to Cloudinary (Free & No login needed)
      final url = Uri.parse('https://api.cloudinary.com/v1_1/dz86er6fe/auto/upload');
      final request = http.MultipartRequest('POST', url)
        ..fields['upload_preset'] = 'ml_default'
        ..files.add(await http.MultipartFile.fromPath('file', _selectedFile!.path));

      final response = await request.send();
      if (response.statusCode != 200) {
        throw Exception('Cloudinary upload failed with status ${response.statusCode}');
      }

      final responseData = await response.stream.bytesToString();
      final jsonResponse = json.decode(responseData);
      final downloadUrl = jsonResponse['secure_url'];

      // 2. Update Firestore
      await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
        'paymentStatus': 'pending',
        'paymentSlipUrl': downloadUrl,
        'paymentTimestamp': FieldValue.serverTimestamp(),
      });

      setState(() => _isLoading = false);
      _showSuccessDialog();
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Upload failed: $e')));
    }
  }

  void _showSuccessDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Slip Submitted!', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Your payment slip has been sent for admin review. You will receive a notification once your account is activated.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          )
        ],
      ),
    );
  }

  Future<void> _submitPromoCode() async {
     String code = _promoCodeController.text.trim().toUpperCase();
    if (code.isEmpty) return;

    setState(() => _isLoading = true);

    try {
      QuerySnapshot query = await FirebaseFirestore.instance
          .collection('users')
          .where('generatedPromoCode', isEqualTo: code)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid Code')));
        setState(() => _isLoading = false);
        return;
      }

      DocumentSnapshot owner = query.docs.first;
      if (owner.get('isPromoCodeUsed') == true) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Code already used')));
        setState(() => _isLoading = false);
        return;
      }

      // Mark used and unlock with 30-day expiry
      await FirebaseFirestore.instance.collection('users').doc(owner.id).update({'isPromoCodeUsed': true});
      await FirebaseFirestore.instance.collection('users').doc(widget.userId).update({
        'isAppUnlocked': true,
        'subscriptionExpiry': Timestamp.fromDate(DateTime.now().add(const Duration(days: 30))),
      });

      setState(() => _isLoading = false);
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (context) => InterfacePage(userId: widget.userId)));
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0F2027),
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            children: [
              _buildTrustSlider(),
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  children: [
                    _buildBankCard(),
                    const SizedBox(height: 30),
                    _buildUploadSection(),
                    const SizedBox(height: 40),
                    const Text("--- OR ---", style: TextStyle(color: Colors.white38)),
                    const SizedBox(height: 30),
                    _buildPromoSection(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrustSlider() {
    return Container(
      height: 200,
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        border: Border(bottom: BorderSide(color: Colors.white10)),
      ),
      child: PageView.builder(
        controller: _pageController,
        onPageChanged: (index) => setState(() => _currentPage = index),
        itemCount: _trustInfo.length,
        itemBuilder: (context, index) {
          final info = _trustInfo[index];
          return Padding(
            padding: const EdgeInsets.all(32.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(info['icon']!, style: const TextStyle(fontSize: 40)),
                const SizedBox(height: 12),
                Text(info['title']!, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(info['description']!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildBankCard() {
    return FutureBuilder<DocumentSnapshot>(
      future: FirebaseFirestore.instance.collection('settings').doc('bankDetails').get(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data() as Map<String, dynamic>? ?? {
          'name': 'Janitha prabath',
          'bank': 'Sampath bank wadduwa',
          'accountNumber': '102657098398'
        };

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [Colors.blueGrey.shade800, Colors.black]),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [BoxShadow(color: Colors.cyanAccent.withOpacity(0.1), blurRadius: 20)],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text("MONTHLY SUBSCRIPTION", style: TextStyle(color: Colors.cyanAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  Text("LKR 350", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const Divider(color: Colors.white10, height: 30),
              _bankDetailRow("Account Name", data['name']),
              const SizedBox(height: 12),
              _bankDetailRow("Bank/Branch", data['bank']),
              const SizedBox(height: 12),
              _bankDetailRow("Account Number", data['accountNumber']),
              const SizedBox(height: 20),
              const Text(
                "Note: Please transfer the exact amount and upload the receipt below.",
                style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _bankDetailRow(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        Text(value, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
      ],
    );
  }

  Widget _buildUploadSection() {
    return Column(
      children: [
        GestureDetector(
          onTap: _pickFile,
          child: Container(
            width: double.infinity,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24, style: BorderStyle.solid),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.cloud_upload_outlined, color: Colors.white54, size: 40),
                const SizedBox(height: 8),
                Text(_fileName ?? 'Tap to select Payment Slip', style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          width: double.infinity,
          height: 55,
          child: ElevatedButton(
            onPressed: _isLoading ? null : _submitPayment,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.cyanAccent.shade700,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _isLoading 
              ? const CircularProgressIndicator(color: Colors.white)
              : const Text("Submit for Review", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
          ),
        ),
      ],
    );
  }

  Widget _buildPromoSection() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.03),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Text("Activate with Connection Code", style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 15),
          TextField(
            controller: _promoCodeController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: "Enter 6-digit Code",
              hintStyle: const TextStyle(color: Colors.white24),
              filled: true,
              fillColor: Colors.black26,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 15),
          TextButton(
            onPressed: _isLoading ? null : _submitPromoCode,
            child: const Text("Apply Code", style: TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
