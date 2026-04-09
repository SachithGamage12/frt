import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

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
    _tabController = TabController(length: 3, vsync: this);
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
          indicatorColor: Colors.blueAccent,
          tabs: const [
            Tab(icon: Icon(Icons.dashboard), text: 'Dashboard'),
            Tab(icon: Icon(Icons.pending_actions), text: 'Approvals'),
            Tab(icon: Icon(Icons.settings), text: 'Bank Settings'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDashboard(),
          _buildApprovalsList(),
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

        double totalRevenue = activeSubscribers * 350.0; // Simplistic calculation

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 16,
            mainAxisSpacing: 16,
            children: [
              _buildStatCard('Total Users', totalUsers.toString(), Colors.blue),
              _buildStatCard('Active Subs', activeSubscribers.toString(), Colors.green),
              _buildStatCard('Pending', pendingApprovals.toString(), Colors.orange),
              _buildStatCard('Revenue (LKR)', totalRevenue.toStringAsFixed(0), Colors.purple),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(title, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w500)),
          const SizedBox(height: 8),
          Text(value, style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
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
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open file')));
                    }
                  },
                  child: data['paymentSlipUrl'].toString().toLowerCase().contains('.pdf')
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
        // TODO: Trigger FCM Notification
      } else {
        await _firestore.collection('users').doc(userId).update({
          'paymentStatus': 'rejected',
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Account Rejected.')));
      }
    } catch (e) {
       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
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
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings Updated!')));
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
