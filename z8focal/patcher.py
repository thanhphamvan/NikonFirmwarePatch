"""Live View & EVF focal-length HUD overlay + Setup Menu toggle for Z8 C 3.11."""
import struct
from z8patch.image import BASE, Image, branch, data_off, movz, table_copy, va
from z8prores.package import require

CODE_AT = 0x40B9C000
SUB_AT = 0x40B9D000
LIMIT = 0x40B9F000
STATE_ROM = 0x40B9F000
STATE_RAM = 0xA1019F000

# Live View / lens hook sites
SITES = (
    (0x410788E0, 'focal_lens_hook',     0x97F9696E, True,  'zoom focal length telemetry hook'),
    (0x404356FC, 'focal_vis_diff_hook', 0x394CB768, False, 'part 0x3b zoom focal length diff hook'),
    (0x40435894, 'focal_vis_show_hook', 0x340000F4, False, 'part 0x3b zoom focal length visibility hook'),
    (0x4041CDE0, 'focal_draw_hook',     0x394C4A88, False, 'part 0x3b zoom focal length render hook'),
)

# Setup Menu (state 0x297) row 8 (stock hidden item 0x391A)
SETUP_HIDE_PTR_VA = 0x40597D00          # mov x1, #0x68d8 -> #0x68dc (skip 0x391A, keep 0x3959 hidden)
SETUP_HIDE_CNT_VA = 0x40597D10          # mov w2, #2      -> #1
SETUP_ROW8_VA = 0x43D59838              # 0x43D596D8 + 44 * 8
SETUP_EVPTR8_VA = 0x43D59EA8            # 0x43D59E68 + 8 * 8
SETUP_ROW8_TABLE_STOCK = 0x43D780E0
SETUP_ROW8_STOCK = (0x43A, 0xFFFF, 0xFFFF, 0, 0x10104D, 0, 0x391A, 0x40004, 0xFFFFFFFF, 0xFFFFFFFF, 2)
SETUP_REFRESH_OFF = 0x4BF7A90           # state 0x297 callbacks + 0x20
SETUP_REFRESH_STOCK = 0x40597E6C
SETUP_ENTER_ACTION = 0x403B1BA8

# Submenu built in verified unused stub state 0x1B1 from stock N-RAW quality template
STATES, STATE_SIZE = 0x4BFFCC0, 0x60
SUB_STATE, NRAW_STATE = 0x1B1, 0x10D
SUB_STOCK = (0xA028EA7C0, 0xA028B9510)  # state 0x1B1 stock callbacks and page record
SUB_ITEMS = (0x3252, 0x3250, 0x3251)    # stock 0x1B1's own private 3 option item IDs
NRAW_LAYOUT, NRAW_ROW, NRAW_EVENTS, NRAW_EVENT_COUNT, NRAW_PAGE = (
    0x3AA81D0, 0x3AA82E0, 0x3AE69B0, 14, 0x4BCC760,
)
NRAW_CALLBACKS_TAIL = (0x4056C954, 0x403B2210, 0x4056C958, 0x4056C960)
NRAW_OK, OK_EVENTS = 0x4056C964, (0x286, 0x28B, 0x2AE)

# String IDs (shared language tables: 3250..3253; "Off" reuses stock ID 375 / 0x177)
TABLE_DIR, BLOB_DIR, LANGUAGES, STOCK_IDS = 0x311C5A0, 0x387AF58, 36, 3137
ID_OFF = 375
ID_LABEL, ID_HELP, ID_WHILE_ZOOMING, ID_ALWAYS_ON = 3250, 3251, 3252, 3253
TEXTS_EN = (
    'Focal length display',
    'Show current focal length in the shooting display for non-PZ zoom lenses. '
    'Choose While zooming (hides after 2 s), Always on, or Off.',
    'While zooming',
    'Always on',
)


def _register_strings(stock, context):
    translations = []
    for lang in range(LANGUAGES):
        table = struct.unpack_from('<Q', stock, TABLE_DIR + 8 * lang)[0] - BASE
        blob = struct.unpack_from('<Q', stock, BLOB_DIR + 8 * lang)[0] - BASE
        offs = struct.unpack_from(f'<{STOCK_IDS}i', stock, table)
        pool = set(stock[blob + offs[0]:blob + offs[-1]].decode('utf-16le', 'replace'))
        for text in TEXTS_EN:
            missing = sorted({c for c in text if c != ' ' and c not in pool})
            require(not missing, f'Missing glyph(s) for focal-length string in language {lang}: {missing}')
        translations.append(list(TEXTS_EN))
    ids = context.add('focal-length', translations)
    require(ids == [ID_LABEL, ID_HELP, ID_WHILE_ZOOMING, ID_ALWAYS_ON], 'Focal-length string allocation')
    return ids


def _build_setup_row8_table(eg):
    """Copy Setup Menu row 8's transition table, retargeting 0x2A8 -> 0x1B1 and adding OK (0x28B)."""
    out = bytearray()
    seen = []
    off = data_off(SETUP_ROW8_TABLE_STOCK)
    for i in range(64):
        e, a, g, t = struct.unpack_from('<4Q', eg, off + 32 * i)
        if t == 0x2A8:
            seen.append(e)
            t = SUB_STATE
        out += struct.pack('<4Q', e, a, g, t)
        if e == 0x286:
            # Also open submenu on OK press (0x28B), matching row 7 (Viewfinder display size)
            out += struct.pack('<4Q', 0x28B, SETUP_ENTER_ACTION, 0, SUB_STATE)
        if e == 0x3BB:
            require(tuple(seen) == (0x286, 0x29F, 0x2AE), f'Unexpected row 8 transitions: {seen}')
            return bytes(out)
    raise ValueError('Setup Menu row 8 transition table lacks terminator')


def _build_menu(img, entries):
    eg = img.old
    at = SUB_AT
    pieces = {}

    def place(name, data, align=8):
        nonlocal at
        at = (at + align - 1) & ~(align - 1)
        pieces[name] = (at, bytes(data))
        at += len(data)
        return pieces[name][0]

    # 1. Submenu layout (copy of stock N-RAW quality page, title -> 3250)
    layout = bytearray(eg[NRAW_LAYOUT:NRAW_LAYOUT + 0x110])
    require(struct.unpack_from('<I', layout, 0x44)[0] == 0x8A6, 'Unexpected N-RAW layout title')
    struct.pack_into('<I', layout, 0x44, ID_LABEL)

    # 2. Submenu 3 radio rows: While zooming (0), Always on (1), Off (2)
    stock_row = struct.unpack_from('<11I', eg, NRAW_ROW)
    require(stock_row[0] == 0x35E and stock_row[6] == 0x3119, 'Unexpected N-RAW option row')
    labels = (ID_WHILE_ZOOMING, ID_ALWAYS_ON, ID_OFF)
    sub_rows = b''.join(
        struct.pack('<11I', labels[i], *stock_row[1:6], SUB_ITEMS[i], *stock_row[7:])
        for i in range(3)
    )

    # 3. Submenu option transition tables (OK/Right/Tap -> focal_sub_ok_hook, return 0x68D)
    ok_fn = entries['focal_sub_ok_hook']
    seen_ok = []

    def ok_change(e, a, g, t):
        if a == NRAW_OK:
            require(t == 0x68D, 'Unexpected N-RAW OK return target')
            seen_ok.append(e)
            return e, ok_fn, g, t
        return e, a, g, t

    opt_table = table_copy(eg, va(NRAW_EVENTS), ok_change)
    require(len(opt_table) == 32 * NRAW_EVENT_COUNT and tuple(seen_ok) == OK_EVENTS, seen_ok)

    # 4. Submenu page record (copy of N-RAW page with 3 rows)
    stock_page = eg[NRAW_PAGE:NRAW_PAGE + 0x50]
    require(
        struct.unpack_from('<4Q', stock_page)[:3] == (0x80001008, va(NRAW_LAYOUT), va(NRAW_ROW))
        and struct.unpack_from('<H', stock_page, 0x20)[0] == 2,
        'Unexpected N-RAW page record',
    )

    layout_at = place('layout', layout)
    rows_at = place('rows', sub_rows, align=4)
    tables_at = place('option_tables', opt_table * 3)
    evptrs_at = place('option_table_pointers', struct.pack('<3Q', *(tables_at + len(opt_table) * i for i in range(3))))
    cb_at = place('callbacks', struct.pack('<5Q', entries['focal_sub_entry_hook'], *NRAW_CALLBACKS_TAIL))
    page = bytearray(stock_page)
    struct.pack_into('<3Q', page, 8, layout_at, rows_at, evptrs_at)
    struct.pack_into('<H', page, 0x20, 3)
    page_at = place('page', page)
    row8_table_at = place('setup_row8_table', _build_setup_row8_table(eg))
    require(at <= LIMIT, 'Focal-length submenu tables exceed reserved cave')

    blob = bytearray(at - SUB_AT)
    for addr, data in pieces.values():
        blob[addr - SUB_AT:addr - SUB_AT + len(data)] = data
    img.put(
        SUB_AT, bytes(blob),
        'focal-length submenu tables (layout, 3 rows, option tables, callbacks, page, Setup row 8 table)',
        expect_zero=True,
    )

    # 5. Bind stub state 0x1B1 callbacks & page record
    rec = STATES + STATE_SIZE * SUB_STATE
    st = struct.unpack_from('<12Q', eg, rec)
    nraw_st = struct.unpack_from('<12Q', eg, STATES + STATE_SIZE * NRAW_STATE)
    require(
        st[0] == ((SUB_STATE << 16) | 2)
        and st[1] == nraw_st[1]
        and (st[5], st[10]) == SUB_STOCK
        and not any(st[2:5] + st[6:10] + st[11:]),
        f'Unexpected stub state {SUB_STATE:#x}',
    )
    img.put(rec + 0x28, struct.pack('<Q', cb_at),
            f'state {SUB_STATE:#x}: callbacks -> focal-length submenu',
            expect=struct.pack('<Q', SUB_STOCK[0]), offset=True)
    img.put(rec + 0x50, struct.pack('<Q', page_at),
            f'state {SUB_STATE:#x}: page record -> focal-length submenu',
            expect=struct.pack('<Q', SUB_STOCK[1]), offset=True)

    # 6. Unhide Setup Menu row 8 (item 0x391A), update its label/help/table, and wrap refresh callback
    img.put(SETUP_HIDE_PTR_VA, movz(1, 0x68DC),
            'Setup Menu entry: hide list points to [0x3959] (unhide 0x391A)',
            expect=movz(1, 0x68D8))
    img.put(SETUP_HIDE_CNT_VA, movz(2, 1, w=True),
            'Setup Menu entry: hide list count 2 -> 1 (unhide 0x391A)',
            expect=struct.pack('<I', 0x321F03E2))
    new_row8 = (ID_LABEL, ID_HELP, ID_LABEL, *SETUP_ROW8_STOCK[3:])
    img.put(SETUP_ROW8_VA, struct.pack('<11I', *new_row8),
            'Setup Menu row 8 (0x391A): label 3250, help 3251',
            expect=struct.pack('<11I', *SETUP_ROW8_STOCK))
    img.put(SETUP_EVPTR8_VA, struct.pack('<Q', row8_table_at),
            'Setup Menu row 8 transition table -> enter state 0x1B1',
            expect=struct.pack('<Q', SETUP_ROW8_TABLE_STOCK))
    img.put(SETUP_REFRESH_OFF, struct.pack('<Q', entries['focal_setup_refresh_hook']),
            'Setup Menu refresh callback -> focal_setup_refresh_hook',
            expect=struct.pack('<Q', SETUP_REFRESH_STOCK), offset=True)

    return dict(
        sub_state=hex(SUB_STATE),
        setting_id='0x02001d9f',
        setting_ram='0xa03d70418',
        setup_row_item='0x391a',
        option_items=[hex(i) for i in SUB_ITEMS],
        option_labels=list(labels),
        end=hex(at),
        tables={k: hex(v[0]) for k, v in pieces.items()},
    )


def build_main(stock, strings_context, unit):
    code, entries = unit('focal-length')
    require(CODE_AT + len(code) <= SUB_AT, 'Focal-length code exceeds reserved code window')
    img = Image(stock)
    img.put(CODE_AT, code, 'zoom focal length HUD and Setup Menu hooks', expect_zero=True)
    for addr, name, expected, link, purpose in SITES:
        img.put(addr, branch(addr, entries[name], link=link), purpose, expect=struct.pack('<I', expected))
    ids = _register_strings(stock, strings_context)
    menu_detail = _build_menu(img, entries)
    return img, dict(
        cave=hex(CODE_AT),
        bytes=len(code),
        state_rom=hex(STATE_ROM),
        state_ram=hex(STATE_RAM),
        string_ids=ids,
        menu=menu_detail,
        entries={k: hex(v) for k, v in sorted(entries.items())},
    )
