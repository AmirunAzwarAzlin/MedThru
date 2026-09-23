"""Hardware deployment drawing for section 5 of the NFC-MedConnect proposal."""
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch, Rectangle
from matplotlib.lines import Line2D

INK = '#1a1f2b'
MUTE = '#5b6472'
RULE = '#9aa3b0'
BAND = '#eef1f5'
ACCENT = '#0f5d8f'

TITLE_GAP = 5.2
LINE_1 = 10.6
LINE_DY = 4.0
PAD_B = 3.4
BODY = 7.2

fig, ax = plt.subplots(figsize=(11.5, 6.4))
ax.set_xlim(0, 115)
ax.set_ylim(-12, 64)
ax.axis('off')


def bh(n):
    return LINE_1 + max(0, n - 1) * LINE_DY + PAD_B


def box(x, ytop, w, title, lines, tsize=9.6):
    h = bh(len(lines))
    y = ytop - h
    ax.add_patch(FancyBboxPatch((x, y), w, h,
                 boxstyle='round,pad=0,rounding_size=1.2',
                 fc='white', ec=INK, lw=1.4, zorder=3))
    ax.text(x + w / 2, ytop - TITLE_GAP, title, ha='center', va='center',
            fontsize=tsize, fontweight='bold', color=INK, zorder=4)
    for i, ln in enumerate(lines):
        ax.text(x + w / 2, ytop - LINE_1 - i * LINE_DY, ln, ha='center',
                va='center', fontsize=BODY, color=MUTE, zorder=4)
    return y, y + h / 2


def arrow(x1, y1, x2, y2, style='-|>', ls='-', color=INK, lw=1.5):
    ax.add_patch(FancyArrowPatch((x1, y1), (x2, y2), arrowstyle=style,
                 mutation_scale=13, lw=lw, color=color, linestyle=ls,
                 shrinkA=0, shrinkB=0, zorder=5))


def label(x, y, text, size=6.9):
    ax.text(x, y, text, ha='center', va='center', fontsize=size,
            style='italic', color=ACCENT, zorder=6,
            bbox=dict(boxstyle='round,pad=0.3', fc='white', ec='none', alpha=0.96))


# ── geometry ─────────────────────────────────────────────────────────────
TOP, TOP2 = 54.0, 18.0
TRIAGE_BOT = TOP - bh(4)          # 28.0
PHYS_BOT = TOP2 - bh(3)           # -4.0

# bands sized to enclose their boxes
ax.add_patch(Rectangle((1.5, TRIAGE_BOT - 2.0), 112, (61.0 - (TRIAGE_BOT - 2.0)),
                       fc=BAND, ec='none', zorder=0))
ax.add_patch(Rectangle((68.0, PHYS_BOT - 2.0), 45.5, ((TOP2 + 3.5) - (PHYS_BOT - 2.0)),
                       fc=BAND, ec='none', zorder=0))
ax.text(3.6, 58.4, 'TRIAGE STATION', fontsize=8.4, fontweight='bold', color=MUTE, zorder=2)
ax.text(70.0, 20.2, 'PHYSICIAN STATION', fontsize=8.4, fontweight='bold', color=MUTE, zorder=2)

# ── triage row ───────────────────────────────────────────────────────────
_, c1 = box(3, TOP, 22, 'NTAG215 Card',
            ['13.56 MHz passive tag', 'ISO/IEC 14443A',
             '504 B user memory', 'token in blocks 4–11'])
_, c2 = box(36, TOP, 21, 'ACR122U Reader',
            ['USB NFC reader', 'PC/SC CCID class', 'bus-powered, ~200 mA',
             'status LED + buzzer'])

th = bh(4)
ax.add_patch(FancyBboxPatch((72, TRIAGE_BOT), 39, th,
             boxstyle='round,pad=0,rounding_size=1.2',
             fc='white', ec=INK, lw=1.4, zorder=3))
ax.text(91.5, TOP - TITLE_GAP, 'Triage Terminal  (Windows PC)', ha='center',
        va='center', fontsize=9.6, fontweight='bold', color=INK, zorder=4)
ax.add_patch(Rectangle((74, TOP - 15.6), 35, 5.0, fc='white', ec=RULE, lw=0.9, zorder=4))
ax.text(91.5, TOP - 13.1, 'reader.js  —  nfc-pcsc bridge', ha='center', va='center',
        fontsize=7.4, color=INK, zorder=5)
ax.add_patch(Rectangle((74, TOP - 22.0), 16.5, 5.0, fc='white', ec=RULE, lw=0.9, zorder=4))
ax.text(82.25, TOP - 19.5, 'server.js API', ha='center', va='center',
        fontsize=7.4, color=INK, zorder=5)
ax.add_patch(Rectangle((92.5, TOP - 22.0), 16.5, 5.0, fc='white', ec=RULE, lw=0.9, zorder=4))
ax.text(100.75, TOP - 19.5, 'SQLite', ha='center', va='center',
        fontsize=7.4, color=INK, zorder=5)

arrow(25.5, c1, 35.5, c1)
label(30.5, c1 + 5.4, 'RF coupling\n13.56 MHz · 0–5 cm')
arrow(57.5, c2, 71.5, c2)
label(64.5, c2 + 5.4, 'USB 2.0 Type-A\nPC/SC CCID')

# ── physician row ────────────────────────────────────────────────────────
box(72, TOP2, 39, 'Physician Terminal',
    ['Clinical portal — Flutter desktop',
     'authenticated clinician session (JWT)',
     'Layer 2 record + AI summary'])

# ── inter-station link ───────────────────────────────────────────────────
MID = (TRIAGE_BOT + TOP2) / 2
arrow(91.5, TRIAGE_BOT - 0.3, 91.5, TOP2 + 0.3, style='<|-|>', color=ACCENT, lw=1.6)
label(91.5, MID, 'LAN  ·  REST over TLS  ·  SSE tap broadcast', size=7.2)

# ── shared powered hub ───────────────────────────────────────────────────
hub_y = MID - 1.6
ax.add_patch(FancyBboxPatch((36, hub_y), 21, 3.2,
             boxstyle='round,pad=0,rounding_size=0.8',
             fc='white', ec=RULE, lw=0.9, zorder=3))
ax.text(46.5, hub_y + 1.6, 'powered USB hub', ha='center', va='center',
        fontsize=6.9, color=MUTE, zorder=4)
arrow(46.5, TRIAGE_BOT - 0.3, 46.5, hub_y + 3.2, ls=(0, (3, 2)), color=RULE, lw=1.1)

# ── legend ───────────────────────────────────────────────────────────────
handles = [
    Line2D([0], [0], color=INK, lw=1.5, label='Data path'),
    Line2D([0], [0], color=ACCENT, lw=1.6, label='Network link (TLS)'),
    Line2D([0], [0], color=RULE, lw=1.1, ls=(0, (3, 2)), label='USB power'),
]
leg = ax.legend(handles=handles, loc='center', bbox_to_anchor=(0.5, 0.022),
                frameon=False, fontsize=7.4, ncol=3, handlelength=2.4,
                columnspacing=3.4)
for t in leg.get_texts():
    t.set_color(MUTE)

fig.savefig('hardware-setup.png', dpi=260, bbox_inches='tight', facecolor='white')
print('written hardware-setup.png')
