from docx import Document
from docx.shared import Pt, Inches, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement
import os

MEDIA = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'unz', 'word', 'media')
OUT = r'c:\Users\amiru\Desktop\Track1_MEDTHRU_Proposal.docx'

FONT = 'Arial'
BODY_PT = 11
TABLE_PT = 10

doc = Document()

# ---------- page setup: A4, 1in margins ----------
s = doc.sections[0]
s.page_width = Inches(8.27)
s.page_height = Inches(11.69)
s.left_margin = s.right_margin = s.top_margin = s.bottom_margin = Inches(1.0)

def set_font(style, name=FONT, size=BODY_PT, bold=None, color=None):
    style.font.name = name
    style.font.size = Pt(size)
    if bold is not None:
        style.font.bold = bold
    if color is not None:
        style.font.color.rgb = color
    rpr = style.element.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts'); rpr.append(rf)
    for a in ('w:ascii', 'w:hAnsi', 'w:cs', 'w:eastAsia'):
        rf.set(qn(a), name)

# ---------- styles ----------
n = doc.styles['Normal']
set_font(n)
pf = n.paragraph_format
pf.line_spacing_rule = WD_LINE_SPACING.MULTIPLE
pf.line_spacing = 1.15
pf.space_after = Pt(6)
pf.space_before = Pt(0)
pf.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY

DARK = RGBColor(0x1F, 0x33, 0x46)

h1 = doc.styles['Heading 1']
set_font(h1, size=14, bold=True, color=DARK)
h1.paragraph_format.space_before = Pt(12)
h1.paragraph_format.space_after = Pt(6)
h1.paragraph_format.line_spacing = 1.15
h1.paragraph_format.keep_with_next = True

h2 = doc.styles['Heading 2']
set_font(h2, size=12, bold=True, color=DARK)
h2.paragraph_format.space_before = Pt(8)
h2.paragraph_format.space_after = Pt(4)
h2.paragraph_format.line_spacing = 1.15
h2.paragraph_format.keep_with_next = True

for sn in ('List Bullet', 'List Number'):
    st = doc.styles[sn]
    set_font(st)
    st.paragraph_format.line_spacing = 1.15
    st.paragraph_format.space_after = Pt(3)
    st.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY

cap = doc.styles.add_style('Fig Caption', 1)
set_font(cap, size=9.5)
cap.font.italic = True
cap.paragraph_format.alignment = WD_ALIGN_PARAGRAPH.CENTER
cap.paragraph_format.space_before = Pt(3)
cap.paragraph_format.space_after = Pt(8)
cap.paragraph_format.line_spacing = 1.0

# ---------- helpers ----------
def para(text='', style=None, align=None, size=None, bold=None, italic=None,
         space_after=None, space_before=None):
    p = doc.add_paragraph(style=style)
    if text:
        r = p.add_run(text)
        if size: r.font.size = Pt(size)
        if bold is not None: r.bold = bold
        if italic is not None: r.italic = italic
    if align is not None: p.alignment = align
    if space_after is not None: p.paragraph_format.space_after = Pt(space_after)
    if space_before is not None: p.paragraph_format.space_before = Pt(space_before)
    return p

def rich(parts, style=None, align=None):
    """parts = list of (text, bold) tuples"""
    p = doc.add_paragraph(style=style)
    for t, b in parts:
        r = p.add_run(t)
        r.bold = b
    if align is not None: p.alignment = align
    return p

def h(text, level=1):
    p = doc.add_paragraph(text, style=f'Heading {level}')
    return p

def bullet(parts_or_text):
    if isinstance(parts_or_text, str):
        return doc.add_paragraph(parts_or_text, style='List Bullet')
    p = doc.add_paragraph(style='List Bullet')
    for t, b in parts_or_text:
        r = p.add_run(t); r.bold = b
    return p

def keep_paragraph_whole(p):
    """Stop a paragraph breaking across a page, and kill widows/orphans."""
    p.paragraph_format.widow_control = True
    p.paragraph_format.keep_together = True

def row_cant_split(row, header=False):
    trPr = row._tr.get_or_add_trPr()
    if trPr.find(qn('w:cantSplit')) is None:
        trPr.append(OxmlElement('w:cantSplit'))
    if header and trPr.find(qn('w:tblHeader')) is None:
        trPr.append(OxmlElement('w:tblHeader'))

def shade(cell, hexcolor):
    tcPr = cell._tc.get_or_add_tcPr()
    sh = OxmlElement('w:shd')
    sh.set(qn('w:val'), 'clear'); sh.set(qn('w:color'), 'auto'); sh.set(qn('w:fill'), hexcolor)
    tcPr.append(sh)

def table(headers, rows, widths=None, font_pt=TABLE_PT, keep_whole=None):
    # keep the lead-in sentence attached to the table it introduces
    if doc.paragraphs:
        doc.paragraphs[-1].paragraph_format.keep_with_next = True
    t = doc.add_table(rows=1, cols=len(headers))
    t.style = 'Table Grid'
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr = t.rows[0].cells
    for i, htxt in enumerate(headers):
        hdr[i].text = ''
        p = hdr[i].paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.LEFT
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.space_before = Pt(2)
        p.paragraph_format.line_spacing = 1.0
        r = p.add_run(htxt); r.bold = True; r.font.size = Pt(font_pt); r.font.name = FONT
        shade(hdr[i], 'E8EDF2')
    for row in rows:
        cells = t.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ''
            p = cells[i].paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.LEFT
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.line_spacing = 1.0
            bold = False
            txt = val
            if isinstance(val, tuple):
                txt, bold = val
            r = p.add_run(txt); r.font.size = Pt(font_pt); r.font.name = FONT; r.bold = bold
    if widths:
        for ri in t.rows:
            for i, w in enumerate(widths):
                ri.cells[i].width = Inches(w)
    # never break inside a row; repeat the header if the table must span pages
    for idx, ri in enumerate(t.rows):
        row_cant_split(ri, header=(idx == 0))
    # short tables are held on a single page; long ones may flow with a repeated header
    tbl_limit = int(os.environ.get('TBL_WHOLE_ROWS', '5'))
    whole = keep_whole if keep_whole is not None else (len(t.rows) <= tbl_limit)
    if whole:
        for ri in list(t.rows)[:-1]:
            for c in ri.cells:
                for cp in c.paragraphs:
                    cp.paragraph_format.keep_with_next = True
    doc.add_paragraph().paragraph_format.space_after = Pt(4)
    return t

def add_page_field(paragraph):
    """Insert a live PAGE field so Word renumbers automatically."""
    run = paragraph.add_run()
    run.font.name = FONT
    run.font.size = Pt(10)
    begin = OxmlElement('w:fldChar'); begin.set(qn('w:fldCharType'), 'begin')
    instr = OxmlElement('w:instrText'); instr.set(qn('xml:space'), 'preserve'); instr.text = 'PAGE'
    end = OxmlElement('w:fldChar'); end.set(qn('w:fldCharType'), 'end')
    run._r.append(begin); run._r.append(instr); run._r.append(end)

def restart_page_numbering(section, start=1):
    sectPr = section._sectPr
    for old in sectPr.findall(qn('w:pgNumType')):
        sectPr.remove(old)
    pg = OxmlElement('w:pgNumType')
    pg.set(qn('w:start'), str(start))
    sectPr.append(pg)

def figure(img, width, caption):
    p = doc.add_paragraph(); p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    p.paragraph_format.space_after = Pt(2)
    p.paragraph_format.keep_with_next = True   # caption never separates from the image
    p.paragraph_format.keep_together = True
    p.add_run().add_picture(os.path.join(MEDIA, img), width=Inches(width))
    cp = doc.add_paragraph(caption, style='Fig Caption')
    cp.paragraph_format.keep_together = True

# =====================================================================
# COVER PAGE  (per provided front-page template)
# =====================================================================
for _ in range(3):
    para(space_after=0)

p = para('Project Proposal', align=WD_ALIGN_PARAGRAPH.CENTER, size=20, bold=True, space_after=28)
p.runs[0].font.color.rgb = DARK

p = para('PROJECT NEXUS 2026: AI INNOVATION CHALLENGE',
         align=WD_ALIGN_PARAGRAPH.CENTER, size=15, bold=True, space_after=40)
p.runs[0].font.color.rgb = DARK

t = doc.add_table(rows=3, cols=2)
t.style = 'Table Grid'
t.alignment = WD_TABLE_ALIGNMENT.CENTER
cover_fields = [
    ('Track Name:', 'Track 1 \u2014 Healthcare Technology'),
    ('Team Name:', 'MEDTHRU'),
    ('Phase:', 'Phase 1 \u2014 Written Proposal'),
]
for i, (k, v) in enumerate(cover_fields):
    for j, txt in enumerate((k, v)):
        c = t.rows[i].cells[j]
        c.text = ''
        pp = c.paragraphs[0]
        pp.paragraph_format.space_after = Pt(6)
        pp.paragraph_format.space_before = Pt(6)
        pp.paragraph_format.line_spacing = 1.15
        r = pp.add_run(txt); r.font.size = Pt(12); r.font.name = FONT; r.bold = (j == 0)
    t.rows[i].cells[0].width = Inches(1.9)
    t.rows[i].cells[1].width = Inches(4.3)
    shade(t.rows[i].cells[0], 'E8EDF2')

para(space_after=0)
p = para('Project Title: Medical Identification Card (MedIC) \u2014 An NFC-Linked Emergency Health Record Platform',
         align=WD_ALIGN_PARAGRAPH.CENTER, size=12, bold=True, space_before=30)
p.runs[0].font.color.rgb = DARK
para('Submitted 16 August 2026', align=WD_ALIGN_PARAGRAPH.CENTER, size=11, italic=True)

# --- new section so the cover carries no page number and the body starts at 1 ---
body_sec = doc.add_section(WD_SECTION.NEW_PAGE)
body_sec.page_width = Inches(8.27)
body_sec.page_height = Inches(11.69)
body_sec.left_margin = body_sec.right_margin = Inches(1.0)
body_sec.top_margin = body_sec.bottom_margin = Inches(1.0)
body_sec.footer_distance = Inches(0.5)
restart_page_numbering(body_sec, 1)

# cover footer: deliberately empty
cover_sec = doc.sections[0]
cover_sec.footer.is_linked_to_previous = False
cover_sec.footer.paragraphs[0].text = ''

# body footer: centred page number
body_sec.footer.is_linked_to_previous = False
fp = body_sec.footer.paragraphs[0]
fp.text = ''
fp.alignment = WD_ALIGN_PARAGRAPH.CENTER
fp.paragraph_format.space_before = Pt(0)
fp.paragraph_format.space_after = Pt(0)
add_page_field(fp)

# =====================================================================
# TEAM MEMBER DETAILS  (required section 2)
# =====================================================================
h('Team Member Details', 1)
table(
    ['Role', 'Name', 'Gender', 'Institution / Programme'],
    [
        ['Team Lead', 'Amirun Azwar bin Azlin', 'Male', 'UKM \u2014 Electrical and Electronic Engineering'],
        ['Team Member', 'Muhammad Syahir bin Sheik Abdul Paris', 'Male', 'UKM \u2014 Electrical and Electronic Engineering'],
        ['Team Member (WIE)', 'Nur Farihah Afiqah binti Zulkufli', 'Female', 'UKM \u2014 Electrical and Electronic Engineering'],
        ['Team Member (WIE)', 'Azra Nafiza binti Awalluddin', 'Female', 'UKM \u2014 Electrical and Electronic Engineering'],
    ],
    widths=[1.35, 2.05, 0.75, 2.15])

# =====================================================================
# 1. EXECUTIVE SUMMARY
# =====================================================================
h('1. Executive Summary', 1)

EXEC = (
    "When an incapacitated patient arrives at an emergency department, the information needed to treat them "
    "safely often exists but cannot be reached in the first critical minutes. Malaysian health records are "
    "fragmented across Ministry of Health facilities, private hospitals, and general practitioners, and no "
    "patient-held emergency summary travels with the individual. App-based alternatives fail precisely when "
    "they are needed, because each assumes a conscious patient holding a charged, connected, unlocked phone."
)
EXEC2 = (
    "MEDTHRU proposes the Medical Identification Card: a patient mobile application, an NFC card, and a "
    "clinical portal as one workflow. The card carries a key, not the data. A 256-bit random token is "
    "written to the tag's data blocks; only its SHA-256 hash is stored server-side. The factory UID is "
    "never used as a credential: it is broadcast to any nearby reader and cheaply cloned. The record "
    "therefore stays current, a lost card can be revoked, and the card discloses nothing."
)
EXEC3 = (
    "Access is dual-layer. A tap resolves a minimal emergency dataset \u2014 blood group, severe allergies, "
    "high-risk medications, key diagnoses, emergency contacts \u2014 in under five seconds with no login, while "
    "full history requires clinician credentials and writes an audit entry. An AI subsystem "
    "condenses 30 days of vital-sign data into a three-point clinical summary and flags contraindications "
    "against active medications and allergies, as advisory decision support under human oversight."
)
EXEC4 = (
    "The record platform is substantially implemented. The build phase closes the card-to-reader loop and "
    "delivers the AI subsystem, at under RM 200 per station and RM 3 per card."
)
for t_ in (EXEC, EXEC2, EXEC3, EXEC4):
    para(t_)

WORDS = len([w for w in (EXEC + ' ' + EXEC2 + ' ' + EXEC3 + ' ' + EXEC4).split()
             if w.strip('—–-')])

# =====================================================================
# 2. BACKGROUND AND PROBLEM STATEMENT   [rubric 25%]
# =====================================================================
h('2. Background and Problem Statement', 1)

h('2.1 The Golden Hour Information Gap', 2)
para("During an emergency, the first 60 minutes following severe injury or acute deterioration are often "
     "described as the \u201cGolden Hour\u201d (Lerner & Moscati, 2001). When a patient arrives at an emergency "
     "department (ED) incapacitated, unconscious, or in severe distress, clinicians may have no immediate "
     "access to reliable identity or medical information. Time is then lost identifying the patient, locating "
     "records, or obtaining history from distressed family members. Three failures compound this gap:")
bullet([("Delayed registration and identification. ", True),
        ("Manual data entry and identity searches slow initial registration and can delay clinical assessment. "
         "In a Malaysian tertiary emergency department, crowding was associated with significantly longer "
         "door-to-antibiotic times in sepsis patients, showing that intake delay translates directly into "
         "delayed treatment (Chau et al., 2024).", False)])
bullet([("Treatment without critical context. ", True),
        ("Clinicians may need to make time-sensitive decisions without confirmed information on severe "
         "allergies, active high-risk medications, or chronic conditions.", False)])
bullet([("Inaccessible patient-held data. ", True),
        ("Health information recorded on personal devices may remain unavailable when the patient is "
         "unconscious, the device is locked, or connectivity is limited.", False)])

h('2.2 Malaysian Healthcare Context', 2)
para("The problem is structural rather than incidental. Malaysian health records are distributed across "
     "government facilities using Ministry of Health systems, private hospitals operating vendor-specific "
     "platforms, and general practitioners relying on paper records or standalone practice software. A patient "
     "who attends a GP in Kajang, receives specialist care in Cheras, and later presents at Hospital Kuala "
     "Lumpur may therefore be represented by three unlinked records (Gong et al., 2024). No national "
     "patient-held emergency summary travels with the individual. The people most affected are also those "
     "least well served by app-only solutions \u2014 older adults, rural communities, and lower-income patients "
     "\u2014 who may have complex medical histories yet be least likely to arrive with a charged smartphone, "
     "active data access, and remembered login credentials (Institute for Public Health, 2024).")

h('2.3 Limitations of Existing Approaches', 2)
table(['Approach', 'Limitation in the Emergency Context'],
      [
        ['National EMR integration',
         'Requires cross-institutional policy alignment and multi-year procurement. Important at national scale, but not immediately deployable by a small team.'],
        ['Smartphone health apps',
         'Assumes the patient is conscious, has a charged phone, remembers credentials, and has connectivity. All four assumptions may fail during an emergency.'],
        ['Paper cards and medical-alert bracelets',
         'Travels with the patient and works when unconscious, but stores only a few static fields, becomes outdated, and cannot be revoked when lost.'],
        ['Cloud patient portals',
         'Retains the same dependency on conscious authentication, and requires internet connectivity to a remote provider at the point of care.'],
        ['National ID cards with medical fields (e.g. MyKad)',
         'The chip can hold blood type, allergies, and chronic conditions, but entry is limited to Telehealth Flagship facilities, the field set is fixed, and the cardholder cannot update or revoke it. There is no live link to a clinical record (Jabatan Pendaftaran Negara, n.d.).'],
        ['Phone-based emergency profiles (Apple Medical ID, Android Emergency Information)',
         'Readable from a locked screen, but still requires a charged, present, undamaged handset, is self-reported with no clinician verification, and must be transcribed into the hospital system by hand.'],
      ],
      widths=[1.95, 4.35])
para("The unmet need is therefore a patient-held record that travels with the individual, functions without "
     "active patient participation, remains current, and can be revoked \u2014 combining the physical "
     "availability of a paper card with the currency of a live database.")

h('2.4 Target Users and Stakeholder Needs', 2)
table(['User Group', 'Primary Need', 'Current Failure Mode'],
      [
        ['Patients and cardholders \u2014 people managing chronic conditions, older adults, and anyone at risk of being unable to communicate',
         'A simple way to record daily health information, and assurance that critical medical facts remain retrievable when they cannot speak',
         'Inability to communicate may result in treatment given without awareness of severe allergies or existing conditions'],
        ['ED registration and triage personnel',
         'Immediate confirmation of patient identity and registration that minimises repetitive manual entry',
         'Slow systems, transcription errors, and record-search delays disrupt workflow during emergency surges'],
        ['Emergency clinicians and specialists',
         'Direct access to a reliable summary of history, conditions, medications, and recent trends',
         'Decisions depend on incomplete records or the recollection of distressed family members'],
      ],
      widths=[2.1, 2.1, 2.1])

# =====================================================================
# 3. OBJECTIVES
# =====================================================================
h('3. Objectives', 1)
para("The project is assessed against seven measurable objectives. Each states the target value and the method "
     "by which it is verified during the build phase.")
table(['#', 'Objective', 'Measurable Target and Verification Method'],
      [
        ['O1', 'Eliminate identification delay at triage',
         'Card tap to populated patient identity in under 5 seconds from a cold-started terminal, measured across 30 consecutive taps.'],
        ['O2', 'Provide emergency data without authentication',
         'Layer 1 dataset resolves on card possession alone in 100% of valid taps; 100% of Layer 2 requests presenting no valid clinician credential are rejected by the API test suite.'],
        ['O3', 'Guarantee cross-patient isolation',
         'Zero instances of one card resolving another patient\u2019s rows across all token-scoped routes, verified by automated scoping tests on every route.'],
        ['O4', 'Contain the loss of a card',
         'Revocation and reissue complete in a single database transaction; the revoked token resolves to nothing on the next tap.'],
        ['O5', 'Deliver clinically useful AI output',
         'A three-point executive summary generated from 30 days of logged readings, and a visible contraindication alert raised in 100% of scripted anticoagulant-on-anticoagulant test cases.'],
        ['O6', 'Keep adoption affordable',
         'Under RM 200 per triage station and under RM 3 per patient card, with staff training completed in under 30 minutes.'],
        ['O7', 'Maintain complete accountability',
         '100% of reads and writes, including patient self-access, produce an append-only audit row, verified by test.'],
      ],
      widths=[0.4, 1.85, 4.05])

# =====================================================================
# 4. PROPOSED SOLUTION   [rubric: conceptual innovation 20%]
# =====================================================================
h('4. Proposed Solution', 1)

h('4.1 Platform Ecosystem', 2)
para("The Medical Identification Card is an integrated three-part emergency health platform connecting "
     "patients, triage personnel, and treating clinicians through a single workflow. Rather than offering "
     "isolated applications or relying on manual intake, it coordinates data capture, card-based access, and "
     "clinical review.")
rich([("Patient health application. ", True),
      ("Supports vital-sign logging, chronic-condition management, and an up-to-date medication list. Daily "
       "records are organised into readable trend charts so clinicians can review patterns such as blood "
       "pressure or heart rate over the preceding 30 days. Structured patient-recorded monitoring of this kind "
       "is associated with measurable improvements in chronic disease control (Harrison et al., 2025).", False)])
rich([("NFC access card. ", True),
      ("A tap reads a cryptographic token and resolves the patient\u2019s basic profile on the hospital screen "
       "in under five seconds, reducing repetitive data entry so clinical assessment can begin sooner.", False)])
rich([("Clinical portal. ", True),
      ("Supports triage registration and clinician review, governed by the dual-layer access model in 4.4.", False)])

h('4.2 Core Innovation: The Card Carries a Key, Not the Data', 2)
para("Writing medical data directly to the card creates three material weaknesses: information becomes "
     "outdated unless every card is physically rewritten; anyone finding the card can read the record; and the "
     "limited memory of a typical NTAG device cannot hold a clinically meaningful history.")
para("Instead, the platform writes a 256-bit cryptographically random token to the card\u2019s user data "
     "blocks. The token is a bearer credential, not a patient identifier. Only its SHA-256 hash is stored in "
     "the database; the raw token is written once at issuance and thereafter transmitted on each tap to be "
     "hashed and compared, never persisted server-side. This yields four properties at once:")
doc.add_paragraph("Patient presence provides emergency access. An unconscious patient is resolved through physical "
                  "possession of the card, without a password, smartphone, or active participation.", style='List Number')
doc.add_paragraph("Information remains current. The card points to a live server-side record rather than storing a "
                  "static copy.", style='List Number')
doc.add_paragraph("Loss can be contained. Revocation stops the token resolving; reissue generates a fresh token and "
                  "revokes the previous card within a single transaction.", style='List Number')
doc.add_paragraph("The card stores no identifying or clinical data. It holds only a pseudonymous 256-bit token. That "
                  "token is personal data in the regulatory sense because it resolves to an identifiable patient, and "
                  "is treated as such throughout \u2014 but nothing clinical can be read from the card itself.", style='List Number')

h('4.3 Deliberate Rejection of the Hardware UID', 2)
para("Every NFC tag broadcasts a factory-assigned UID. Convenient, but unsuitable as a credential: it is "
     "exposed to any nearby reader and cloned with inexpensive hardware, so anyone passing a patient could "
     "later impersonate their card. The platform stores its token in the tag\u2019s data blocks instead, using "
     "the UID only for logging \u2014 the most important security decision in the design, already implemented "
     "in reader.js and tag-storage.js.")

h('4.4 Dual-Layer Data Access and Privacy Model', 2)
para("A dual-layer architecture balances immediate access to life-critical information against protection of "
     "sensitive records. Layer 1 is available immediately after a valid tap, without clinician login, and is "
     "restricted to information that may directly affect immediate treatment: verified blood group (displayed "
     "for contextual awareness, not as the sole basis for transfusion), severe anaphylactic allergies, active "
     "high-risk medications, key chronic diagnoses, and emergency contacts. Layer 2 protects detailed history, "
     "daily vital trends, and diagnostic records behind authenticated clinician credentials, and each access "
     "writes an append-only audit entry recording clinician identity, timestamp, and stated purpose. Access "
     "control is enforced by the API, not the interface: a client cannot obtain data the server is not "
     "authorised to return.")
table(['User / Access Context', 'Data Returned', 'Required Proof'],
      [
        ['First responder or triage staff', 'Layer 1 emergency dataset', 'Card possession'],
        ['Patient using own card', 'Layer 2 own record', 'Card possession, plus optional card password where enabled'],
        ['Patient without card in hand', 'Layer 2 own record', 'Registered phone number and password'],
        ['Authenticated clinician', 'Layer 2 plus authorised clinical write access', 'Clinician login (JWT bearer)'],
      ],
      widths=[1.95, 2.35, 2.0])

h('4.5 Clinical Data Verification', 2)
para("The portal allows clinicians to review and digitally verify patient-submitted information, so emergency "
     "staff can distinguish clinician-verified entries from self-reported data. The source-attribution model is "
     "already implemented: every clinical row \u2014 readings, allergies, medications, laboratory results, "
     "documents \u2014 carries a source field assigned by the server according to whether the request presented "
     "a valid clinician token. A patient-entered reading is never silently presented as clinician-verified. The "
     "build phase adds an explicit verification stamp recording the reviewing clinician and time.")

# =====================================================================
# 5. AI INTEGRATION STRATEGY   [rubric: integration 20%]
# =====================================================================
h('5. AI Integration Strategy', 1)

h('5.1 Embedded AI Functionality', 2)
para("During emergency care, clinicians have limited time to review extensive historical logs. The platform "
     "incorporates natural-language and time-series analytical functions over longitudinal data collected "
     "through the patient application. These run on the backend, not on the card, which stores only the "
     "256-bit access token.")
rich([("Clinical executive summary. ", True),
      ("The AI synthesises 30-day vital-sign trends into a concise three-point summary and highlights "
       "potentially significant patterns \u2014 hypertensive spikes, progressive glycaemic volatility \u2014 that "
       "are difficult to identify from a raw table.", False)])
rich([("Triage risk and contraindication system. ", True),
      ("Opening a patient profile cross-references recorded allergies and active medications against proposed "
       "interventions. Where a severe interaction is identified \u2014 for example additional anticoagulation in a "
       "patient already on high-dose anticoagulant therapy \u2014 the portal raises a prominent safety alert. Such "
       "alerts increase targeted clinician action where they are specific and actionable "
       "(Holbrook et al., 2025).", False)])
para("Both functions operate on data the platform already holds; the allergy, medication, and readings tables "
     "are implemented and populated, and the AI subsystem forms the analytical layer above them. Scope is "
     "deliberately bounded: a general treatment-checking system would require a validated medication database, "
     "dose and route data, current guidelines, and formal regulatory assessment \u2014 none achievable or "
     "responsible in a student prototype. What is built is an advisory engine over a limited, clinically "
     "reviewed set of simulated rules, demonstrated against scripted cases rather than presented as a "
     "deployable clinical tool.")

h('5.2 Clinical Safety and Human Oversight', 2)
para("These functions provide decision support, not autonomous decision-making. Every summary or alert is "
     "advisory, attributable, and displayed alongside the underlying source data. The system does not withhold "
     "raw information or block clinical action; it surfaces a potential risk and records that the alert was "
     "presented. This restraint is deliberate: a 2024 meta-analysis found that clinicians override roughly 90% "
     "of drug\u2013drug interaction alerts generated by clinical decision support systems, so the platform "
     "raises only patient-specific, actionable risks rather than broad rule-based warnings "
     "(Felisberto et al., 2024).")

h('5.3 AI-Assisted Development Workflow', 2)
para("AI is also integrated into prototype design, algorithm development, and testing. The team\u2019s "
     "AI-assisted workflow, recorded contemporaneously in the Nexus Log, covers architecture decisions (the "
     "token-versus-UID analysis, the dual-layer access model, and the source-attribution scheme, developed "
     "through AI-assisted design review with the team evaluating, challenging, and overriding proposals); "
     "protocol work (NTAG21x block read/write sequencing and PC/SC APDU handling against the ACR122U); "
     "security review (adversarial analysis of the token lifecycle, rate limits, and the card-loss threat "
     "model); test generation (endpoint and access-scoping tests, including the \u201ccard A must never reach "
     "patient B\u2019s rows\u201d class of test guarding every token-scoped route); and reader-level fault "
     "diagnosis once hardware enters the loop.")

# =====================================================================
# 6. SYSTEM DESIGN   [rubric 15%]
# =====================================================================
h('6. System Design', 1)

h('6.1 Architecture Overview and Data Flow', 2)
para("The system follows a secure client\u2013server topology of NFC hardware, cross-platform clients, a "
     "clinical portal, and backend API services. A patient records health information in the mobile "
     "application, and the backend associates that record with the token on their card. At the hospital the "
     "card is tapped on a USB reader at the triage terminal and the token is sent to the backend over an "
     "encrypted endpoint. The backend validates it and returns the Layer 1 profile; where a clinician needs "
     "detailed history, authentication unlocks Layer 2 and starts the AI pipeline. All communication is "
     "protected using TLS.")
figure('image1.png', 4.45, 'Figure 1. System architecture and data flow.')
rich([("Deployment model and its limitation. ", True),
      ("The prototype runs a facility-local backend: API and database sit on a commodity PC or hospital virtual "
       "machine inside the facility network, reached by the reader bridge over the local network rather than "
       "the public internet. This removes the external-connectivity dependency that constrains cloud portals "
       "and keeps the record inside the facility holding custody of it. It does not make the system "
       "network-free, and the proposal does not claim otherwise: a tap must reach the local backend to resolve "
       "a token. Two mitigations are stated in section 9 as planned work \u2014 an offline Layer 1 cache at each "
       "reader station, and a read-only replica at a second host.", False)])

h('6.2 End-to-End Card Tap Sequence', 2)
para("The cold-start path matters to both the demonstration and real deployment. A tap works even when the "
     "terminal is fully inactive: if the backend is not listening the reader bridge starts it, and if the "
     "client is not running the bridge opens it. The operator\u2019s only required action is to present the "
     "card.")
figure('image2.png', 3.7, 'Figure 2. End-to-end NFC card tap sequence.')

h('6.3 Physical Deployment Layout', 2)
para("The card is a passive 13.56 MHz transponder powered by the reader\u2019s electromagnetic field; "
     "containing no battery, it requires no maintenance cycle. The ACR122U connects to Windows as a standard "
     "PC/SC CCID device and draws power over USB 2.0, so a triage station needs no separate mains adapter "
     "beyond the terminal itself. The physician\u2019s terminal requires no reader of its own \u2014 it reaches "
     "the same record over the local network \u2014 so adding a review station costs nothing beyond the PC "
     "already on the desk.")
figure('image3.png', 4.05, 'Figure 3. Physical deployment layout: card, reader, and triage terminal, with the physician terminal reached over the local network.')

h('6.4 Technology Stack', 2)
table(['System Layer', 'Technology', 'Primary Function'],
      [
        ['Hardware', 'ACR122U USB NFC reader (13.56 MHz, PC/SC); NTAG215 cards', 'Physical identification; reads the token from the tag\u2019s data blocks'],
        ['Reader bridge', 'Node.js, nfc-pcsc, custom NTAG block I/O', 'Detects taps, extracts the token, broadcasts to clients, cold-starts the stack'],
        ['Clients', 'Flutter / Dart \u2014 patient app (Android) and clinical portal (desktop \u2192 web)', 'Daily logging, trend charts, appointments, document upload; triage check-in and physician review across both access layers'],
        ['Backend API', 'Node.js, Express 5, REST/JSON', 'Token resolution, access-layer enforcement, CRUD, audit logging'],
        ['Security', 'bcrypt, separate patient/clinician JWTs, SHA-256 token hashing, per-route rate limiting, TLS', 'Authentication, credential protection, brute-force and enumeration resistance'],
        ['Database', 'SQLite (16 tables); filesystem store for document blobs', 'Clinical record, card lifecycle, append-only audit trail'],
        ['AI subsystem', 'Time-series anomaly detection, NLP summarisation, bounded rule-based contraindication engine', 'Converts longitudinal data into actionable insight at the point of care'],
      ],
      widths=[1.1, 2.6, 2.6])

h('6.5 Data Model and Security Properties', 2)
para("Sixteen SQLite tables underpin the platform. Figure 4 highlights the security-critical relationships: "
     "one active card per patient, reissue revoking the previous card in the same transaction; every read and "
     "write audited, including patient self-access; and token-scoped routes that are patient-scoped in SQL, "
     "each resolving the patient before filtering child rows. One card therefore cannot reach another "
     "patient\u2019s record, even with a valid row identifier.")
figure('image4.png', 5.6, 'Figure 4. Security-critical data relationships.')
table(['Threat / Control Gap', 'Mitigation', 'Status'],
      [
        ['Cloned card via broadcast UID', 'UID never used as a credential; token lives in the data blocks', 'Implemented'],
        ['Token database leak', 'Only SHA-256 hashes stored; the raw token is never persisted server-side', 'Implemented'],
        ['Card lost or stolen', 'Revoke and reissue; optional card password gates the full record on a raw tap', 'Implemented'],
        ['Token enumeration or privilege escalation via the client', '256-bit token space plus a 30 lookups/min rate limit; both access layers enforced server-side, so the UI is not a security boundary', 'Implemented'],
        ['Cross-patient data access', 'Every token-scoped query filtered by resolved patient_id', 'Implemented'],
        ['Unaudited access', 'Every read and write writes an audit_log row', 'Implemented'],
        ['Hardcoded development JWT secret', 'Must be supplied via environment variable before any real patient data', ('Open', True)],
        ['Data at rest unencrypted', 'Database-level encryption required for production', ('Open', True)],
      ],
      widths=[1.95, 3.25, 1.1])
para("The final two items are stated deliberately: they are known deployment blockers that must be resolved "
     "before the system handles real patient data.")

h('6.6 Current Implementation Status', 2)
para("The core record platform is substantially implemented: an approximately 1,750-line Node/Express API "
     "across 16 SQLite tables with full audit logging and CRUD for records, appointments, messaging, and "
     "documents; bcrypt authentication with separate clinician and patient JWTs; a completed PC/SC reader "
     "bridge with cold-start and SSE broadcast; card provisioning to blank NTAGs; a 46-file Flutter client "
     "with trend charts, PDF export, and notifications; a simulation harness exercising the full tap path "
     "without hardware; and an endpoint test suite covering cross-patient scoping. The build phase delivers "
     "the three remaining priorities: the physical hardware loop, the AI subsystem, and the hardened Layer 1 "
     "route.")

# =====================================================================
# 7. INTEGRATION AND DEPLOYMENT STRATEGY
# =====================================================================
h('7. Integration and Deployment Strategy', 1)

h('7.1 Overlay Architecture, Not System Replacement', 2)
para("The platform operates alongside existing hospital systems rather than replacing them. A facility does "
     "not migrate from its current electronic medical record platform; it adds a USB reader at each triage "
     "station, letting the card act as a patient-held index across facilities that may not otherwise exchange "
     "data. The portal exposes resolved demographics two ways so no facility must change its software: a REST "
     "endpoint for systems able to consume it, and clipboard and CSV export for those that cannot. Cards are "
     "issued at reception after identity verification against MyKad, with consent recorded for the Layer 1 "
     "dataset; the facility acts as data controller and the project team as data processor under a written "
     "agreement.")

h('7.2 Staged Deployment Path', 2)
table(['Stage', 'Scope', 'Validation Objective'],
      [
        ['1. Single clinic', 'One reader at reception, one at the consultation desk; cards issued at registration', 'Tap-to-record works in a real workflow with real staff'],
        ['2. Clinic cluster', 'Several GP clinics sharing one backend', 'Cross-facility continuity \u2014 the actual point of the system'],
        ['3. Emergency department', 'Readers at triage, Layer 1 only at the front desk', 'The unconscious-patient case: the highest-value scenario'],
        ['4. Standards alignment', 'HL7 FHIR export/import over the existing schema', 'A path into national infrastructure rather than a competing silo'],
      ],
      widths=[1.3, 2.5, 2.5])

h('7.3 Regulatory and Ethical Position', 2)
para("The proposal recognises the obligations of Malaysia\u2019s Personal Data Protection Act 2010 (Act 709). "
     "The architecture is built around data minimisation on the card, patient-controlled revocation, "
     "inspectable audit trails, and server-side access control. Production deployment will additionally require "
     "encryption at rest, TLS in transit, a data-controller agreement per facility, and Ministry of Health "
     "engagement for any public-sector pilot. These are identified as implementation obligations, not presented "
     "as completed work.")
para("Layer 1 is a deliberate, limited privacy trade-off in favour of emergency utility. Access on card "
     "possession alone is what makes it work for an unconscious patient, and equally what a reviewer should "
     "question. The prototype scopes it to the minimum dataset that changes immediate treatment; patients opt "
     "in at issuance, may set a card password protecting everything beyond Layer 1, and may revoke at any "
     "time. Because access is enforced server-side, production can add reader registration, device "
     "certificates, facility-authenticated taps, and per-facility rate ceilings without redesign — options "
     "rather than delivered features, each resting on controls the prototype already implements.")

# =====================================================================
# 8. BUDGET
# =====================================================================
h('8. Budget and Resource Allocation', 1)
para("The RM 700 seed grant is allocated as follows. Prototype hardware is itemised below; the balance is "
     "retained for the contingency and showcase costs described beneath the table.")
table(['Item', 'Qty', 'Unit (RM)', 'Total (RM)', 'Justification'],
      [
        ['ACR122U USB NFC reader', '1', '126', '126', 'The PC/SC-compliant reader required to close the physical card-to-reader loop (O1). One unit equips the demonstration triage station; a five-year asset.'],
        ['NTAG215 blank cards', '3', '2.33', '7', 'Patient cards for the demonstration, including one spare to demonstrate the revoke-and-reissue flow (O4).'],
        ['NTAG213 sticker labels', '10', '0.60', '6', 'Low-cost tags for destructive read/write testing of NTAG block I/O, so provisioned patient cards are not consumed during development.'],
        [('Hardware subtotal', True), '', '', ('139', True), 'Confirms the sub-RM 200 per-station target in O6.'],
        ['Server and database', '\u2014', '\u2014', '0', 'Runs on a commodity PC already owned by the team; SQLite carries no licensing cost.'],
        ['Showcase and contingency', '\u2014', '\u2014', '561', 'Booth materials and printing for the Grand Finale, replacement reader in the event of hardware failure during the build window, and additional cards for extended testing.'],
        [('Total', True), '', '', ('700', True), ''],
      ],
      widths=[1.35, 0.4, 0.65, 0.7, 3.2])
para("Staff training is costed at zero: the clinician-facing workflow is limited to presenting the card to "
     "the reader, and is completed in under 30 minutes (O6).")

# =====================================================================
# 9. IMPROVEMENT PLAN AND IMPACT MEASUREMENT   [rubric 10%]
# =====================================================================
h('9. Improvement Plan and Impact Measurement', 1)

h('9.1 Build Milestones', 2)
table(['Window', 'Deliverable', 'Success Criterion'],
      [
        ['16\u201322 Sep', 'Hardware loop closed end to end', 'Cold-boot tap: physical card \u2192 reader \u2192 Layer 1 profile on screen, under 5 s, unattended'],
        ['18\u201325 Sep', 'AI clinical executive summary over 30-day readings', 'Three-point summary generated from real logged data, with anomalies correctly surfaced'],
        ['23\u201328 Sep', 'Contraindication engine; Layer 1 hardening; card-loss flow', 'Anticoagulant-on-anticoagulant scenario raises a visible alert; a revoked card is correctly denied'],
        ['26\u201330 Sep', 'Booth build, demo script, cards provisioned', 'Full demonstration runs three times consecutively without intervention'],
        ['30 Sep \u2013 7 Oct', 'Documentation, source code, video, Nexus Log', 'All four submission artefacts complete, submitted with at least 24 hours\u2019 margin'],
      ],
      widths=[1.2, 2.3, 2.8])

h('9.2 Post-Competition Development Roadmap', 2)
rich([("Immediate. ", True),
      ("Close the JWT secret gap and add encryption at rest, followed by a pre-deployment security review; make "
       "the audit trail tamper-evident through hash chaining and export to append-only storage, so alteration "
       "by a database administrator becomes detectable rather than merely difficult; replace the desktop "
       "client with a web portal; add HL7 FHIR export; build the offline-first cache that keeps a rural "
       "facility running through an outage; and produce the iOS build, currently blocked by toolchain rather "
       "than architecture.", False)])
rich([("Medium-term. ", True),
      ("Phone-as-reader using Android NFC, dropping per-station hardware cost to zero; hospital SSO so "
       "clinician identity comes from the facility directory; expanded AI covering triage acuity scoring and "
       "deterioration prediction; and a multi-tenant backend so a cluster shares infrastructure without "
       "sharing a database.", False)])
rich([("Long-term. ", True),
      ("Facility federation, in which hospitals resolve a card against a shared directory while each retains "
       "custody of its own records; a Ministry of Health pilot in an emergency department, the deployment "
       "that would genuinely validate the national-scale claim; and longitudinal population insight from "
       "consented, de-identified aggregate data.", False)])

h('9.3 Success Measures', 2)
para("Success will be evaluated through four operational measures rather than download counts: time from "
     "arrival to confirmed identity at triage; time to availability of critical history; clinician-reported "
     "confidence in the AI summary against the underlying record; and the proportion of issued cards still "
     "active after 12 months, indicating whether patients keep carrying the card.")

# =====================================================================
# 10. TEAM COMPOSITION AND DIVERSITY   [rubric 10%]
# =====================================================================
h('10. Team Composition and Diversity', 1)
para("MEDTHRU is a four-member team from the Faculty of Engineering and Built Environment, Universiti "
     "Kebangsaan Malaysia, all reading Electrical and Electronic Engineering. The team is evenly balanced by "
     "gender, with two Women in Engineering members satisfying the WIE participation requirement. "
     "Responsibilities are divided so each member owns a distinct layer of the platform, which is also how the "
     "build-phase milestones in section 9.1 are staffed.")
table(['Member', 'Gender', 'Role', 'Build-Phase Responsibility'],
      [
        ['Amirun Azwar bin Azlin', 'Male', 'Team Lead', 'Backend API, token lifecycle, security model, integration'],
        ['Muhammad Syahir bin Sheik Abdul Paris', 'Male', 'Team Member', 'NFC hardware loop: reader bridge, NTAG I/O, provisioning'],
        ['Nur Farihah Afiqah binti Zulkufli', 'Female', 'Team Member (WIE)', 'AI subsystem: summarisation and contraindication engine'],
        ['Azra Nafiza binti Awalluddin', 'Female', 'Team Member (WIE)', 'Flutter client and portal; demo, docs and Nexus Log'],
      ],
      widths=[1.85, 0.65, 1.05, 2.75])

# =====================================================================
# 11. CONCLUSION
# =====================================================================
h('11. Conclusion', 1)
para("The Medical Identification Card closes the emergency information gap with a patient health application, "
     "an NFC card carrying a revocable token rather than medical data, and a portal governed by dual-layer "
     "access: emergency information on card possession, detailed records behind authenticated clinician "
     "access and full audit logging. The build phase delivers the hardware loop, the AI subsystem, and the "
     "hardened Layer 1 route, below RM 200 per station and RM 3 per card.")

# =====================================================================
# REFERENCES  (excluded from the page count)
# =====================================================================
doc.add_page_break()
h('References', 1)
REFS = [
 "Chau, E. Y. W., Abu Bakar, A., Zamhot, A., Zaini, I. Z., Adanan, S. N., & Sabardin, D. M. (2024). An observational study on the impact of overcrowding towards door-to-antibiotic time among sepsis patients presented to emergency department of a tertiary academic hospital. BMC Emergency Medicine, 24(1), Article 58. https://doi.org/10.1186/s12873-024-00973-4",
 "Felisberto, M., Lima, G. dos S., Celuppi, I. C., Fantonelli, M. dos S., Zanotto, W. L., Oliveira, J. M. D. de, Mohr, E. T. B., Santos, R. A. dos, Scandolara, D. H., Cunha, C. L., Hammes, J. F., Rosa, J. S. da, Demarchi, I. G., Wazlawick, R. S., & Dalmarco, E. M. (2024). Override rate of drug-drug interaction alerts in clinical decision support systems: A brief systematic review and meta-analysis. Health Informatics Journal, 30(2). https://doi.org/10.1177/14604582241263242",
 "Gong, R., Mukhriz, I., & Tan, J.-E. (2024). Digital health records in Malaysia: The journey and the way forward. Khazanah Research Institute. https://www.krinstitute.org/publications/digital-health-records-in-malaysia-the-journey-and-the-way-forward",
 "Harrison, T. N., Juan, R. A., An, J., Zhou, H., Mora Marquez, J., Ong-Su, A. L., Brettler, J. W., & Reynolds, K. (2025). Blood pressure outcomes following a home blood pressure monitoring program in a large integrated US health system. American Journal of Hypertension, 38(10), 833\u2013840. https://doi.org/10.1093/ajh/hpaf082",
 "Holbrook, A. M., Matos Silva, J., Yaser Faruque, J. A., Deng, J., Schneider, T., & Jaffer, A. (2025). Effect of electronic drug-drug interaction alerts on patient and clinician outcomes: A systematic review. Journal of the American Medical Informatics Association, 32(10), 1617\u20131628. https://academic.oup.com/jamia/article/32/10/1617/8240693",
 "Institute for Public Health. (2024). National Health and Morbidity Survey (NHMS) 2023: Non-communicable diseases and healthcare demand \u2014 Technical report. Ministry of Health Malaysia. https://iku.nih.gov.my/images/nhms2023/report-nhms-2023.pdf",
 "Jabatan Pendaftaran Negara. (n.d.). MyKad: Main applications. Retrieved August 2, 2026, from https://www.jpn.gov.my/en/information-2/mykad/main-applications/",
 "Lerner, E. B., & Moscati, R. M. (2001). The golden hour: Scientific fact or medical \u201curban legend\u201d? Academic Emergency Medicine, 8(7), 758\u2013760.",
 "Personal Data Protection Act 2010 (Act 709) (Malay.).",
]
for r in REFS:
    p = doc.add_paragraph(r)
    p.paragraph_format.first_line_indent = Inches(-0.4)
    p.paragraph_format.left_indent = Inches(0.4)
    p.paragraph_format.space_after = Pt(6)

# ---------- final pagination pass ----------
# Widows/orphans off everywhere; short paragraphs additionally forced to stay whole.
# Long paragraphs are allowed to flow, since forcing them intact strands whole page
# bottoms and costs more than it buys.
# Pagination knobs — raise to split less, lower to fit more on a page.
#   KEEP_WHOLE_UNDER : paragraphs shorter than this (chars) never break across pages
#   TBL_WHOLE_ROWS   : tables with at most this many rows are held on one page
KEEP_WHOLE_UNDER = int(os.environ.get('KEEP_WHOLE_UNDER', '300'))
for p in doc.paragraphs:
    if p.style.name in ('Normal', 'List Bullet', 'List Number'):
        p.paragraph_format.widow_control = True
        if len(p.text) <= KEEP_WHOLE_UNDER:
            p.paragraph_format.keep_together = True

doc.save(OUT)
print('Executive summary word count:', WORDS)
print('Saved:', OUT)
