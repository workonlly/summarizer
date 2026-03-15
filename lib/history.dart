import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // Pure white background
      appBar: AppBar(
        backgroundColor: Colors.white, // Matches the scaffold
        elevation: 0,
        // The back button will automatically be added and styled dark here
        iconTheme: IconThemeData(color: Colors.blueGrey.shade900),
        title: Text(
          'Summary History',
          style: GoogleFonts.poppins(
            color: Colors.blueGrey.shade900, // Dark text for white background
            fontWeight: FontWeight.w600,
            fontSize: 18,
          ),
        ),
        centerTitle: true,
      ),
      // A clean, empty body waiting for your future data
      body: Center(
        child: Text(
          "No history available yet.",
          style: GoogleFonts.poppins(
            color: Colors.blueGrey.shade400, // Dim grey text for the placeholder
            fontSize: 15,
          ),
        ),
      ),
    );
  }
}