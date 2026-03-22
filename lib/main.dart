import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:device_frame/device_frame.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'firebase_options.dart';

// Helper function to generate unique QR code
String _generateUniqueQRCode(String eventId, String userId) {
  final timestamp = DateTime.now().millisecondsSinceEpoch;
  final random = Random().nextInt(9999).toString().padLeft(4, '0');
  return 'CAMPUS_${eventId.substring(0, 8)}_${userId.substring(0, 8)}_${timestamp}_$random';
}

// Helper function to generate and save QR code to local storage
Future<String?> _generateAndSaveQRCode(
  String eventId,
  String userId,
  String eventTitle,
  String userName,
) async {
  try {
    // Generate unique QR code data
    final qrData = _generateUniqueQRCode(eventId, userId);

    // Create QR data with more information
    final qrContent =
        '''
CAMPUS SYNC EVENT REGISTRATION
===============================
Event ID: $eventId
User ID: $userId
Event: $eventTitle
Attendee: $userName
QR Code: $qrData
Registered: ${DateTime.now().toIso8601String()}
===============================
This QR code is your entry pass for the event.
    ''';

    // Generate QR code image
    final qrPainter = QrPainter(
      data: qrContent.trim(),
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      color: const Color(0xFF000000),
      emptyColor: const Color(0xFFFFFFFF),
    );

    final image = await qrPainter.toImageData(300);
    if (image == null) {
      debugPrint('Failed to generate QR code image');
      return null;
    }
    final bytes = image.buffer.asUint8List();

    // Save to local storage
    final directory = await getApplicationDocumentsDirectory();
    final qrCodesDir = Directory('${directory.path}/qr_codes');

    if (!await qrCodesDir.exists()) {
      await qrCodesDir.create(recursive: true);
    }

    final fileName =
        'qr_${eventId}_${userId}_${DateTime.now().millisecondsSinceEpoch}.png';
    final qrPath = '${qrCodesDir.path}/$fileName';
    final file = File(qrPath);

    await file.writeAsBytes(bytes);
    debugPrint('QR code saved locally: $qrPath');

    return qrPath;
  } catch (e) {
    debugPrint('Error generating QR code: $e');
    return null;
  }
}

// Helper function to create image widget from local path or network URL
Widget _buildEventImage(
  String? imagePath,
  String? imageUrl, {
  double height = 150,
  double? width,
}) {
  if (imagePath != null && imagePath.isNotEmpty) {
    try {
      final file = File(imagePath);
      if (file.existsSync()) {
        return Image.file(
          file,
          height: height,
          width: width ?? double.infinity,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) {
            return Container(
              height: height,
              width: width ?? double.infinity,
              color: Colors.grey[300],
              child: Icon(Icons.broken_image, color: Colors.grey[600]),
            );
          },
        );
      }
    } catch (e) {
      debugPrint('Error loading local image: $e');
    }
  }

  if (imageUrl != null && imageUrl.isNotEmpty) {
    return Image.network(
      imageUrl,
      height: height,
      width: width ?? double.infinity,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          height: height,
          width: width ?? double.infinity,
          color: Colors.grey[300],
          child: Icon(Icons.broken_image, color: Colors.grey[600]),
        );
      },
    );
  }

  return Container(
    height: height,
    width: width ?? double.infinity,
    color: Colors.grey[300],
    child: Icon(Icons.image, color: Colors.grey[600]),
  );
}

// Helper function to save image to local storage
Future<String?> _saveImageToLocal(Uint8List imageBytes, String eventId) async {
  try {
    final directory = await getApplicationDocumentsDirectory();
    final eventImagesDir = Directory('${directory.path}/event_images');

    // Create directory if it doesn't exist
    if (!await eventImagesDir.exists()) {
      await eventImagesDir.create(recursive: true);
    }

    final fileName =
        'event_${eventId}_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final imagePath = '${eventImagesDir.path}/$fileName';
    final file = File(imagePath);

    await file.writeAsBytes(imageBytes);
    debugPrint('Image saved locally: $imagePath');

    return imagePath;
  } catch (e) {
    debugPrint('Error saving image locally: $e');
    return null;
  }
}

// Helper function to check if storage object exists
Future<bool> _storageObjectExists(String imageUrl) async {
  try {
    final ref = FirebaseStorage.instance.refFromURL(imageUrl);
    await ref.getMetadata();
    return true;
  } catch (e) {
    debugPrint('Storage object does not exist or is inaccessible: $e');
    return false;
  }
}

// Global Data Manager for reactivity and platform compatibility
class AppData extends ChangeNotifier {
  String? _userName;
  String? get userName => _userName;

  String? _userEmail;
  String? get userEmail => _userEmail;

  String? _userDept;
  String? get userDept => _userDept;

  String? _userCourse;
  String? get userCourse => _userCourse;

  String? _userDivision;
  String? get userDivision => _userDivision;

  String? _profileImageUrl;
  String? get profileImageUrl => _profileImageUrl;

  final List<Map<String, dynamic>> _events = [];
  List<Map<String, dynamic>> get events => _events;

  void addEvent(Map<String, dynamic> event) {
    _events.add(event);
    notifyListeners();
  }

  void updateUserData({
    String? dept,
    String? course,
    String? division,
    String? imageUrl,
  }) {
    if (dept != null) _userDept = dept;
    if (course != null) _userCourse = course;
    if (division != null) _userDivision = division;
    if (imageUrl != null) _profileImageUrl = imageUrl;
    notifyListeners();
  }

  Future<void> loadUserData() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        if (doc.exists) {
          final data = doc.data()!;
          _userName = data['fullName'];
          _userEmail = user.email;
          _userDept = data['department'];
          _userCourse = data['course'];
          _userDivision = data['division'];
          _profileImageUrl = data['profileImageUrl'];
        }
        notifyListeners();
      } catch (e) {
        debugPrint('Error loading user data: $e');
      }
    }
  }
}

final AppData appData = AppData();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    Widget app = MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Campus Sync',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF3F51B5), // Indigo
          primary: const Color(0xFF3F51B5),
          secondary: const Color(0xFF03A9F4), // Light Blue
          surface: const Color(0xFFFFFFFF),
          onSurface: const Color(0xFF212121),
        ),
        scaffoldBackgroundColor: const Color(0xFFFFFFFF),
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Color(0xFF212121)),
          bodyMedium: TextStyle(color: Color(0xFF212121)),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF3F51B5),
          foregroundColor: Colors.white,
        ),
        listTileTheme: const ListTileThemeData(tileColor: Colors.transparent),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          selectedItemColor: Color(0xFF3F51B5),
          unselectedItemColor: Colors.grey,
        ),
      ),
      home: const AuthWrapper(),
    );

    if (kIsWeb && kDebugMode) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          backgroundColor: Colors.grey[200],
          body: Center(
            child: DeviceFrame(
              device: Devices.ios.iPhone13,
              isFrameVisible: true,
              orientation: Orientation.portrait,
              screen: app,
            ),
          ),
        ),
      );
    }

    return app;
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key});

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> {
  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasData) {
          Future.microtask(() => appData.loadUserData());
          return const MainNavigationHolder();
        }
        return const SplashScreen();
      },
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _scaleAnimation = Tween<double>(
      begin: 0.8,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.elasticOut));
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _navigateToLogin() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const LoginPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOutQuart;
          var tween = Tween(
            begin: begin,
            end: end,
          ).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.white, Color(0xFFE8EAF6)],
              ),
            ),
          ),
          Positioned(
            top: -100,
            left: -100,
            child: _buildBlob(300, const Color(0x113F51B5)),
          ),
          Positioned(
            bottom: -50,
            right: -80,
            child: _buildBlob(250, const Color(0x1103A9F4)),
          ),
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: ScaleTransition(
                scale: _scaleAnimation,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withOpacity(0.1),
                            blurRadius: 20,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Image.asset(
                          'android/app/src/logo.png',
                          width: 140,
                          height: 140,
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    const SizedBox(height: 30),
                    const Text(
                      'Campus Sync',
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3F51B5),
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 80),
                    GestureDetector(
                      onTap: _navigateToLogin,
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3F51B5),
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFF3F51B5,
                                  ).withOpacity(0.3),
                                  blurRadius: 15,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: const Icon(
                              Icons.arrow_forward_ios_rounded,
                              color: Colors.white,
                              size: 28,
                            ),
                          ),
                          const SizedBox(height: 15),
                          const Text(
                            'GET STARTED',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF3F51B5),
                              letterSpacing: 2.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBlob(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _obscurePassword = true;
  bool _isAdminMode = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _toggleMode(bool admin) {
    HapticFeedback.selectionClick();
    setState(() {
      _isAdminMode = admin;
    });
  }

  Future<void> _handleLogin() async {
    HapticFeedback.heavyImpact();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty || password.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter all fields')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final userCredential = await FirebaseAuth.instance
          .signInWithEmailAndPassword(email: email, password: password);

      final user = userCredential.user;
      if (user != null) {
        // Fetch user role from Firestore
        final userDoc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .get();
        final userData = userDoc.data() ?? {};
        final role = userData['role'] as String?;

        if (_isAdminMode) {
          if (role == 'admin') {
            if (mounted) {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => const AdminDashboard()),
              );
            }
          } else {
            // Not an admin
            await FirebaseAuth.instance.signOut();
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Access Denied: You do not have admin privileges.',
                  ),
                ),
              );
            }
          }
        } else {
          // User Mode
          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(builder: (context) => const AuthWrapper()),
            );
          }
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message ?? 'Login failed')));
      }
    } catch (e, stacktrace) {
      debugPrint('Login generic error: $e\n$stacktrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An unexpected error occurred: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF212121), Color(0xFF3F51B5)],
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 50,
                ),
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildModeButton('User', !_isAdminMode),
                          _buildModeButton('Admin', _isAdminMode),
                        ],
                      ),
                    ),
                    const SizedBox(height: 30),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                        child: Container(
                          padding: const EdgeInsets.all(30),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.2),
                              width: 1.5,
                            ),
                          ),
                          child: Column(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: const BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                ),
                                child: ClipOval(
                                  child: Image.asset(
                                    'android/app/src/logo.png',
                                    width: 70,
                                    height: 70,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(
                                _isAdminMode ? 'Admin Portal' : 'Campus Sync',
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 30),
                              _buildTextField(
                                _isAdminMode
                                    ? Icons.badge_outlined
                                    : Icons.alternate_email,
                                _isAdminMode ? 'Admin ID' : 'Email Address',
                                _emailController,
                              ),
                              const SizedBox(height: 20),
                              _buildPasswordField(
                                Icons.lock_person_outlined,
                                'Password',
                                _passwordController,
                              ),
                              const SizedBox(height: 35),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : _handleLogin,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.white,
                                    foregroundColor: const Color(0xFF3F51B5),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 18,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(15),
                                    ),
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text(
                                          'Login',
                                          style: TextStyle(
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 25),
                              Visibility(
                                visible: !_isAdminMode,
                                maintainSize: true,
                                maintainAnimation: true,
                                maintainState: true,
                                child: _buildSwitchAuth(
                                  'New here?',
                                  'Create Account',
                                  () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (context) =>
                                            const RegisterPage(),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton(String label, bool isSelected) {
    return GestureDetector(
      onTap: () => _toggleMode(label == 'Admin'),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF3F51B5) : Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    IconData icon,
    String hint,
    TextEditingController controller,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.7)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildPasswordField(
    IconData icon,
    String hint,
    TextEditingController controller,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
      ),
      child: TextField(
        controller: controller,
        obscureText: _obscurePassword,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.7)),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword ? Icons.visibility_off : Icons.visibility,
              color: Colors.white.withOpacity(0.7),
            ),
            onPressed: () =>
                setState(() => _obscurePassword = !_obscurePassword),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildSwitchAuth(String text, String action, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
        ),
        child: RichText(
          text: TextSpan(
            text: "$text ",
            style: TextStyle(
              color: Colors.white.withOpacity(0.9),
              fontSize: 14,
            ),
            children: [
              TextSpan(
                text: action,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController =
      TextEditingController();
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _fadeAnimation = CurvedAnimation(parent: _controller, curve: Curves.easeIn);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  bool _isValidEmail(String email) =>
      RegExp(r'^[a-zA-Z0-9.]+@[a-zA-Z0-9]+\.[a-zA-Z]+').hasMatch(email);

  Future<void> _handleRegister() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final confirm = _confirmPasswordController.text.trim();

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please enter all fields')));
      return;
    }
    if (!_isValidEmail(email)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Invalid email format')));
      return;
    }
    if (password != confirm) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Passwords do not match')));
      return;
    }

    setState(() => _isLoading = true);
    try {
      final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (cred.user != null) {
        // Save Name and Email directly to Firestore
        await FirebaseFirestore.instance
            .collection('users')
            .doc(cred.user!.uid)
            .set({
              'fullName': name,
              'email': email,
              'createdAt': FieldValue.serverTimestamp(),
            });

        // Successful registration. Navigate to LoginPage.
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Account created successfully!')),
          );
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (context) => const LoginPage()),
          );
        }
      }
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? 'Registration failed')),
        );
      }
    } catch (e, stacktrace) {
      debugPrint('Register generic error: $e\n$stacktrace');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('An unexpected error occurred: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF212121), Color(0xFF3F51B5)],
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(30),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(30),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 15, sigmaY: 15),
                    child: Container(
                      padding: const EdgeInsets.all(30),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(30),
                      ),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                            child: ClipOval(
                              child: Image.asset(
                                'android/app/src/logo.png',
                                width: 70,
                                height: 70,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Create Account',
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 30),
                          _buildTextField(
                            Icons.person_outline,
                            'Full Name',
                            _nameController,
                          ),
                          const SizedBox(height: 15),
                          _buildTextField(
                            Icons.alternate_email,
                            'Email Address',
                            _emailController,
                          ),
                          const SizedBox(height: 15),
                          _buildPasswordField(
                            Icons.lock_person_outlined,
                            'Password',
                            _passwordController,
                            _obscurePassword,
                            () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                          ),
                          const SizedBox(height: 15),
                          _buildPasswordField(
                            Icons.lock_reset_outlined,
                            'Confirm Password',
                            _confirmPasswordController,
                            _obscureConfirmPassword,
                            () => setState(
                              () => _obscureConfirmPassword =
                                  !_obscureConfirmPassword,
                            ),
                          ),
                          const SizedBox(height: 30),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: _isLoading ? null : _handleRegister,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: const Color(0xFF3F51B5),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 18,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(15),
                                ),
                              ),
                              child: _isLoading
                                  ? const SizedBox(
                                      height: 20,
                                      width: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Text(
                                      'Register',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextField(
    IconData icon,
    String hint,
    TextEditingController controller,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
      ),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.7)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
      ),
    );
  }

  Widget _buildPasswordField(
    IconData icon,
    String hint,
    TextEditingController controller,
    bool isObscure,
    VoidCallback toggleObscure,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(15),
      ),
      child: TextField(
        controller: controller,
        obscureText: isObscure,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
          prefixIcon: Icon(icon, color: Colors.white.withOpacity(0.7)),
          suffixIcon: IconButton(
            icon: Icon(
              isObscure ? Icons.visibility_off : Icons.visibility,
              color: Colors.white.withOpacity(0.7),
            ),
            onPressed: toggleObscure,
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 18,
          ),
        ),
      ),
    );
  }
}

class AdminDashboard extends StatelessWidget {
  const AdminDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(builder: (context) => const LoginPage()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          final count = snapshot.hasData ? snapshot.data!.docs.length : 0;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF3F51B5), Color(0xFF03A9F4)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      const Icon(Icons.people, color: Colors.white, size: 40),
                      Text(
                        '$count',
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                      const Text(
                        'Total Users',
                        style: TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ListTile(
                  leading: const Icon(Icons.manage_accounts, color: Colors.red),
                  title: const Text('Manage Users'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const ManageUsersPage(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.event, color: Colors.green),
                  title: const Text('Add New Event'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const AddEventPage(),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(
                    Icons.edit_calendar_rounded,
                    color: Colors.orange,
                  ),
                  title: const Text('Manage Events'),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => const ManageEventsPage(),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class ManageUsersPage extends StatelessWidget {
  const ManageUsersPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Users')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final users = snapshot.data!.docs;
          return ListView.builder(
            itemCount: users.length,
            itemBuilder: (context, i) {
              final data = users[i].data() as Map<String, dynamic>;
              return ListTile(
                title: Text(data['fullName'] ?? 'Anonymous'),
                subtitle: Text(data['email'] ?? ''),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () async {
                    await FirebaseFirestore.instance
                        .collection('users')
                        .doc(users[i].id)
                        .delete();
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class ManageEventsPage extends StatelessWidget {
  const ManageEventsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manage Events')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('events').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final events = snapshot.data!.docs;
          if (events.isEmpty)
            return const Center(child: Text('No events published yet.'));

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: events.length,
            itemBuilder: (context, i) {
              final eventId = events[i].id;
              final data = events[i].data() as Map<String, dynamic>;
              final title = data['title'] ?? 'No Title';
              final localImagePath = data['localImagePath'] as String?;
              final imageUrl = data['imageUrl'] as String?; // Legacy support
              final maxReg = data['maxRegistrations'] ?? 100;

              return Card(
                margin: const EdgeInsets.all(12),
                elevation: 3,
                child: Column(
                  children: [
                    _buildEventImage(localImagePath, imageUrl, height: 150),
                    ListTile(
                      title: Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            data['isPaid'] == true
                                ? 'Price: ₹${data['price']}'
                                : 'Free Event',
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<QuerySnapshot>(
                            stream: FirebaseFirestore.instance
                                .collection('events')
                                .doc(eventId)
                                .collection('registrations')
                                .snapshots(),
                            builder: (context, regSnap) {
                              final count = regSnap.hasData
                                  ? regSnap.data!.docs.length
                                  : 0;
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  LinearProgressIndicator(
                                    value: count / maxReg,
                                    backgroundColor: Colors.grey[200],
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      count >= maxReg
                                          ? Colors.red
                                          : Colors.green,
                                    ),
                                    minHeight: 8,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '$count / $maxReg slots filled',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(
                              Icons.people_outline,
                              color: Colors.blue,
                            ),
                            onPressed: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (context) => ViewParticipantsPage(
                                  eventId: eventId,
                                  eventTitle: title,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline,
                              color: Colors.red,
                            ),
                            onPressed: () => _confirmDelete(context, eventId),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _confirmDelete(BuildContext context, String eventId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Event?'),
        content: const Text(
          'Are you sure you want to delete this event? This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              try {
                // First get the event data to find the image URL
                final eventDoc = await FirebaseFirestore.instance
                    .collection('events')
                    .doc(eventId)
                    .get();

                if (eventDoc.exists) {
                  final eventData = eventDoc.data() as Map<String, dynamic>;
                  final imageUrl = eventData['imageUrl'] as String?;

                  // Delete the image from storage if it exists
                  if (imageUrl != null && imageUrl.isNotEmpty) {
                    if (await _storageObjectExists(imageUrl)) {
                      try {
                        final ref = FirebaseStorage.instance.refFromURL(
                          imageUrl,
                        );
                        await ref.delete();
                        debugPrint('Image deleted successfully from storage');
                      } catch (storageError) {
                        debugPrint(
                          'Warning: Could not delete image from storage: $storageError',
                        );
                        // Continue with event deletion even if image deletion fails
                      }
                    } else {
                      debugPrint(
                        'Image no longer exists in storage, skipping deletion',
                      );
                    }
                  }
                }

                // Delete the event document
                await FirebaseFirestore.instance
                    .collection('events')
                    .doc(eventId)
                    .delete();

                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Event deleted successfully')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error deleting event: $e')),
                  );
                }
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class ViewParticipantsPage extends StatelessWidget {
  final String eventId;
  final String eventTitle;
  const ViewParticipantsPage({
    super.key,
    required this.eventId,
    required this.eventTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Participants: $eventTitle')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('events')
            .doc(eventId)
            .collection('registrations')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final registrations = snapshot.data!.docs;
          if (registrations.isEmpty)
            return const Center(child: Text('No participants registered yet.'));

          return ListView.builder(
            itemCount: registrations.length,
            itemBuilder: (context, i) {
              final regData = registrations[i].data() as Map<String, dynamic>;
              return ListTile(
                leading: CircleAvatar(child: Text('${i + 1}')),
                title: Text(regData['userName'] ?? 'Unknown User'),
                subtitle: Text(regData['userEmail'] ?? 'No Email'),
                trailing: Text(
                  regData['registeredAt'] != null
                      ? (regData['registeredAt'] as Timestamp)
                            .toDate()
                            .toString()
                            .split(' ')[0]
                      : '',
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class AddEventPage extends StatefulWidget {
  const AddEventPage({super.key});

  @override
  State<AddEventPage> createState() => _AddEventPageState();
}

class _AddEventPageState extends State<AddEventPage> {
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _venueController = TextEditingController();
  final _priceController = TextEditingController();
  final _maxRegController = TextEditingController(text: '100');
  final TextEditingController _dateController = TextEditingController();
  TimeOfDay? _selectedTime;
  bool _isPaid = false;
  Uint8List? _coverImageBytes;
  bool _isLoading = false;

  Future<void> _pickCoverImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        setState(() => _coverImageBytes = bytes);
      }
    } catch (e) {
      debugPrint('Error picking cover image: $e');
    }
  }

  Future<void> _publishEvent() async {
    final title = _titleController.text.trim();
    final description = _descriptionController.text.trim();
    final venue = _venueController.text.trim();
    final priceStr = _priceController.text.trim();
    final maxRegStr = _maxRegController.text.trim();

    if (title.isEmpty ||
        description.isEmpty ||
        venue.isEmpty ||
        _dateController.text.trim().isEmpty ||
        _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please fill all required fields: title, description, venue, date & time',
          ),
        ),
      );
      return;
    }

    if (_isPaid && priceStr.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter price in INR')),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      final parsedDate = _parseDate(_dateController.text.trim());
      final selectedTime = _selectedTime;

      debugPrint('Date controller text: "${_dateController.text.trim()}"');
      debugPrint('Parsed date: $parsedDate');
      debugPrint('Selected time: $selectedTime');

      if (parsedDate == null || selectedTime == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select both date and time')),
          );
        }
        return;
      }

      String? localImagePath;
      if (_coverImageBytes != null) {
        // Create event first to get ID, then save image locally
        final eventDoc = await FirebaseFirestore.instance
            .collection('events')
            .add({
              'title': title,
              'description': description,
              'venue': venue,
              'eventDate': parsedDate.millisecondsSinceEpoch,
              'eventTime': selectedTime.format(context),
              'isPaid': _isPaid,
              'price': _isPaid ? double.tryParse(priceStr) ?? 0.0 : 0.0,
              'maxRegistrations': int.tryParse(maxRegStr) ?? 100,
              'localImagePath': null, // Will be updated after image save
              'createdAt': FieldValue.serverTimestamp(),
            });

        // Save image locally with the event ID
        localImagePath = await _saveImageToLocal(
          _coverImageBytes!,
          eventDoc.id,
        );

        // Update the event document with the local image path
        if (localImagePath != null) {
          await eventDoc.update({'localImagePath': localImagePath});
          debugPrint('Event created with local image: $localImagePath');
        } else {
          debugPrint('Event created without image (local save failed)');
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Event published successfully!')),
          );
          Navigator.pop(context);
        }
        return; // Exit early since we already created the event
      }

      // Create event without image
      await FirebaseFirestore.instance.collection('events').add({
        'title': title,
        'description': description,
        'venue': venue,
        'eventDate': parsedDate.millisecondsSinceEpoch,
        'eventTime': selectedTime.format(context),
        'isPaid': _isPaid,
        'price': _isPaid ? double.tryParse(priceStr) ?? 0.0 : 0.0,
        'maxRegistrations': int.tryParse(maxRegStr) ?? 100,
        'localImagePath': null,
        'createdAt': FieldValue.serverTimestamp(),
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Event published successfully!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('Error creating event: $e');
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add Event')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSectionTitle('Event Basics'),
                  const SizedBox(height: 16),
                  _buildTextField(
                    'Event Name',
                    _titleController,
                    Icons.title_rounded,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    'Description',
                    _descriptionController,
                    Icons.description_rounded,
                    maxLines: 4,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    'Max Registrations',
                    _maxRegController,
                    Icons.people_alt_rounded,
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildVenueField(),
                  const SizedBox(height: 16),
                  _buildDateField(),
                  const SizedBox(height: 16),
                  _buildTimeField(),

                  const SizedBox(height: 32),
                  _buildSectionTitle('Pricing Details'),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    title: const Text(
                      'Is this a paid event?',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    subtitle: Text(
                      _isPaid
                          ? 'Participants will be charged'
                          : 'Free for all users',
                    ),
                    value: _isPaid,
                    onChanged: (val) => setState(() => _isPaid = val),
                    activeColor: const Color(0xFF3F51B5),
                    contentPadding: EdgeInsets.zero,
                  ),
                  if (_isPaid) ...[
                    const SizedBox(height: 8),
                    _buildTextField(
                      'Price (INR)',
                      _priceController,
                      Icons.currency_rupee_rounded,
                      keyboardType: TextInputType.number,
                    ),
                  ],

                  const SizedBox(height: 32),
                  _buildSectionTitle('Event Cover'),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _pickCoverImage,
                    child: Container(
                      width: double.infinity,
                      height: 200,
                      decoration: BoxDecoration(
                        color: Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.grey[300]!,
                          width: 2,
                          style: BorderStyle.solid,
                        ),
                      ),
                      child: _coverImageBytes != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.memory(
                                _coverImageBytes!,
                                fit: BoxFit.cover,
                              ),
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.add_photo_alternate_rounded,
                                  size: 48,
                                  color: Colors.grey[400],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Tap to select cover image',
                                  style: TextStyle(color: Colors.grey[600]),
                                ),
                              ],
                            ),
                    ),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _publishEvent,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3F51B5),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 18),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                        elevation: 4,
                      ),
                      child: const Text(
                        'Publish Event',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.bold,
        color: Color(0xFF3F51B5),
        letterSpacing: 1.2,
      ),
    );
  }

  Widget _buildVenueField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: TextField(
        controller: _venueController,
        decoration: InputDecoration(
          labelText: 'Venue',
          prefixIcon: Icon(
            Icons.location_on_outlined,
            color: const Color(0xFF3F51B5),
          ),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
      ),
    );
  }

  Widget _buildDateField() {
    return _buildTextField(
      'Event Date (DD/MM/YYYY)',
      _dateController,
      Icons.calendar_today,
      keyboardType: const TextInputType.numberWithOptions(
        signed: true,
        decimal: true,
      ),
    );
  }

  Widget _buildTimeField() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        title: const Text(
          'Event Time',
          style: TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          _selectedTime == null
              ? 'Select time'
              : _selectedTime!.format(context),
        ),
        trailing: const Icon(Icons.access_time, color: Color(0xFF3F51B5)),
        onTap: _pickTime,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
  }

  DateTime? _parseDate(String input) {
    if (input.trim().isEmpty) return null;

    try {
      // Handle both DD/MM/YYYY and DD-MM-YYYY formats
      final parts = input.trim().split(RegExp(r'[/\-]'));
      if (parts.length != 3) return null;

      final day = int.tryParse(parts[0]);
      final month = int.tryParse(parts[1]);
      final year = int.tryParse(parts[2]);

      if (day == null || month == null || year == null) return null;
      if (month < 1 || month > 12 || day < 1 || day > 31) return null;

      final date = DateTime(year, month, day);
      // Allow past dates but show a warning
      if (date.isBefore(DateTime.now())) {
        debugPrint('Warning: Date is in the past');
      }
      return date;
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Invalid date format. Use DD/MM/YYYY or DD-MM-YYYY'),
        ),
      );
      return null;
    }
  }

  Future<void> _pickTime() async {
    final time = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
    );
    if (time != null) {
      setState(() => _selectedTime = time);
    }
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    IconData icon, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboardType ?? TextInputType.text,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFF3F51B5)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}

class MainNavigationHolder extends StatefulWidget {
  const MainNavigationHolder({super.key});

  @override
  State<MainNavigationHolder> createState() => _MainNavigationHolderState();
}

class _MainNavigationHolderState extends State<MainNavigationHolder> {
  int _selectedIndex = 0;
  final _pages = [
    const HomePage(),
    const YourEventsPage(),
    const ProfilePage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Campus Sync'),
        leading: _selectedIndex != 0
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => setState(() => _selectedIndex = 0),
              )
            : null,
        actions: [
          ListenableBuilder(
            listenable: appData,
            builder: (context, _) {
              final hasImage =
                  appData.profileImageUrl != null &&
                  appData.profileImageUrl!.isNotEmpty;
              return GestureDetector(
                onTap: () =>
                    setState(() => _selectedIndex = 2), // Switch to Profile tab
                child: Container(
                  margin: const EdgeInsets.only(right: 16),
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFF3F51B5),
                      width: 1.5,
                    ),
                    image: hasImage
                        ? DecorationImage(
                            image: NetworkImage(appData.profileImageUrl!),
                            fit: BoxFit.cover,
                          )
                        : null,
                    color: hasImage ? null : Colors.grey[200],
                  ),
                  child: hasImage
                      ? null
                      : Center(
                          child: Text(
                            (appData.userName != null &&
                                    appData.userName!.isNotEmpty)
                                ? appData.userName![0].toUpperCase()
                                : '?',
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF3F51B5),
                            ),
                          ),
                        ),
                ),
              );
            },
          ),
        ],
      ),
      body: _pages[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (i) => setState(() => _selectedIndex = i),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.event), label: 'Events'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Profile'),
        ],
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListenableBuilder(
          listenable: appData,
          builder: (context, _) {
            final firstName = (appData.userName ?? 'User').split(' ').first;
            return Padding(
              padding: const EdgeInsets.only(
                left: 20,
                right: 20,
                top: 20,
                bottom: 10,
              ),
              child: Text(
                'Hello $firstName and welcome back! 👋',
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3F51B5),
                ),
              ),
            );
          },
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('events').snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData)
                return const Center(child: CircularProgressIndicator());
              final events = snapshot.data!.docs;
              if (events.isEmpty)
                return const Center(child: Text('No events published yet.'));

              return ListView.builder(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                itemCount: events.length,
                itemBuilder: (context, i) {
                  final eventId = events[i].id;
                  final data = events[i].data() as Map<String, dynamic>;
                  final title = data['title'] ?? 'No Title';
                  final localImagePath = data['localImagePath'] as String?;
                  final imageUrl =
                      data['imageUrl'] as String?; // Legacy support
                  final maxReg = data['maxRegistrations'] ?? 100;

                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    clipBehavior: Clip.antiAlias,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                    elevation: 4,
                    child: InkWell(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => EventDetailsPage(
                            eventId: eventId,
                            eventData: data,
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildEventImage(
                            localImagePath,
                            imageUrl,
                            height: 160,
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            title,
                                            style: const TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                data['isPaid'] == true
                                                    ? 'Price: ₹${data['price']}'
                                                    : 'Free Event',
                                                style: TextStyle(
                                                  color: Colors.grey[600],
                                                ),
                                              ),
                                              if (data['venue'] != null) ...[
                                                Text(
                                                  'Venue: ${data['venue']}',
                                                  style: TextStyle(
                                                    color: Colors.grey[600],
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                              if (data['eventDate'] !=
                                                  null) ...[
                                                Text(
                                                  'Date: ${DateTime.fromMillisecondsSinceEpoch(data['eventDate'] as int).toLocal().toString().split(' ')[0]}',
                                                  style: TextStyle(
                                                    color: Colors.grey[600],
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                              if (data['eventTime'] !=
                                                  null) ...[
                                                Text(
                                                  'Time: ${data['eventTime']}',
                                                  style: TextStyle(
                                                    color: Colors.grey[600],
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    ElevatedButton(
                                      onPressed: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              EventDetailsPage(
                                                eventId: eventId,
                                                eventData: data,
                                              ),
                                        ),
                                      ),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFF3F51B5,
                                        ),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                      ),
                                      child: const Text('RSVP Now'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                StreamBuilder<QuerySnapshot>(
                                  stream: FirebaseFirestore.instance
                                      .collection('events')
                                      .doc(eventId)
                                      .collection('registrations')
                                      .snapshots(),
                                  builder: (context, regSnap) {
                                    final count = regSnap.hasData
                                        ? regSnap.data!.docs.length
                                        : 0;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        LinearProgressIndicator(
                                          value: count / maxReg,
                                          backgroundColor: Colors.grey[200],
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                count >= maxReg
                                                    ? Colors.red
                                                    : const Color(0xFF3F51B5),
                                              ),
                                          minHeight: 8,
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '$count / $maxReg slots filled',
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class EventDetailsPage extends StatefulWidget {
  final String eventId;
  final Map<String, dynamic> eventData;
  const EventDetailsPage({
    super.key,
    required this.eventId,
    required this.eventData,
  });

  @override
  State<EventDetailsPage> createState() => _EventDetailsPageState();
}

class _EventDetailsPageState extends State<EventDetailsPage> {
  bool _isRegistering = false;

  Future<void> _registerForEvent() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Check if event is full
    final maxReg = widget.eventData['maxRegistrations'] ?? 100;
    final regDocs = await FirebaseFirestore.instance
        .collection('events')
        .doc(widget.eventId)
        .collection('registrations')
        .get();
    if (regDocs.docs.length >= maxReg) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sorry, this event is already full!')),
        );
      return;
    }

    // Check if event is paid
    final isPaid = widget.eventData['isPaid'] == true;
    final price = (widget.eventData['price'] as num?)?.toDouble() ?? 0.0;
    final eventTitle = widget.eventData['title'] ?? 'Event';

    if (isPaid && price > 0) {
      // Redirect to payment page for paid events
      if (mounted) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) => PaymentPage(
              eventId: widget.eventId,
              eventTitle: eventTitle,
              amount: price,
            ),
          ),
        );
      }
      return;
    }

    // Direct registration for free events
    setState(() => _isRegistering = true);
    try {
      // Generate QR code
      final qrPath = await _generateAndSaveQRCode(
        widget.eventId,
        user.uid,
        widget.eventData['title'] ?? 'Event',
        appData.userName ?? 'Anonymous',
      );

      await FirebaseFirestore.instance
          .collection('events')
          .doc(widget.eventId)
          .collection('registrations')
          .doc(user.uid)
          .set({
            'userId': user.uid,
            'userName': appData.userName ?? 'Anonymous',
            'userEmail': user.email,
            'registeredAt': FieldValue.serverTimestamp(),
            'qrCode': _generateUniqueQRCode(widget.eventId, user.uid),
            'qrPath': qrPath,
          });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Registered Successfully! QR code generated.'),
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isRegistering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.eventData;
    final maxReg = data['maxRegistrations'] ?? 100;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 300,
            pinned: true,
            flexibleSpace: FlexibleSpaceBar(
              background: _buildEventImage(
                data['localImagePath'] as String?,
                data['imageUrl'] as String?,
                height: 300,
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          data['title'] ?? '',
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1A237E),
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF3F51B5).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          data['isPaid'] == true ? '₹${data['price']}' : 'FREE',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF3F51B5),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('events')
                        .doc(widget.eventId)
                        .collection('registrations')
                        .snapshots(),
                    builder: (context, regSnap) {
                      final count = regSnap.hasData
                          ? regSnap.data!.docs.length
                          : 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(
                            value: count / maxReg,
                            backgroundColor: Colors.grey[200],
                            valueColor: AlwaysStoppedAnimation<Color>(
                              count >= maxReg
                                  ? Colors.red
                                  : const Color(0xFF3F51B5),
                            ),
                            minHeight: 10,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$count / $maxReg registrations',
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.blueGrey,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'About this event',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    data['description'] ?? '',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.6,
                      color: Colors.grey[800],
                    ),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: double.infinity,
                    height: 60,
                    child: ElevatedButton(
                      onPressed: _isRegistering ? null : _registerForEvent,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3F51B5),
                        foregroundColor: Colors.white,
                        elevation: 8,
                        shadowColor: const Color(0xFF3F51B5).withOpacity(0.4),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                      ),
                      child: _isRegistering
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text(
                              'Register Now',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 1.2,
                              ),
                            ),
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

class YourEventsPage extends StatelessWidget {
  const YourEventsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(child: Text('Your Registered Events'));
  }
}

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final TextEditingController _deptController = TextEditingController();
  final TextEditingController _courseController = TextEditingController();
  final TextEditingController _divController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _deptController.text = appData.userDept ?? '';
    _courseController.text = appData.userCourse ?? '';
    _divController.text = appData.userDivision ?? '';
  }

  @override
  void dispose() {
    _deptController.dispose();
    _courseController.dispose();
    _divController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final picker = ImagePicker();
      final picked = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 75,
      );
      if (picked != null) {
        setState(() => _isLoading = true);
        final bytes = await picked.readAsBytes();
        final user = FirebaseAuth.instance.currentUser;
        if (user != null) {
          final storageRef = FirebaseStorage.instance.ref().child(
            'profile_images/${user.uid}.jpg',
          );
          await storageRef.putData(
            bytes,
            SettableMetadata(contentType: 'image/jpeg'),
          );
          final url = await storageRef.getDownloadURL();
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .update({'profileImageUrl': url});
          appData.updateUserData(imageUrl: url);
          if (mounted)
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Profile picture updated')),
            );
        }
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error updating image: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _saveProfile() async {
    final dept = _deptController.text.trim();
    final course = _courseController.text.trim();
    final div = _divController.text.trim();

    setState(() => _isLoading = true);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .update({'department': dept, 'course': course, 'division': div});
        appData.updateUserData(dept: dept, course: course, division: div);
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile saved successfully!')),
          );
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error saving profile: $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildRegisteredEventsSection() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          'Please log in to view your registered events',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.event_available, color: Color(0xFF3F51B5), size: 28),
              SizedBox(width: 12),
              Text(
                'Your Registered Events',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF3F51B5),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 280,
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collectionGroup('registrations')
                .where('userId', isEqualTo: user.uid)
                .orderBy('registeredAt', descending: true)
                .limit(5)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: Colors.red[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Error loading events',
                          style: TextStyle(color: Colors.red[400]),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Please check your connection and try again',
                          style: TextStyle(color: Colors.grey[600]),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              }
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final registrations = snapshot.data?.docs ?? [];
              if (registrations.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(30),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.event_busy,
                        size: 64,
                        color: Color(0xFF9E9E9E),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No registered events yet',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF757575),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Register for events from the Home tab to get started!',
                        style: TextStyle(color: Colors.grey[500]),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: registrations.length,
                itemBuilder: (context, i) {
                  final regDoc = registrations[i];
                  final eventId = regDoc.reference.parent.parent?.id ?? '';
                  if (eventId.isEmpty) {
                    return const ListTile(
                      title: Text('Event ID unavailable'),
                      subtitle: Text('Cannot locate event details'),
                    );
                  }
                  return StreamBuilder<DocumentSnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('events')
                        .doc(eventId)
                        .snapshots(),
                    builder: (context, eventSnap) {
                      if (eventSnap.hasError) {
                        return const ListTile(
                          leading: Icon(Icons.error_outline, color: Colors.red),
                          title: Text('Error loading event'),
                          subtitle: Text('Please try again later'),
                        );
                      }
                      if (!eventSnap.hasData ||
                          !(eventSnap.data?.exists ?? false)) {
                        return const ListTile(
                          leading: Icon(Icons.event_busy, color: Colors.grey),
                          title: Text('Event unavailable'),
                          subtitle: Text('This event may have been deleted'),
                        );
                      }
                      final eventData =
                          eventSnap.data?.data() as Map<String, dynamic>? ?? {};
                      return Card(
                        margin: EdgeInsets.only(bottom: 12),
                        child: ListTile(
                          dense: true,
                          leading: Builder(
                            builder: (context) {
                              final localImagePath =
                                  eventData['localImagePath'] as String?;
                              final imageUrl = eventData['imageUrl'] as String?;
                              return _buildEventImage(
                                localImagePath,
                                imageUrl,
                                height: 50,
                                width: 50,
                              );
                            },
                          ),
                          title: Text(
                            eventData['title'] ?? 'Untitled Event',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (eventData['venue'] != null)
                                Text(
                                  eventData['venue'],
                                  style: TextStyle(fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (eventData['eventDate'] != null)
                                Text(
                                  eventData['eventDate'] != null
                                      ? DateTime.fromMillisecondsSinceEpoch(
                                          eventData['eventDate'] as int,
                                        ).toLocal().toString().split(' ')[0]
                                      : DateTime.now()
                                            .toLocal()
                                            .toString()
                                            .split(' ')[0],
                                  style: TextStyle(fontSize: 12),
                                ),
                              Text(
                                eventData['eventTime'] ?? 'Time TBD',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                eventData['isPaid'] == true
                                    ? '₹${eventData['price'] ?? 0}'
                                    : 'Free',
                                style: TextStyle(
                                  color: Color(0xFF4CAF50),
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                          trailing: Icon(
                            Icons.check_circle,
                            color: Colors.green,
                            size: 24,
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => EventDetailsPage(
                                eventId: eventId,
                                eventData: eventData,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: appData,
      builder: (context, _) {
        final hasImage =
            appData.profileImageUrl != null &&
            appData.profileImageUrl!.isNotEmpty;
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            // Profile Header Card
            Container(
              width: double.infinity,
              padding: const EdgeInsets.only(top: 40, bottom: 30),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF1A237E),
                    Color(0xFF3F51B5),
                    Color(0xFF03A9F4),
                  ],
                ),
                borderRadius: BorderRadius.only(
                  bottomLeft: Radius.circular(30),
                  bottomRight: Radius.circular(30),
                ),
              ),
              child: Column(
                children: [
                  // Profile picture
                  GestureDetector(
                    onTap: _isLoading ? null : _pickImage,
                    child: Stack(
                      children: [
                        Container(
                          width: 100,
                          height: 100,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 3),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.3),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                            image: hasImage
                                ? DecorationImage(
                                    image: NetworkImage(
                                      appData.profileImageUrl!,
                                    ),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                            color: hasImage ? null : Colors.white,
                          ),
                          child: hasImage
                              ? null
                              : Center(
                                  child: Text(
                                    (appData.userName != null &&
                                            appData.userName!.isNotEmpty)
                                        ? appData.userName![0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                      fontSize: 40,
                                      fontWeight: FontWeight.bold,
                                      color: Color(0xFF3F51B5),
                                    ),
                                  ),
                                ),
                        ),
                        if (_isLoading)
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.black.withValues(alpha: 0.5),
                            ),
                            child: const Center(
                              child: CircularProgressIndicator(
                                color: Colors.white,
                              ),
                            ),
                          ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                              color: Colors.greenAccent,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.camera_alt,
                              color: Colors.white,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    appData.userName ?? 'Loading...',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    appData.userEmail ?? '',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Edit Form Section
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Edit Details',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blueGrey,
                    ),
                  ),
                  const SizedBox(height: 15),
                  _buildEditField(
                    Icons.business_rounded,
                    'Department',
                    _deptController,
                  ),
                  const SizedBox(height: 15),
                  _buildEditField(
                    Icons.school_rounded,
                    'Course',
                    _courseController,
                  ),
                  const SizedBox(height: 15),
                  _buildEditField(
                    Icons.groups_rounded,
                    'Division',
                    _divController,
                  ),
                  const SizedBox(height: 25),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _isLoading ? null : _saveProfile,
                      icon: const Icon(Icons.save),
                      label: const Text(
                        'Save Profile',
                        style: TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3F51B5),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Help & Support'),
                            content: const Text(
                              'For any queries or support, please contact us at support@campussync.com',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context),
                                child: const Text('Close'),
                              ),
                            ],
                          ),
                        );
                      },
                      icon: const Icon(
                        Icons.help_outline_rounded,
                        color: Color(0xFF3F51B5),
                        size: 20,
                      ),
                      label: const Text(
                        'Help & Support',
                        style: TextStyle(
                          color: Color(0xFF3F51B5),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(
                          color: Color(0xFF3F51B5),
                          width: 1.5,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  _buildRegisteredEventsSection(),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => const QRCodeDisplayPage(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.qr_code_scanner),
                      label: const Text('View My QR Codes'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3F51B5),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await FirebaseAuth.instance.signOut();
                      },
                      icon: const Icon(
                        Icons.logout_rounded,
                        color: Colors.red,
                        size: 20,
                      ),
                      label: const Text(
                        'Logout',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.red, width: 1.5),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEditField(
    IconData icon,
    String label,
    TextEditingController controller,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFF3F51B5)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}

// Dummy Payment Page
class PaymentPage extends StatefulWidget {
  final String eventId;
  final String eventTitle;
  final double amount;

  const PaymentPage({
    super.key,
    required this.eventId,
    required this.eventTitle,
    required this.amount,
  });

  @override
  State<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends State<PaymentPage> {
  final _cardNumberController = TextEditingController();
  final _cardHolderController = TextEditingController();
  final _expiryController = TextEditingController();
  final _cvvController = TextEditingController();
  bool _isProcessing = false;

  @override
  void dispose() {
    _cardNumberController.dispose();
    _cardHolderController.dispose();
    _expiryController.dispose();
    _cvvController.dispose();
    super.dispose();
  }

  Future<void> _processPayment() async {
    if (_cardNumberController.text.length < 16 ||
        _cardHolderController.text.isEmpty ||
        _expiryController.text.isEmpty ||
        _cvvController.text.length < 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please fill all payment details correctly'),
        ),
      );
      return;
    }

    setState(() => _isProcessing = true);

    // Simulate payment processing
    await Future.delayed(const Duration(seconds: 3));

    // Register for the event after successful payment
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        // Generate QR code
        final qrPath = await _generateAndSaveQRCode(
          widget.eventId,
          user.uid,
          widget.eventTitle,
          appData.userName ?? 'Anonymous',
        );

        await FirebaseFirestore.instance
            .collection('events')
            .doc(widget.eventId)
            .collection('registrations')
            .doc(user.uid)
            .set({
              'userId': user.uid,
              'userName': appData.userName ?? 'Anonymous',
              'userEmail': user.email,
              'registeredAt': FieldValue.serverTimestamp(),
              'paymentAmount': widget.amount,
              'paymentMethod': 'Card',
              'paidAt': FieldValue.serverTimestamp(),
              'qrCode': _generateUniqueQRCode(widget.eventId, user.uid),
              'qrPath': qrPath,
            });
      }
    } catch (e) {
      debugPrint('Error registering after payment: $e');
      // Continue to success page even if registration fails
    }

    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (context) => PaymentSuccessPage(
            eventTitle: widget.eventTitle,
            amount: widget.amount,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment'),
        backgroundColor: const Color(0xFF3F51B5),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Event: ${widget.eventTitle}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Amount: ₹${widget.amount.toStringAsFixed(2)}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color(0xFF4CAF50),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'Payment Details',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            _buildPaymentField(
              controller: _cardNumberController,
              label: 'Card Number',
              icon: Icons.credit_card,
              keyboardType: TextInputType.number,
              maxLength: 16,
            ),
            const SizedBox(height: 15),
            _buildPaymentField(
              controller: _cardHolderController,
              label: 'Card Holder Name',
              icon: Icons.person,
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                Expanded(
                  child: _buildPaymentField(
                    controller: _expiryController,
                    label: 'MM/YY',
                    icon: Icons.calendar_today,
                    maxLength: 5,
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: _buildPaymentField(
                    controller: _cvvController,
                    label: 'CVV',
                    icon: Icons.lock,
                    keyboardType: TextInputType.number,
                    maxLength: 3,
                    obscureText: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isProcessing ? null : _processPayment,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: _isProcessing
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: 10),
                          Text('Processing...'),
                        ],
                      )
                    : Text(
                        'Pay ₹${widget.amount.toStringAsFixed(2)}',
                        style: const TextStyle(fontSize: 16),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Note: This is a dummy payment gateway for demonstration purposes only.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    TextInputType? keyboardType,
    int? maxLength,
    bool obscureText = false,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        maxLength: maxLength,
        obscureText: obscureText,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon, color: const Color(0xFF3F51B5)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}

// Payment Success Page
class PaymentSuccessPage extends StatefulWidget {
  final String eventTitle;
  final double amount;

  const PaymentSuccessPage({
    super.key,
    required this.eventTitle,
    required this.amount,
  });

  @override
  State<PaymentSuccessPage> createState() => _PaymentSuccessPageState();
}

class _PaymentSuccessPageState extends State<PaymentSuccessPage> {
  int _countdown = 7;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startCountdown();
  }

  void _startCountdown() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown > 0) {
        setState(() {
          _countdown--;
        });
      } else {
        timer.cancel();
        _redirectToHome();
      }
    });
  }

  void _redirectToHome() {
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const HomePage()),
        (route) => false,
      );
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF4CAF50),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 100,
              height: 100,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.2),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: const Icon(
                Icons.check,
                size: 60,
                color: Color(0xFF4CAF50),
              ),
            ),
            const SizedBox(height: 30),
            const Text(
              'Payment Successful!',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 15),
            Text(
              'Registration for ${widget.eventTitle}',
              style: const TextStyle(fontSize: 18, color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Amount: ₹${widget.amount.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 16, color: Colors.white70),
            ),
            const SizedBox(height: 40),
            Container(
              padding: const EdgeInsets.all(20),
              margin: const EdgeInsets.symmetric(horizontal: 40),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(15),
              ),
              child: Column(
                children: [
                  const Text(
                    'You will be redirected to home in',
                    style: TextStyle(fontSize: 16, color: Colors.white),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '$_countdown seconds',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: _redirectToHome,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF4CAF50),
                padding: const EdgeInsets.symmetric(
                  horizontal: 30,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(25),
                ),
              ),
              child: const Text('Go to Home Now'),
            ),
          ],
        ),
      ),
    );
  }
}

// QR Code Display Page
class QRCodeDisplayPage extends StatefulWidget {
  const QRCodeDisplayPage({super.key});

  @override
  State<QRCodeDisplayPage> createState() => _QRCodeDisplayPageState();
}

class _QRCodeDisplayPageState extends State<QRCodeDisplayPage> {
  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Scaffold(
        body: Center(child: Text('Please log in to view QR codes')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Event QR Codes'),
        backgroundColor: const Color(0xFF3F51B5),
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collectionGroup('registrations')
            .where('userId', isEqualTo: user.uid)
            .orderBy('registeredAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          final registrations = snapshot.data?.docs ?? [];
          if (registrations.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.qr_code_scanner, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'No QR codes found',
                    style: TextStyle(fontSize: 18, color: Colors.grey),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Register for events to generate QR codes',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: registrations.length,
            itemBuilder: (context, index) {
              final regDoc = registrations[index];
              final regData = regDoc.data() as Map<String, dynamic>;
              final qrPath = regData['qrPath'] as String?;
              final qrCode = regData['qrCode'] as String?;
              final eventId = regDoc.reference.parent.parent?.id ?? '';

              return FutureBuilder<DocumentSnapshot>(
                future: FirebaseFirestore.instance
                    .collection('events')
                    .doc(eventId)
                    .get(),
                builder: (context, eventSnap) {
                  final eventData =
                      eventSnap.data?.data() as Map<String, dynamic>? ?? {};
                  final eventTitle = eventData['title'] ?? 'Unknown Event';

                  return Card(
                    margin: const EdgeInsets.only(bottom: 16),
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            eventTitle,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          if (qrPath != null)
                            Center(
                              child: Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 4,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Image.file(
                                  File(qrPath),
                                  width: 200,
                                  height: 200,
                                ),
                              ),
                            )
                          else
                            Center(
                              child: Container(
                                width: 200,
                                height: 200,
                                decoration: BoxDecoration(
                                  color: Colors.grey[200],
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(
                                      Icons.qr_code,
                                      size: 64,
                                      color: Colors.grey,
                                    ),
                                    SizedBox(height: 8),
                                    Text(
                                      'QR Code',
                                      style: TextStyle(color: Colors.grey),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          const SizedBox(height: 12),
                          if (qrCode != null)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'QR Code:',
                                  style: TextStyle(fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.grey[100],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    qrCode,
                                    style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 8),
                          Text(
                            'Registered: ${DateTime.fromMillisecondsSinceEpoch(regData['registeredAt']?.millisecondsSinceEpoch ?? 0).toString().split('.')[0]}',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
