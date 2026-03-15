import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_fonts/google_fonts.dart';
import 'main.dart'; 

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _mobileController = TextEditingController();
  
  bool _isLoading = false; 

  Future<void> _saveData() async {
    FocusScope.of(context).unfocus();

    if (_nameController.text.isEmpty || 
        _emailController.text.isEmpty || 
        _mobileController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please fill in all fields to continue.'),
          backgroundColor: Colors.blueGrey.shade800, // Professional dark grey for errors
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    await Future.delayed(const Duration(milliseconds: 600));

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('userName', _nameController.text.trim());
    await prefs.setString('userEmail', _emailController.text.trim());
    await prefs.setString('userMobile', _mobileController.text.trim());

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MyApp()),
      );
    }
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blue.shade50.withOpacity(0.3), // Very subtle blue tint
        borderRadius: BorderRadius.circular(12), // Slightly sharper corners for a pro look
        border: Border.all(color: Colors.blue.shade100),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        style: GoogleFonts.poppins(fontSize: 15, color: Colors.blueGrey.shade900),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: GoogleFonts.poppins(color: Colors.blueGrey.shade400, fontSize: 15),
          prefixIcon: Icon(icon, color: Colors.blue.shade400),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 48.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Icon/Logo Area
                Center(
                  child: Container(
                    height: 85,
                    width: 85,
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(24), // Squircle shape
                    ),
                    child: Icon(
                      Icons.shield_outlined, // Changed to a shield for privacy/trust
                      size: 40, 
                      color: Colors.blue.shade600,
                    ),
                  ),
                ),
                const SizedBox(height: 48),

                // Welcome Text
                Text(
                  "Let's get started",
                  style: GoogleFonts.poppins(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: Colors.blueGrey.shade900,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Set up your local profile to start summarizing your notifications securely.",
                  style: GoogleFonts.poppins(
                    fontSize: 14,
                    color: Colors.blueGrey.shade500,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 40),

                // Input Fields
                _buildTextField(
                  controller: _nameController,
                  hintText: 'Full Name',
                  icon: Icons.person_outline,
                ),
                const SizedBox(height: 16),
                
                _buildTextField(
                  controller: _emailController,
                  hintText: 'Email Address',
                  icon: Icons.email_outlined,
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 16),
                
                _buildTextField(
                  controller: _mobileController,
                  hintText: 'Mobile Number',
                  icon: Icons.phone_outlined,
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 48),

                // Fancy Save Button
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _saveData,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700, // Trustworthy corporate blue
                      foregroundColor: Colors.white,
                      elevation: 0, // Flat design is more modern/professional
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            height: 24,
                            width: 24,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            'Save & Continue',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.3,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}