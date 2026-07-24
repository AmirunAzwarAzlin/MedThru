import 'package:flutter/material.dart';
import '../../readings.dart';
import '../../theme.dart';
import '../../widgets.dart';
import '../health_records/health_record_list_screen.dart';
import '../health_records/vitals_record_screen.dart';
import '../health_records/documents_screen.dart';

/// The full health record, organized into sections: allergies, anthropometry,
/// medical history, medications, vaccinations and vital signs. Each section
/// loads and adds independently, so one slow or failing category never blocks
/// the rest of the record from being visible.
/// A menu of the six Health Records categories. Each row is a door, not a
/// drawer: tapping it pushes a dedicated page instead of expanding content
/// inline, so this tab stays a short, scannable list.
/// Health Records is a pushed screen, reached only from the Home dashboard
/// tile. Its own body is just a menu, so no data of its own to fetch here.
class HealthRecordsMenuScreen extends StatelessWidget {
  const HealthRecordsMenuScreen({
    super.key,
    required this.patientId,
    required this.cardToken,
  });
  final int patientId;
  final String cardToken;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Health records')),
      body: BoundedBody(
        maxWidth: 640,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
            Text(
              'Tap a category to view and add entries.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            _CategoryTile(
              icon: Icons.warning_amber_outlined,
              color: MedThruTheme.iconRed,
              tile: MedThruTheme.tileRed,
              title: 'Allergies & intolerances',
              subtitle: 'Allergens, reactions and severity',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: allergyRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.straighten_outlined,
              color: MedThruTheme.iconBlue,
              tile: MedThruTheme.tileBlue,
              title: 'Anthropometry',
              subtitle: 'Height and weight over time',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VitalsRecordScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    category: ReadingCategory.anthropometry,
                    title: 'Anthropometry',
                    emptyLabel: 'No measurements logged yet.',
                    initialType: 'weight',
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.history_edu_outlined,
              color: MedThruTheme.iconPurple,
              tile: MedThruTheme.tilePurple,
              title: 'Medical history',
              subtitle: 'Past and ongoing diagnoses',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: medicalHistoryRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.medication_outlined,
              color: MedThruTheme.iconGreen,
              tile: MedThruTheme.tileGreen,
              title: 'Medications',
              subtitle: 'Dosage, frequency and dates',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: medicationRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.vaccines_outlined,
              color: MedThruTheme.iconBlue,
              tile: MedThruTheme.tileBlue,
              title: 'Vaccinations',
              subtitle: 'Doses and dates administered',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: vaccinationRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.science_outlined,
              color: MedThruTheme.iconGreen,
              tile: MedThruTheme.tileGreen,
              title: 'Lab results',
              subtitle: 'Test values, ranges and status',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: labResultRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.folder_copy_outlined,
              color: MedThruTheme.iconBlue,
              tile: MedThruTheme.tileBlue,
              title: 'Documents',
              subtitle: 'Scans, referral letters and reports',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DocumentsScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.contact_emergency_outlined,
              color: MedThruTheme.iconPurple,
              tile: MedThruTheme.tilePurple,
              title: 'Emergency contacts',
              subtitle: 'Who to call, and how they\'re related',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => HealthRecordListScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    config: emergencyContactRecordConfig,
                  ),
                ),
              ),
            ),
            _CategoryTile(
              icon: Icons.monitor_heart_outlined,
              color: MedThruTheme.iconRed,
              tile: MedThruTheme.tileRed,
              title: 'Vital signs',
              subtitle: 'Blood sugar, pressure, heart rate and more',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VitalsRecordScreen(
                    patientId: patientId,
                    cardToken: cardToken,
                    category: ReadingCategory.vital,
                    title: 'Vital signs',
                    emptyLabel: 'No vitals logged yet.',
                    initialType: 'blood_sugar',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the Health Records menu.
class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.icon,
    required this.color,
    required this.tile,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final Color tile;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: isDark ? color.withValues(alpha: 0.18) : tile,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: isDark ? tile : color, size: 22),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: scheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
        ),
        trailing: Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
      ),
    );
  }
}
