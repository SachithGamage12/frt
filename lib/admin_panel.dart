import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import 'style_utils.dart';

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('Admin Management Dashboard', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.blueGrey.shade900,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.primary,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard), text: 'Stats'),
            Tab(icon: Icon(Icons.pending_actions), text: 'Approvals'),
            Tab(icon: Icon(Icons.feedback_outlined), text: 'Cancellations'),
            Tab(icon: Icon(Icons.settings), text: 'Bank'),
          ],
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
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        int totalUsers = snapshot.data!.docs.length;
        int activeSubscribers = snapshot.data!.docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          if (data['subscriptionExpiry'] == null) return false;
          return (data['subscriptionExpiry'] as Timestamp).toDate().isAfter(DateTime.now());
        }).length;

        int pendingApprovals = snapshot.data!.docs.where((doc) {
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
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color.withOpacity(0.05),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: color.withOpacity(0.2)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withOpacity(0.1), Colors.transparent],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 16),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(title, style: TextStyle(color: color.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildApprovalsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('users').where('paymentStatus', isEqualTo: 'pending').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        if (snapshot.data!.docs.isEmpty) {
          return const Center(child: Text('No pending approvals', style: TextStyle(color: Colors.white70)));
        }

        return ListView.builder(
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            var userDoc = snapshot.data!.docs[index];
            var data = userDoc.data() as Map<String, dynamic>;

            return Card(
              color: Colors.white.withOpacity(0.05),
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: ListTile(
                leading: CircleAvatar(
                  backgroundImage: data['profilePicture'] != null ? NetworkImage(data['profilePicture']) : null,
                  child: data['profilePicture'] == null ? const Icon(Icons.person) : null,
                ),
                title: Text(data['name'] ?? 'Unknown', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(userDoc.id, style: const TextStyle(color: Colors.white54)),
                trailing: const Icon(Icons.chevron_right, color: Colors.blueAccent),
                onTap: () => _showApprovalDialog(userDoc.id, data),
              ),
            );
          },
        );
      },
    );
  }

  void _showApprovalDialog(String userId, Map<String, dynamic> data) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text('Review Payment: ${data['name']}', style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Payment Slip:', style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 10),
              if (data['paymentSlipUrl'] != null)
                GestureDetector(
                  onTap: () async {
                    final Uri url = Uri.parse(data['paymentSlipUrl']);
                    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                      AppAlerts.show(context, 'Could not open file', isError: true);
                    }
                  },
                  child: (data['paymentSlipUrl'].toString().toLowerCase().contains('.pdf') || 
                          data['paymentSlipUrl'].toString().toLowerCase().contains('/pdf/'))
                    ? Column(
                        children: [
                          const Icon(Icons.picture_as_pdf, color: Colors.red, size: 80),
                          const Text('Tap to view PDF', style: TextStyle(color: Colors.blueAccent)),
                        ],
                      )
                    : Image.network(data['paymentSlipUrl'], height: 300, fit: BoxFit.contain),
                ),
              const SizedBox(height: 20),
              Text('Submitted: ${data['paymentTimestamp'] != null ? DateFormat('yyyy-MM-dd HH:mm').format((data['paymentTimestamp'] as Timestamp).toDate()) : 'N/A'}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () => _handleApproval(userId, false),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade900),
            child: const Text('Reject'),
          ),
          ElevatedButton(
            onPressed: () => _handleApproval(userId, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade900),
            child: const Text('Approve'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleApproval(String userId, bool approved) async {
    Navigator.pop(context); // Close dialog

    try {
      if (approved) {
        DateTime expiry = DateTime.now().add(const Duration(days: 30));
        await _firestore.collection('users').doc(userId).update({
          'isAppUnlocked': true,
          'paymentStatus': 'approved',
          'subscriptionExpiry': Timestamp.fromDate(expiry),
          'approvalDate': FieldValue.serverTimestamp(),
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account Approved! Notification Sent.')));
        AppAlerts.show(context, 'Account Approved! Notification Sent.');
      } else {
        await _firestore.collection('users').doc(userId).update({
          'paymentStatus': 'rejected',
        });
        AppAlerts.show(context, 'Account Rejected.');
      }
    } catch (e) {
      AppAlerts.show(context, 'Error: $e', isError: true);
    }
  }

  Widget _buildCancellationsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: _firestore.collection('cancellations').orderBy('timestamp', descending: true).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        if (snapshot.data!.docs.isEmpty) {
          return const Center(child: Text('No cancellation records', style: TextStyle(color: Colors.white70)));
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: snapshot.data!.docs.length,
          itemBuilder: (context, index) {
            var doc = snapshot.data!.docs[index];
            var data = doc.data() as Map<String, dynamic>;
            DateTime? ts = (data['timestamp'] as Timestamp?)?.toDate();

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.05),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.redAccent.withOpacity(0.1)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(data['email'] ?? 'Unknown User', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      if (ts != null) Text(DateFormat('MMM dd, yr').format(ts), style: const TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text("Reason for leaving:", style: TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(data['reason'] ?? 'No reason provided', style: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic)),
                ],
              ),
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
