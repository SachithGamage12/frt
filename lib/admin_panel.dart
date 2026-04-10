import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:math' as math;
import 'style_utils.dart';
import 'firebase_utils.dart';

class AdminPanelPage extends StatefulWidget {
  const AdminPanelPage({super.key});

  @override
  _AdminPanelPageState createState() => _AdminPanelPageState();
}

class _AdminPanelPageState extends State<AdminPanelPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    FirebaseUtils.initializeSecondaryApp();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        automaticallyImplyLeading: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Admin Dashboard', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20)),
            Text('Central Management Hub', style: TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: AppColors.primary),
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.redAccent),
            onPressed: () {
              Navigator.of(context).pushNamedAndRemoveUntil('/', (route) => false);
            },
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: TabBar(
              controller: _tabController,
              indicator: BoxDecoration(
                color: AppColors.primary.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.primary.withOpacity(0.5)),
              ),
              indicatorSize: TabBarIndicatorSize.tab,
              dividerColor: Colors.transparent,
              labelColor: AppColors.primary,
              unselectedLabelColor: Colors.white54,
              labelPadding: EdgeInsets.zero,
              tabs: const [
                Tab(icon: Icon(Icons.analytics_outlined, size: 20), text: 'Stats'),
                Tab(icon: Icon(Icons.verified_user_outlined, size: 20), text: 'Approvals'),
                Tab(icon: Icon(Icons.feedback_outlined, size: 20), text: 'Exit log'),
                Tab(icon: Icon(Icons.account_balance_outlined, size: 20), text: 'Bank'),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDashboard(),
          _buildApprovalsList(),
          _buildCancellationsList(),
          _buildBankSettings(),
        ],
      ),
    );
  }

  Widget _buildDashboard() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('users').snapshots(),
      builder: (context, snapshot1) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseUtils.secondaryFirestore?.collection('users').snapshots() ?? const Stream.empty(),
          builder: (context, snapshot2) {
            if (!snapshot1.hasData) return const Center(child: CircularProgressIndicator());

            var allDocs = [...snapshot1.data!.docs];
            if (snapshot2.hasData && snapshot2.data != null) {
              allDocs.addAll(snapshot2.data!.docs);
            }

            int totalUsers = allDocs.length;
            int activeSubscribers = allDocs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              if (data['subscriptionExpiry'] == null) return false;
              return (data['subscriptionExpiry'] as Timestamp).toDate().isAfter(DateTime.now());
            }).length;

            int pendingApprovals = allDocs.where((doc) {
              final data = doc.data() as Map<String, dynamic>;
              return data['paymentStatus'] == 'pending';
            }).length;

        double totalRevenue = activeSubscribers * 350.0;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Platform Overview",
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              _buildModernMetricRow(
                'Total Users', totalUsers.toString(), Icons.people, Colors.blue,
                'Active Subs', activeSubscribers.toString(), Icons.check_circle, Colors.green,
              ),
              const SizedBox(height: 16),
              _buildModernMetricRow(
                'Pending', pendingApprovals.toString(), Icons.hourglass_empty, Colors.orange,
                'Revenue', 'LKR ${totalRevenue.toStringAsFixed(0)}', Icons.payments, Colors.purple,
              ),
            ],
          ),
        );
          },
        );
      },
    );
  }

  Widget _buildModernMetricRow(String t1, String v1, IconData i1, Color c1, String t2, String v2, IconData i2, Color c2) {
    return Row(
      children: [
        Expanded(child: _buildModernStatCard(t1, v1, i1, c1)),
        const SizedBox(width: 16),
        Expanded(child: _buildModernStatCard(t2, v2, i2, c2)),
      ],
    );
  }

  Widget _buildModernStatCard(String title, String value, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(32),
        border: Border.all(color: color.withOpacity(0.1)),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.05),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            right: -10,
            top: -10,
            child: Icon(icon, color: color.withOpacity(0.05), size: 100),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const Spacer(),
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  letterSpacing: -1,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.5),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildApprovalsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('users').where('paymentStatus', isEqualTo: 'pending').snapshots(),
      builder: (context, snapshot1) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseUtils.secondaryFirestore?.collection('users').where('paymentStatus', isEqualTo: 'pending').snapshots() ?? const Stream.empty(),
          builder: (context, snapshot2) {
            if (!snapshot1.hasData) return const Center(child: CircularProgressIndicator());

            var allDocs = [...snapshot1.data!.docs];
            if (snapshot2.hasData && snapshot2.data != null) {
              allDocs.addAll(snapshot2.data!.docs);
            }

            if (allDocs.isEmpty) {
              return const Center(child: Text('No pending approvals', style: TextStyle(color: Colors.white70)));
            }

            return ListView.builder(
              itemCount: allDocs.length,
              itemBuilder: (context, index) {
                var userDoc = allDocs[index];
            var data = userDoc.data() as Map<String, dynamic>;

            return AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
                gradient: LinearGradient(
                  colors: [Colors.white.withOpacity(0.08), Colors.transparent],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                leading: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [Colors.blue, Colors.cyan]),
                  ),
                  child: CircleAvatar(
                    backgroundImage: data['profilePicture'] != null ? NetworkImage(data['profilePicture']) : null,
                    backgroundColor: AppColors.surface,
                    child: data['profilePicture'] == null ? const Icon(Icons.person, color: Colors.white70) : null,
                  ),
                ),
                title: Text(
                  data['name'] ?? 'Unknown', 
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)
                ),
                subtitle: Text(
                  'Pending • ${userDoc.id}', 
                  style: const TextStyle(color: Colors.white38, fontSize: 11)
                ),
                trailing: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.chevron_right, color: AppColors.primary),
                ),
                onTap: () => _showApprovalDialog(userDoc.id, data),
              ),
            );
          },
        );
          },
        );
      },
    );
  }

  void _showApprovalDialog(String userId, Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.1),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
                ),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 40,
                      backgroundImage: data['profilePicture'] != null ? NetworkImage(data['profilePicture']) : null,
                      backgroundColor: Colors.black26,
                      child: data['profilePicture'] == null ? const Icon(Icons.person, size: 40) : null,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      data['name'] ?? 'Unknown User',
                      style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      userId,
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    const Text('VERIFICATION DOCUMENT', style: TextStyle(color: AppColors.primary, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.2)),
                    const SizedBox(height: 16),
                    if (data['paymentSlipUrl'] != null)
                      GestureDetector(
                        onTap: () async {
                          final Uri url = Uri.parse(data['paymentSlipUrl']);
                          if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                            AppAlerts.show(context, 'Could not open file', isError: true);
                          }
                        },
                        child: Container(
                          height: 200,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white10),
                          ),
                          child: (data['paymentSlipUrl'].toString().toLowerCase().contains('.pdf') || 
                                  data['paymentSlipUrl'].toString().toLowerCase().contains('/pdf/'))
                            ? const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.picture_as_pdf, color: Colors.red, size: 60),
                                  SizedBox(height: 8),
                                  Text('Tap to view PDF', style: TextStyle(color: Colors.white54, fontSize: 12)),
                                ],
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Image.network(data['paymentSlipUrl'], fit: BoxFit.cover),
                              ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () => _handleApproval(userId, false),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: const BorderSide(color: Colors.redAccent),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: const Text('Reject', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton(
                            onPressed: () => _handleApproval(userId, true),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.green,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            ),
                            child: const Text('Approve', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close Review', style: TextStyle(color: Colors.white38)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _handleApproval(String userId, bool approved) async {
    Navigator.pop(context); // Close dialog

    try {
      if (approved) {
        DateTime expiry = DateTime.now().add(const Duration(days: 30));
        // Generate 6-digit promo code (Uppercase + Numbers)
        const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // Avoid confusing O/0, I/1
        String promoCode = '';
        math.Random rnd = math.Random();
        for (var i = 0; i < 6; i++) {
          promoCode += chars[rnd.nextInt(chars.length)];
        }

        final updateData = {
          'isAppUnlocked': true,
          'paymentStatus': 'approved',
          'subscriptionExpiry': Timestamp.fromDate(expiry),
          'approvalDate': FieldValue.serverTimestamp(),
          'promoCode': promoCode,
          'isPromoCodeUsed': false,
          'isFirstLoginAfterApprove': true,
        };
        try { await _firestore.collection('users').doc(userId).update(updateData); } catch(_) {}
        final secFirestore = FirebaseUtils.secondaryFirestore;
        if (secFirestore != null) {
          try { await secFirestore.collection('users').doc(userId).update(updateData); } catch(_) {}
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account Approved! Notification Sent.')));
        AppAlerts.show(context, 'Account Approved! Notification Sent.');
      } else {
        try { await _firestore.collection('users').doc(userId).update({ 'paymentStatus': 'rejected' }); } catch(_) {}
        final secFirestore = FirebaseUtils.secondaryFirestore;
        if (secFirestore != null) {
          try { await secFirestore.collection('users').doc(userId).update({ 'paymentStatus': 'rejected' }); } catch(_) {}
        }
        AppAlerts.show(context, 'Account Rejected.');
      }
    } catch (e) {
      AppAlerts.show(context, 'Error: $e', isError: true);
    }
  }

  Widget _buildCancellationsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('cancellations').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot1) {
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseUtils.secondaryFirestore?.collection('cancellations').orderBy('timestamp', descending: true).snapshots() ?? const Stream.empty(),
          builder: (context, snapshot2) {
            if (!snapshot1.hasData) return const Center(child: CircularProgressIndicator());

            var allDocs = [...snapshot1.data!.docs];
            if (snapshot2.hasData && snapshot2.data != null) {
              allDocs.addAll(snapshot2.data!.docs);
            }

            allDocs.sort((a, b) {
              final valA = (a.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
              final valB = (b.data() as Map<String, dynamic>)['timestamp'] as Timestamp?;
              if (valA == null && valB == null) return 0;
              if (valA == null) return 1;
              if (valB == null) return -1;
              return valB.compareTo(valA);
            });

            if (allDocs.isEmpty) {
              return const Center(child: Text('No cancellation records', style: TextStyle(color: Colors.white70)));
            }

            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: allDocs.length,
              itemBuilder: (context, index) {
                var doc = allDocs[index];
            var data = doc.data() as Map<String, dynamic>;
            DateTime? ts = (data['timestamp'] as Timestamp?)?.toDate();

            return Container(
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        color: Colors.redAccent.withOpacity(0.5),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    data['email'] ?? 'Anonymous',
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                  ),
                                  if (ts != null)
                                    Text(
                                      DateFormat('MMM d').format(ts),
                                      style: const TextStyle(color: Colors.white24, fontSize: 11),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  data['reason']?.toString().toUpperCase() ?? 'OTHER',
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                data['feedback'] ?? 'No additional feedback provided.',
                                style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
          },
        );
      },
    );
  }

  Widget _buildBankSettings() {
    return FutureBuilder<DocumentSnapshot>(
      future: _firestore.collection('settings').doc('bankDetails').get(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        final data = snapshot.data!.data() as Map<String, dynamic>? ?? {
          'name': 'Janitha prabath',
          'bank': 'Sampath bank wadduwa',
          'accountNumber': '102657098398'
        };

        final nameCtrl = TextEditingController(text: data['name']);
        final bankCtrl = TextEditingController(text: data['bank']);
        final accCtrl = TextEditingController(text: data['accountNumber']);

        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Payment Instructions Displayed to Users', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              _buildSettingsField('Account Name', nameCtrl),
              const SizedBox(height: 16),
              _buildSettingsField('Bank & Branch', bankCtrl),
              const SizedBox(height: 16),
              _buildSettingsField('Account Number', accCtrl),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () async {
                    await _firestore.collection('settings').doc('bankDetails').set({
                      'name': nameCtrl.text,
                      'bank': bankCtrl.text,
                      'accountNumber': accCtrl.text,
                      'updatedAt': FieldValue.serverTimestamp(),
                    });
                    AppAlerts.show(context, 'Settings Updated!');
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text('Update Bank Details', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSettingsField(String label, TextEditingController controller) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}
