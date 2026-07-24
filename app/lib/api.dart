import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Thrown by [MedThruApi.lookupByToken] when a raw card tap needs the
/// card's password (the patient has set one up under phone login) and
/// either none was supplied yet or the one supplied was wrong.
class PasswordRequiredException implements Exception {
  const PasswordRequiredException();
}

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
  String? _patientToken;
  Map<String, dynamic>? _patientSession;

  Map<String, dynamic>? get doctor => _doctor;
  bool get isLoggedIn => _token != null;

  /// Card reissue/revoke and deleting a patient record outright are
  /// administrator-only, not something every doctor account can do.
  bool get isAdmin => _doctor?['is_admin'] == true;
  String? get doctorName => _doctor?['name'] as String?;

  Map<String, dynamic>? get patientSession => _patientSession;
  bool get patientIsLoggedIn => _patientToken != null;

  /// Whether the app-wide tap listener (set up in main.dart) is currently
  /// connected to the SSE stream, and whether it's mid-lookup for a tap it
  /// just received. Surfaced here — rather than owned by whichever screen
  /// happens to show a "listening" indicator — because the listener itself
  /// now lives at the app root and runs regardless of which screen is open.
  bool tapStreamListening = false;
  bool tapLookupInProgress = false;

  void setTapStreamListening(bool value) {
    tapStreamListening = value;
    notifyListeners();
  }

  void setTapLookupInProgress(bool value) {
    tapLookupInProgress = value;
    notifyListeners();
  }

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

  Map<String, String> get _patientHeaders => {
        'Content-Type': 'application/json',
        if (_patientToken != null) 'Authorization': 'Bearer $_patientToken',
      };

  /// Card-token routes accept the literal segment "me" to mean "resolve via
  /// the signed-in patient's session" instead of a physical card token.
  Map<String, String> _headersFor(String cardToken) =>
      cardToken == 'me' ? _patientHeaders : _headers;

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

  /// The signed-in doctor's profile (name, email, phone).
  Future<Map<String, dynamic>> getDoctorProfile() async {
    final res = await http.get(Uri.parse('$_baseUrl/auth/me'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load profile');
    }
    final profile = jsonDecode(res.body) as Map<String, dynamic>;
    _doctor = profile;
    notifyListeners();
    return profile;
  }

  /// Update the signed-in doctor's name, email and/or phone.
  Future<Map<String, dynamic>> updateDoctorProfile({
    String? name,
    String? email,
    String? phone,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/auth/me'),
      headers: _headers,
      body: jsonEncode({
        if (name != null) 'name': name,
        if (email != null) 'email': email,
        if (phone != null) 'phone': phone,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update profile');
    }
    final profile = jsonDecode(res.body) as Map<String, dynamic>;
    _doctor = profile;
    notifyListeners();
    return profile;
  }

  /// Change the signed-in doctor's password. Requires the current one.
  Future<void> changePassword(String currentPassword, String newPassword) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/change-password'),
      headers: _headers,
      body: jsonEncode({
        'currentPassword': currentPassword,
        'newPassword': newPassword,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not change password');
    }
  }

  /// Sign a patient in with phone + password, set up in advance while they
  /// held their card. An alternative to tapping the card each time.
  Future<void> patientLogin(String phone, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/auth/patient-login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Login failed');
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    _patientToken = data['token'] as String;
    _patientSession = data['patient'] as Map<String, dynamic>;
    notifyListeners();
  }

  void patientLogout() {
    _patientToken = null;
    _patientSession = null;
    notifyListeners();
  }

  /// Bind phone + password to the card currently in hand, so the patient can
  /// sign in later without it. Requires a real card token, not "me".
  Future<void> setupPatientLogin(
      String cardToken, String phone, String password) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$cardToken/login-setup'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'phone': phone, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not set up phone login');
    }
  }

  /// Set a fake session in tests, so auth-dependent UI can be exercised
  /// without a live server. Pass nulls to simulate a signed-out state.
  @visibleForTesting
  void debugSetSession({String? token, Map<String, dynamic>? doctor}) {
    _token = token;
    _doctor = doctor;
    notifyListeners();
  }

  /// Subscribes to the backend's NFC tap broadcast. `reader.js` runs as a
  /// separate process — it's the only thing actually talking to the
  /// physical reader — so this is how a tap reaches the app: over
  /// Server-Sent Events rather than a function call. Yields each card token
  /// as it's tapped, for `main.dart`'s app-wide tap handler to resolve.
  ///
  /// No `package:sse`/`eventsource` dependency needed — SSE is just a
  /// streamed HTTP response with `data: ...` lines, simple enough to parse
  /// by hand with the `http` package already in use everywhere else here.
  Stream<String> watchTaps() async* {
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$_baseUrl/taps/stream'));
      final response = await client.send(request);
      final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data: ')) continue; // comment/keep-alive lines
        final data = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        final token = data['token'] as String?;
        if (token != null) yield token;
      }
    } finally {
      client.close();
    }
  }

  /// Look up a patient by NFC card token. A raw card tap (not a doctor, not
  /// an already-password-authenticated "me" session) additionally needs
  /// [password] once the patient has opted into a card password — see
  /// [PasswordRequiredException]. Physical possession alone remains the only
  /// requirement for a patient who hasn't set one up.
  Future<Map<String, dynamic>?> lookupByToken(String token, {String? password}) async {
    final uri = Uri.parse('$_baseUrl/patients/token/$token').replace(
      queryParameters: password != null ? {'password': password} : null,
    );
    final res = await http.get(uri, headers: _headersFor(token));
    if (res.statusCode == 404) return null;
    if (res.statusCode == 401 && _isPasswordRequired(res)) {
      throw const PasswordRequiredException();
    }
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Lookup failed');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  bool _isPasswordRequired(http.Response res) {
    try {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return body['passwordRequired'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Every registered patient, optionally filtered by name. Lets a doctor
  /// find someone without their card in hand.
  Future<List<Map<String, dynamic>>> getAllPatients({String? search}) async {
    final uri = Uri.parse('$_baseUrl/patients').replace(
      queryParameters: (search != null && search.isNotEmpty) ? {'q': search} : null,
    );
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load patients');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// The doctor dashboard snapshot: today's schedule, KPI figures,
  /// demographics, this month's appointment tallies and the newest patients —
  /// all in one round trip. Doctor-only.
  Future<Map<String, dynamic>> getDoctorDashboard() async {
    final res = await http.get(Uri.parse('$_baseUrl/doctor/dashboard'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load the dashboard');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// A single patient's full record by id — the doctor-only counterpart to
  /// [lookupByToken], for browsing without a card (e.g. from the directory).
  Future<Map<String, dynamic>> getPatientById(int id) async {
    final res = await http.get(Uri.parse('$_baseUrl/patients/$id'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load patient');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Permanently remove a patient and everything tied to their record. No
  /// undo — the caller should make sure the doctor really meant it.
  Future<void> deletePatient(int id) async {
    final res = await http.delete(Uri.parse('$_baseUrl/patients/$id'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not delete patient');
    }
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
      headers: _headersFor(token),
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

  /// Remove a mistaken reading. [token] may be a card token or "me".
  Future<void> deleteReading(String token, int id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/patients/token/$token/readings/$id'),
      headers: _headersFor(token),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not delete reading');
    }
  }

  // --- Health records ---
  //
  // Allergies, medications, vaccinations and medical history. Same trust
  // rule as readings: reachable with a card (or "me" session), and a doctor
  // may also browse by patient id. Shared helpers since all four categories
  // are shaped the same: create against a token, list against a token, list
  // against a patient id.

  Future<List<Map<String, dynamic>>> _listByToken(String path, String token) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/token/$token/$path'),
      headers: _headersFor(token),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load $path');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Doctor-convenience listing by patient id, same as [getNotes]/[getReadings].
  Future<List<Map<String, dynamic>>> _listByPatientId(String path, int patientId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/$patientId/$path'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load $path');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  Future<Map<String, dynamic>> _addByToken(
      String path, String token, Map<String, dynamic> fields) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/$path'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not save entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _updateByToken(
      String path, String token, int id, Map<String, dynamic> fields) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/patients/token/$token/$path/$id'),
      headers: _headersFor(token),
      body: jsonEncode(fields),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update entry');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> _deleteByToken(String path, String token, int id) async {
    final res = await http.delete(
      Uri.parse('$_baseUrl/patients/token/$token/$path/$id'),
      headers: _headersFor(token),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not delete entry');
    }
  }

  Future<List<Map<String, dynamic>>> getAllergies(String token) =>
      _listByToken('allergies', token);

  Future<List<Map<String, dynamic>>> getAllergiesForPatient(int patientId) =>
      _listByPatientId('allergies', patientId);

  Future<Map<String, dynamic>> addAllergy(
    String token, {
    required String allergen,
    String? reaction,
    String? severity,
    String? note,
  }) =>
      _addByToken('allergies', token, {
        'allergen': allergen,
        if (reaction != null && reaction.isNotEmpty) 'reaction': reaction,
        if (severity != null && severity.isNotEmpty) 'severity': severity,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateAllergy(
    String token,
    int id, {
    required String allergen,
    String? reaction,
    String? severity,
    String? note,
  }) =>
      _updateByToken('allergies', token, id, {
        'allergen': allergen,
        if (reaction != null && reaction.isNotEmpty) 'reaction': reaction,
        if (severity != null && severity.isNotEmpty) 'severity': severity,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteAllergy(String token, int id) => _deleteByToken('allergies', token, id);

  Future<List<Map<String, dynamic>>> getMedications(String token) =>
      _listByToken('medications', token);

  Future<List<Map<String, dynamic>>> getMedicationsForPatient(int patientId) =>
      _listByPatientId('medications', patientId);

  Future<Map<String, dynamic>> addMedication(
    String token, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
  }) =>
      _addByToken('medications', token, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateMedication(
    String token,
    int id, {
    required String name,
    String? dosage,
    String? frequency,
    String? startDate,
    String? endDate,
    String? note,
  }) =>
      _updateByToken('medications', token, id, {
        'name': name,
        if (dosage != null && dosage.isNotEmpty) 'dosage': dosage,
        if (frequency != null && frequency.isNotEmpty) 'frequency': frequency,
        if (startDate != null && startDate.isNotEmpty) 'startDate': startDate,
        if (endDate != null && endDate.isNotEmpty) 'endDate': endDate,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteMedication(String token, int id) => _deleteByToken('medications', token, id);

  Future<List<Map<String, dynamic>>> getVaccinations(String token) =>
      _listByToken('vaccinations', token);

  Future<List<Map<String, dynamic>>> getVaccinationsForPatient(int patientId) =>
      _listByPatientId('vaccinations', patientId);

  Future<Map<String, dynamic>> addVaccination(
    String token, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
  }) =>
      _addByToken('vaccinations', token, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateVaccination(
    String token,
    int id, {
    required String vaccine,
    required String administeredAt,
    int? doseNumber,
    String? nextDue,
    String? note,
  }) =>
      _updateByToken('vaccinations', token, id, {
        'vaccine': vaccine,
        'administeredAt': administeredAt,
        if (doseNumber != null) 'doseNumber': doseNumber,
        if (nextDue != null && nextDue.isNotEmpty) 'nextDue': nextDue,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteVaccination(String token, int id) =>
      _deleteByToken('vaccinations', token, id);

  Future<List<Map<String, dynamic>>> getMedicalHistory(String token) =>
      _listByToken('medical-history', token);

  Future<List<Map<String, dynamic>>> getMedicalHistoryForPatient(int patientId) =>
      _listByPatientId('medical-history', patientId);

  Future<Map<String, dynamic>> addMedicalHistory(
    String token, {
    required String conditionName,
    String? diagnosedAt,
    String? status,
    String? note,
  }) =>
      _addByToken('medical-history', token, {
        'conditionName': conditionName,
        if (diagnosedAt != null && diagnosedAt.isNotEmpty) 'diagnosedAt': diagnosedAt,
        if (status != null && status.isNotEmpty) 'status': status,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateMedicalHistory(
    String token,
    int id, {
    required String conditionName,
    String? diagnosedAt,
    String? status,
    String? note,
  }) =>
      _updateByToken('medical-history', token, id, {
        'conditionName': conditionName,
        if (diagnosedAt != null && diagnosedAt.isNotEmpty) 'diagnosedAt': diagnosedAt,
        if (status != null && status.isNotEmpty) 'status': status,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteMedicalHistory(String token, int id) =>
      _deleteByToken('medical-history', token, id);

  Future<List<Map<String, dynamic>>> getEmergencyContacts(String token) =>
      _listByToken('emergency-contacts', token);

  Future<List<Map<String, dynamic>>> getEmergencyContactsForPatient(int patientId) =>
      _listByPatientId('emergency-contacts', patientId);

  Future<Map<String, dynamic>> addEmergencyContact(
    String token, {
    required String name,
    required String phone,
    String? relationship,
    String? note,
  }) =>
      _addByToken('emergency-contacts', token, {
        'name': name,
        'phone': phone,
        if (relationship != null && relationship.isNotEmpty) 'relationship': relationship,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateEmergencyContact(
    String token,
    int id, {
    required String name,
    required String phone,
    String? relationship,
    String? note,
  }) =>
      _updateByToken('emergency-contacts', token, id, {
        'name': name,
        'phone': phone,
        if (relationship != null && relationship.isNotEmpty) 'relationship': relationship,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteEmergencyContact(String token, int id) =>
      _deleteByToken('emergency-contacts', token, id);

  Future<List<Map<String, dynamic>>> getLabResults(String token) =>
      _listByToken('lab-results', token);

  Future<List<Map<String, dynamic>>> getLabResultsForPatient(int patientId) =>
      _listByPatientId('lab-results', patientId);

  Future<Map<String, dynamic>> addLabResult(
    String token, {
    required String testName,
    String? value,
    String? unit,
    String? referenceRange,
    String? status,
    String? takenAt,
    String? note,
  }) =>
      _addByToken('lab-results', token, {
        'testName': testName,
        if (value != null && value.isNotEmpty) 'value': value,
        if (unit != null && unit.isNotEmpty) 'unit': unit,
        if (referenceRange != null && referenceRange.isNotEmpty) 'referenceRange': referenceRange,
        if (status != null && status.isNotEmpty) 'status': status,
        if (takenAt != null && takenAt.isNotEmpty) 'takenAt': takenAt,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<Map<String, dynamic>> updateLabResult(
    String token,
    int id, {
    required String testName,
    String? value,
    String? unit,
    String? referenceRange,
    String? status,
    String? takenAt,
    String? note,
  }) =>
      _updateByToken('lab-results', token, id, {
        'testName': testName,
        if (value != null && value.isNotEmpty) 'value': value,
        if (unit != null && unit.isNotEmpty) 'unit': unit,
        if (referenceRange != null && referenceRange.isNotEmpty) 'referenceRange': referenceRange,
        if (status != null && status.isNotEmpty) 'status': status,
        if (takenAt != null && takenAt.isNotEmpty) 'takenAt': takenAt,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  Future<void> deleteLabResult(String token, int id) =>
      _deleteByToken('lab-results', token, id);

  Future<List<Map<String, dynamic>>> getDocumentsForPatient(int patientId) =>
      _listByPatientId('documents', patientId);

  /// Upload a file's bytes as base64 JSON. [mimeType] helps the server and the
  /// viewer render it; [filename] is what the patient sees.
  Future<Map<String, dynamic>> uploadDocument(
    String token, {
    required String filename,
    String? mimeType,
    required List<int> bytes,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/documents'),
      headers: _headersFor(token),
      body: jsonEncode({
        'filename': filename,
        if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        'dataBase64': base64Encode(bytes),
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not upload the document');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<void> deleteDocument(String token, int id) =>
      _deleteByToken('documents', token, id);

  /// URL of a document's raw bytes (open by id, matching the other by-id reads).
  String documentFileUrl(int patientId, int docId) =>
      '$_baseUrl/patients/$patientId/documents/$docId/file';

  Future<Uint8List> downloadDocument(int patientId, int docId) async {
    final res = await http.get(Uri.parse(documentFileUrl(patientId, docId)));
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not open the document');
    }
    return res.bodyBytes;
  }

  /// A patient editing their own name and/or date of birth. Narrower than
  /// [updatePatient], which also covers doctor-only clinical fields.
  Future<Map<String, dynamic>> updateMyProfile(
    String token, {
    String? fullName,
    String? dateOfBirth,
    String? gender,
  }) async {
    final res = await http.put(
      Uri.parse('$_baseUrl/patients/token/$token/profile'),
      headers: _headersFor(token),
      body: jsonEncode({
        if (fullName != null) 'fullName': fullName,
        if (dateOfBirth != null) 'dateOfBirth': dateOfBirth,
        if (gender != null) 'gender': gender,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update profile');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  // --- Appointments ---

  /// Registered hospitals and clinics a patient can book into. No auth: you
  /// browse facilities before identifying yourself with a card.
  Future<List<Map<String, dynamic>>> getClinics() async {
    final res = await http.get(Uri.parse('$_baseUrl/clinics'), headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load clinics');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// The bookable start times ("HH:MM") at a clinic on [date] (YYYY-MM-DD),
  /// with slots already taken or now in the past removed.
  Future<List<String>> getAvailability(int clinicId, String date) async {
    final uri = Uri.parse('$_baseUrl/clinics/$clinicId/availability')
        .replace(queryParameters: {'date': date});
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load availability');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return (body['slots'] as List<dynamic>).cast<String>();
  }

  /// Request an appointment against a card. Like readings, this needs no doctor
  /// login — card possession is the patient's credential. The booking lands as
  /// `requested` and holds its slot until a doctor confirms or rejects it.
  ///
  /// [startsAt] is clinic-local "YYYY-MM-DD HH:MM". Throws with the server's
  /// message on a clash (the slot was taken first) or invalid time.
  Future<Map<String, dynamic>> bookAppointment(
    String token, {
    required int clinicId,
    required String startsAt,
    String? reason,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/appointments'),
      headers: _headersFor(token),
      body: jsonEncode({
        'clinicId': clinicId,
        'startsAt': startsAt,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      }),
    );
    if (res.statusCode != 201) {
      throw _errorFrom(res, 'Could not book appointment');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// A patient's own appointments, reached with their card. Newest first.
  Future<List<Map<String, dynamic>>> getMyAppointments(String token) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/token/$token/appointments'),
      headers: _headersFor(token),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load appointments');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Doctor-convenience view by patient id, same as [getNotes]/[getReadings] —
  /// no card needed.
  Future<List<Map<String, dynamic>>> getAppointmentsForPatient(int patientId) async {
    final res = await http.get(
      Uri.parse('$_baseUrl/patients/$patientId/appointments'),
      headers: _headers,
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load appointments');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Cancel one of the cardholder's own appointments, freeing its slot.
  Future<Map<String, dynamic>> cancelAppointment(
      String token, int appointmentId) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/patients/token/$token/appointments/$appointmentId/cancel'),
      headers: _headersFor(token),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not cancel appointment');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// The doctor's approval queue for a given status (default `requested`).
  Future<List<Map<String, dynamic>>> getAppointmentQueue(
      {String status = 'requested'}) async {
    final uri = Uri.parse('$_baseUrl/appointments')
        .replace(queryParameters: {'status': status});
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not load appointment queue');
    }
    return (jsonDecode(res.body) as List<dynamic>).cast<Map<String, dynamic>>();
  }

  /// Doctor decision on a booking: confirm, reject, cancel or complete it.
  Future<Map<String, dynamic>> decideAppointment(
    int appointmentId,
    String status, {
    String? note,
  }) async {
    final res = await http.post(
      Uri.parse('$_baseUrl/appointments/$appointmentId/decision'),
      headers: _headers,
      body: jsonEncode({
        'status': status,
        if (note != null && note.isNotEmpty) 'note': note,
      }),
    );
    if (res.statusCode != 200) {
      throw _errorFrom(res, 'Could not update appointment');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
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
