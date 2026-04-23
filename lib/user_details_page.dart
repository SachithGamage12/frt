import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'style_utils.dart';

class UserDetailsPage extends StatefulWidget {
  final Map<String, dynamic> userData;
  final String userId;

  const UserDetailsPage({
    super.key,
    required this.userData,
    required this.userId,
  });

  @override
  _UserDetailsPageState createState() => _UserDetailsPageState();
}

class _UserDetailsPageState extends State<UserDetailsPage> with SingleTickerProviderStateMixin {
  late TextEditingController _nameController;
  bool _isEditing = false;
  bool _isLoggingOut = false;
  bool _showFabMenu = false;

  @override
  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.userData['name'] ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _toggleEditing() {
    setState(() {
      _isEditing = !_isEditing;
      _showFabMenu = false; // Close FAB menu when editing
    });
  }

  Future<void> _saveName() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) {
      AppAlerts.show(context, 'Name cannot be empty', isError: true);
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.userId)
          .update({'name': newName});

      setState(() {
        widget.userData['name'] = newName;
        _isEditing = false;
      });

      AppAlerts.show(context, 'Name updated successfully');
    } catch (e) {
      AppAlerts.show(context, 'Failed to update name: $e', isError: true);
    }
  }

  Future<void> _logout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Logout', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (shouldLogout != true) return;

    setState(() {
      _isLoggingOut = true;
      _showFabMenu = false;
    });

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('mobile');
      await prefs.remove('password');
      await prefs.setBool('rememberMe', false);

      await FirebaseAuth.instance.signOut();

      if (mounted) {
        Navigator.of(context).pushNamedAndRemoveUntil(
          '/',
          (Route<dynamic> route) => false,
        );
      }
    } catch (e) {
      setState(() => _isLoggingOut = false);
      if (mounted) {
        AppAlerts.show(context, 'Logout failed: $e', isError: true);
      }
    }
  }

  void _toggleFabMenu() {
    setState(() {
      _showFabMenu = !_showFabMenu;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Full-screen animated gradient background with pattern overlay
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.background,
                  Colors.black87,
                ],
              ),
            ),
            child: Stack(
              children: [
                // Subtle pattern overlay
                Positioned.fill(
                  child: Opacity(
                    opacity: 0.1,
                    child: Image.asset(
                      'assets/pattern.png',
                      repeat: ImageRepeat.repeat,
                      color: Colors.white,
                    ),
                  ),
                ),
                SafeArea(
                  child: Column(
                    children: [
                      // AppBar replacement
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 10.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back, color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                            ),
                            const Text(
                              'Your Profile',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 48), // Balance layout
                          ],
                        ),
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              // Profile picture (no animation)
                              CircleAvatar(
                                radius: 70,
                                backgroundColor: Colors.white.withOpacity(0.2),
                                backgroundImage: widget.userData['profilePicture'] != null
                                    ? NetworkImage(widget.userData['profilePicture'])
                                    : null,
                                child: widget.userData['profilePicture'] == null
                                    ? const Icon(
                                        Icons.person,
                                        size: 70,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 20),
                              // Name and email (no animation)
                              _isEditing
                                  ? Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 16),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.9),
                                        borderRadius: BorderRadius.circular(12),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.black.withOpacity(0.1),
                                            blurRadius: 8,
                                            offset: const Offset(0, 4),
                                          ),
                                        ],
                                      ),
                                      child: TextFormField(
                                        controller: _nameController,
                                        decoration: const InputDecoration(
                                          labelText: 'Name',
                                          border: InputBorder.none,
                                        ),
                                        style: const TextStyle(fontSize: 18),
                                      ),
                                    )
                                  : Text(
                                      widget.userData['name'] ?? 'No Name',
                                      style: const TextStyle(
                                        fontSize: 28,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                        shadows: [
                                          Shadow(
                                            blurRadius: 4,
                                            color: Colors.black26,
                                            offset: Offset(2, 2),
                                          ),
                                        ],
                                      ),
                                    ),
                              const SizedBox(height: 8),
                              if (widget.userData['email'] != null)
                                Text(
                                  widget.userData['email'],
                                  style: const TextStyle(
                                    fontSize: 16,
                                    color: Colors.white70,
                                  ),
                                ),
                              const SizedBox(height: 30),
                              // Detail cards (no animation)
                              if (widget.userData['mobile'] != null)
                                _buildDetailCard(
                                  icon: Icons.phone,
                                  title: 'Mobile',
                                  value: widget.userData['mobile'],
                                ),
                              const SizedBox(height: 16),
                              if (widget.userData['age'] != null)
                                _buildDetailCard(
                                  icon: Icons.cake,
                                  title: 'Age',
                                  value: widget.userData['age'].toString(),
                                ),
                              const SizedBox(height: 16),
                              if (widget.userData['promoCode'] != null)
                                _buildDetailCard(
                                  icon: Icons.card_giftcard,
                                  title: 'Connection Reward Code',
                                  value: widget.userData['promoCode'],
                                  subtitle: widget.userData['isPromoCodeUsed'] == true 
                                      ? 'Status: Used' 
                                      : 'Status: Available • Tap copy to share',
                                  trailing: IconButton(
                                    icon: const Icon(Icons.copy, color: AppColors.primary, size: 20),
                                    onPressed: () {
                                      Clipboard.setData(ClipboardData(text: widget.userData['promoCode']));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('✅ Code copied to clipboard!')),
                                      );
                                    },
                                  ),
                                ),
                              const SizedBox(height: 30),
                              ElevatedButton.icon(
                                onPressed: () async {
                                  final Uri url = Uri.parse("https://www.lankafrt.com/login.html");
                                  if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
                                    AppAlerts.show(context, 'Could not open website', isError: true);
                                  }
                                },
                                icon: const Icon(Icons.delete_forever_outlined, color: Colors.white),
                                label: const Text("Delete Account", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent.withOpacity(0.2),
                                  foregroundColor: Colors.redAccent,
                                  elevation: 0,
                                  side: const BorderSide(color: Colors.redAccent, width: 1),
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                ),
                              ),
                              const SizedBox(height: 80), // Space for FAB
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Floating Action Button with menu
          Positioned(
            bottom: 16,
            right: 16,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_showFabMenu) ...[
                  FloatingActionButton(
                    heroTag: 'save_edit',
                    mini: true,
                    backgroundColor: Colors.green,
                    onPressed: _isEditing ? _saveName : _toggleEditing,
                    child: Icon(_isEditing ? Icons.save : Icons.edit),
                  ),
                  const SizedBox(height: 8),
                  FloatingActionButton(
                    heroTag: 'logout',
                    mini: true,
                    backgroundColor: Colors.red,
                    onPressed: _logout,
                    child: const Icon(Icons.logout),
                  ),
                  const SizedBox(height: 8),
                ],
                FloatingActionButton(
                  heroTag: 'main_fab',
                  backgroundColor: Colors.blueAccent,
                  onPressed: _toggleFabMenu,
                  child: Icon(_showFabMenu ? Icons.close : Icons.menu, color: Colors.white),
                ),
              ],
            ),
          ),
          // Loading overlay
          if (_isLoggingOut)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDetailCard({
    required IconData icon,
    required String title,
    required String value,
    String? subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassmorphic,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 24, color: AppColors.primary),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.white38,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 18,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: subtitle.contains('Available') ? AppColors.primary : Colors.orangeAccent,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }
}