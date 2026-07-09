import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Talks to the MedThru backend (server.js) and holds the current session.
///
/// Extends [ChangeNotifier] so widgets can rebuild when the doctor logs in
/// or out. Base URL differs by platform: the Android emulator reaches the
/// host via 10.0.2.2, while desktop/web use localhost directly.
class MedThruApi extends ChangeNotifier {
  MedThruApi._();
  static final MedThruApi instance = MedThruApi._();

  String? _token;
  Map<String, dynamic>? _doctor;

  Map<String, dynamic>? get doctor => _doctor;
  bool get isLoggedIn => _token != null;
  String? get doctorName => _doctor?['name'] as String?;

  static String get _baseUrl {
    if (!kIsWeb && Platform.isAndroid) {
      return 'http://10.0.2.2:3000/api';
    }
    return 'http://localhost:3000/api';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<void> login(String email, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Login failed');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    _token = data['token'] as String;
    _doctor = data['doctor'] as Map<String, dynamic>;
    notifyListeners();
  }

  void logout() {
    _token = null;
    _doctor = null;
    notifyListeners();
  }

  /// Set a fake session in tests, so auth-dependent UI can be exercised
  /// without a live server. Pass nulls to simulate a signed-out state.
  @visibleForTesting
  void debugSetSession({String? token, Map<String, dynamic>? doctor}) {
    _token = token;
    _doctor = doctor;
    notifyListeners();
  }

  /// Look up a patient by NFC card token. No auth required (physical card
  /// possession is the credential), so patients can view their own record.
  Future<Map<String, dynamic>?> lookupByToken(String token) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/token/$token'),
      headers: _headers,
    );
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Lookup failed');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Register a new patient. The server generates the card token — clients
  /// never choose it — and returns it exactly once, to be written to a blank
  /// tag. Afterwards only a 4-character preview is ever exposed.
  ///
  /// Returns `(patient, cardToken)`.
  Future<({Map<String, dynamic> patient, String cardToken})> createPatient(
      Map<String, dynamic> fields) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients'),
      headers: _headers,
      body: jsonEncode(fields),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not create patient');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      patient: body['patient'] as Map<String, dynamic>,
      cardToken: body['cardToken'] as String,
    );
  }

  /// Revoke the current card and issue a replacement. Use when a card is lost.
  /// The old token stops working immediately.
  Future<({Map<String, dynamic> patient, String cardToken})> reissueCard(
      int patientId) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/$patientId/cards/reissue'),
      headers: _headers,
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not reissue card');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      patient: body['patient'] as Map<String, dynamic>,
      cardToken: body['cardToken'] as String,
    );
  }

  /// Revoke the active card without issuing a replacement.
  Future<void> revokeCard(int patientId) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/$patientId/cards/revoke'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not revoke card');
    }
  }

  /// Doctor updates a patient record. Requires login.
  Future<Map<String, dynamic>> updatePatient(
      String token, Map<String, dynamic> fields) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/patients/token/$token'),
      headers: _headers,
      body: jsonEncode(fields),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Update failed');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Append a clinical update (checkup, med change, etc.) to a patient's
  /// timeline. Requires login.
  Future<Map<String, dynamic>> addNote(
      int patientId, String noteType, String body) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/$patientId/notes'),
      headers: _headers,
      body: jsonEncode({'noteType': noteType, 'body': body}),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not add update');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// The patient's clinical-update timeline, newest first.
  Future<List<Map<String, dynamic>>> getNotes(int patientId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/$patientId/notes'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load updates');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Log a self-measured reading against a card. Deliberately does NOT
  /// require a doctor login — the patient holding the card may record their
  /// own values. The server tags the row as patient- or doctor-sourced.
  Future<Map<String, dynamic>> addReading(
    String token,
    String readingType,
    double value, {
    String? note,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/readings'),
      headers: _headers,
      body: jsonEncode({
        'readingType': readingType,
        'value': value,
        if (note != null && note.isNotEmpty) 'note': note,
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not save reading');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// A patient's readings, newest first. Optionally filtered by type.
  Future<List<Map<String, dynamic>>> getReadings(int patientId,
      {String? type}) async {
    final uri = Uri.parse('$_baseUrl/patients/$patientId/readings')
        .replace(queryParameters: type == null ? null : {'type': type});
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load readings');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Full access history for a patient (reads, edits, who and when).
  Future<List<Map<String, dynamic>>> getAudit(int patientId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/$patientId/audit'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load history');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  Exception _errorFrom(http.Response res, String fallback) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return Exception(body['error'] ?? fallback);
    } catch (_) {
      return Exception('$fallback (${res.statusCode})');
    }
  }
}
