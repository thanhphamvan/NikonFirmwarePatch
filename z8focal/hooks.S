// Live View & EVF focal length HUD for non-PZ zoom lenses (Z-mount and FTZ)
// with in-camera Setup Menu toggle (row 8, item 0x391A, stub state 0x1B1).
//
// Persistent mode stored in verified unused native Setup setting 0x02001D9F
// (RAM 0xA03D70418, ROM default 0x440394E8 == 0):
//   0 = While zooming (default: shows on zoom change, auto-hides after 2.0 s)
//   1 = Always on     (shows continuously for non-PZ zoom lenses on info DISP)
//   2 = Off           (full bypass: no lens reads, no stock calls, telemetry buffer untouched)
//
// Leaves the Power Zoom capability bit [0xA032CFF88 + 0x200] untouched so
// Power Zoom button bindings, control-ring menus, and the popup zoom bar
// (part 0x41) are unaffected on manual-zoom lenses.
//
// Private state in zero-initialized DRAM (RAM alias of 0x40B9F000, inside
// still-photo-tools 0x40BA0000 loader floor; 0x40B9F000 is RX, 0xA1019F000 RW):
//   0xA1019F000 + 0x0 : u8  g_zoom_fl_active (1 during 2 s zoom display window)
//   0xA1019F000 + 0x1 : u8  g_zoom_fl_prev   (last active state seen by 0x40435658)
//   0xA1019F000 + 0x4 : u32 g_last_fl_tenths (previous fl_tenths; 0 = detached/init)
//   0xA1019F000 + 0x8 : u64 g_hide_deadline  (CNTPCT_EL0 expiry tick)

#define FOCAL_SETTING_LO  0x1d9f
#define FOCAL_SETTING_HI  0x0200
#define FOCAL_SETUP_SLOT  0x45

// Branch to \unsafe unless fl_tenths in \fl prints in <= 7 chars. Stock 0x4041CCC4 sprintf()s it
// unbounded into an 8-byte stack buffer with saved x21 right behind: "%d.%dmm" fits below
// 1000.0 mm, "%dmm" fits for whole mm. Checked where the text is shown and drawn, because the
// lens hook validates zoom lenses only and the HUD value can be stale or from another lens.
.macro FL_FITS fl, tmp, tmp2, unsafe
    cbz     \fl, \unsafe
    movz    \tmp, #10000
    cmp     \fl, \tmp
    b.lo    8f                      // < 1000.0 mm
    movz    \tmp, #0x4240
    movk    \tmp, #0xf, lsl #16     // 1000000 tenths: "%dmm" would need 8 chars
    cmp     \fl, \tmp
    b.hs    \unsafe
    movz    \tmp, #10
    udiv    \tmp2, \fl, \tmp
    msub    \tmp2, \tmp2, \tmp, \fl
    cbnz    \tmp2, \unsafe          // fractional mm at >= 1000 mm
8:
.endm

.text

// ---------------------------------------------------------------------------
// 1. Lens telemetry hook (replaces 0x410788E0: bl 0x40ED2E98 in 0x41078568)
// ---------------------------------------------------------------------------
.global focal_lens_hook
focal_lens_hook:
    stp     x19, x30, [sp, #-32]!
    stp     x20, x21, [sp, #16]
    mov     x19, x0                 // x19 = &buf
    mov     w20, wzr                // w20 = fl_tenths (0 => not a zoom lens)

    // Off: clear private state, hide if shown, and pass the stock buffer on untouched.
    movz    x13, #0x0418
    movk    x13, #0x03d7, lsl #16
    movk    x13, #0x000a, lsl #32
    ldr     w13, [x13]
    cmp     w13, #2
    b.eq    .Lno_zoom

    // Load lens_type = *(uint32_t *)0xA045A58E0
    movz    x8, #0x58e0
    movk    x8, #0x045a, lsl #16
    movk    x8, #0x000a, lsl #32
    ldr     w8, [x8]

    cmp     w8, #1                  // Z-mount (ML_LENS)?
    b.eq    .Lz_mount
    cmp     w8, #3                  // F-mount / FTZ (F_LENS)?
    b.eq    .Lf_mount
    b       .Lno_zoom

.Lz_mount:
    ldr     w9,  [x19, #0x18]       // min_int  (prop 0x75)
    ldr     w10, [x19, #0x1c]       // min_frac (prop 0x74)
    ldr     w11, [x19, #0x20]       // max_int  (prop 0x73)
    ldr     w12, [x19, #0x24]       // max_frac (prop 0x72)
    cbz     w11, .Lno_zoom          // max_int == 0 -> not ready
    movz    w13, #0xffff
    cmp     w11, w13
    b.eq    .Lno_zoom               // max_int == 0xffff -> invalid
    cmp     w9, w11
    b.ne    .Lz_is_zoom
    cmp     w10, w12
    b.eq    .Lno_zoom               // min == max -> prime lens

.Lz_is_zoom:
    ldr     w8, [x19, #0x4]         // stock fl_tenths (from prop 0x12d/0x12c)
    cbz     w8, .Lz_fallback
    movz    w13, #50000
    cmp     w8, w13
    b.lo    .Lz_have_fl

.Lz_fallback:
    // Fallback to cmd 0x20 cur_fl2 (prop 0x112 int, prop 0x111 frac16)
    ldr     w9,  [x19, #0x10]       // cur_int
    ldr     w10, [x19, #0x14]       // cur_frac16
    cbz     w9, .Lno_zoom
    movz    w13, #5000
    cmp     w9, w13
    b.hs    .Lno_zoom
    movz    w13, #10
    mul     w8, w9, w13             // cur_int * 10
    mul     w10, w10, w13           // cur_frac16 * 10
    add     w10, w10, #0x8000       // + 0.5 * 65536
    lsr     w10, w10, #16
    add     w8, w8, w10
    str     w8, [x19, #0x4]

.Lz_have_fl:
    // Keep non-PZ string <= 7 chars for 0x4041CCC4's 8-byte stack buffer:
    // for >= 1000.0mm (10000 tenths), round to whole mm so rem == 0 ("%dmm").
    ldrb    w9, [x19, #0x0]         // is_pz
    cbnz    w9, .Lz_done
    movz    w13, #10000
    cmp     w8, w13
    b.lo    .Lz_done
    add     w9, w8, #5
    movz    w10, #10
    udiv    w9, w9, w10
    mul     w8, w9, w10
    str     w8, [x19, #0x4]

.Lz_done:
    mov     w20, w8                 // w20 = valid fl_tenths
    b       .Lupdate_timer

.Lf_mount:
    // F-mount / FTZ: check zoom via prop 0x1fb (min) != prop 0x1fc (max)
    movz    w0, #0x1fb
    bl      original_4109E130
    mov     w21, w0                 // w21 = min_raw
    movz    w0, #0x1fc
    bl      original_4109E130       // w0 = max_raw
    cbz     w0, .Lno_zoom
    cmp     w21, w0
    b.eq    .Lno_zoom               // prime F-mount lens

    // Decode current F-mount focal length via stock 0x41083618 (returns Q24.8 mm)
    bl      original_41083618
    cbz     w0, .Lno_zoom
    movz    w9, #10
    mov     w8, w0                  // zero-extend w0 into x8
    mul     x8, x8, x9
    add     x8, x8, #128
    lsr     x8, x8, #8              // fl_tenths = round(q8 * 10 / 256)
    cbz     w8, .Lno_zoom
    movz    w13, #50000
    cmp     w8, w13
    b.hs    .Lno_zoom
    movz    w13, #10000
    cmp     w8, w13
    b.lo    .Lf_store_fl
    add     w9, w8, #5
    movz    w10, #10
    udiv    w9, w9, w10
    mul     w8, w9, w10
.Lf_store_fl:
    str     w8, [x19, #0x4]
    mov     w20, w8                 // w20 = valid fl_tenths
    b       .Lupdate_timer

.Lno_zoom:
    // No zoom lens attached (or prime / detached): clear state & hide if active.
    movz    x8, #0xf000
    movk    x8, #0x1019, lsl #16
    movk    x8, #0x000a, lsl #32
    ldrb    w21, [x8, #0]           // w21 = prev active
    strb    wzr, [x8, #0]           // g_zoom_fl_active = 0
    str     wzr, [x8, #4]           // g_last_fl_tenths = 0
    str     xzr, [x8, #8]           // g_hide_deadline = 0
    cbz     w21, .Lexit
    b       .Lwake_hud

.Lupdate_timer:
    // Zoom lens attached with fl_tenths in w20 (> 0).
    // Read Setup Menu setting 0x02001D9F from RAM 0xA03D70418:
    //   0 = While zooming (2 s auto-hide), 1 = Always on. Off left at the hook entry.
    movz    x8, #0xf000
    movk    x8, #0x1019, lsl #16
    movk    x8, #0x000a, lsl #32
    movz    x13, #0x0418
    movk    x13, #0x03d7, lsl #16
    movk    x13, #0x000a, lsl #32
    ldr     w13, [x13]
    cmp     w13, #1
    b.eq    .Lmode_always

    // Mode 0 (While zooming): show for 2 seconds whenever fl_tenths changes.
    ldrb    w21, [x8, #0]           // w21 = prev active
    ldr     w9,  [x8, #4]           // w9  = g_last_fl_tenths
    str     w20, [x8, #4]           // g_last_fl_tenths = fl_tenths

    mrs     x10, cntpct_el0         // x10 = now
    cbz     w9, .Lcheck_deadline    // first reading after boot/attach: stay hidden
    cmp     w9, w20
    b.eq    .Lcheck_deadline        // focal length unchanged

    // Focal length changed: arm 2.0-second display deadline (now + 2 * CNTFRQ_EL0)
    mrs     x11, cntfrq_el0
    add     x11, x10, x11, lsl #1
    str     x11, [x8, #8]           // g_hide_deadline = now + 2s
    mov     w12, #1
    strb    w12, [x8, #0]           // g_zoom_fl_active = 1
    b       .Lexit

.Lmode_always:
    // Mode 1 (Always on): track focal length continuously, never auto-hide.
    ldrb    w21, [x8, #0]
    str     w20, [x8, #4]
    mov     w12, #1
    strb    w12, [x8, #0]
    str     xzr, [x8, #8]
    cbnz    w21, .Lexit
    b       .Lwake_hud

.Lcheck_deadline:
    ldr     x11, [x8, #8]           // x11 = g_hide_deadline
    cmp     x10, x11
    cset    w12, lo                 // active = (now < deadline)
    strb    w12, [x8, #0]
    cbnz    w12, .Lexit             // still active
    cbz     w21, .Lexit             // was already hidden -> no HUD wake needed

.Lwake_hud:
    // Active state transitioned: wake HUD task (mirrors 0x4042799C timer expiry)
    bl      original_403DB984
    mov     w1, #0x4
    bl      original_403DBA50

.Lexit:
    mov     x0, x19                 // restore &buf for 0x40ED2E98
    ldp     x20, x21, [sp, #16]
    ldp     x19, x30, [sp], #32
    b       original_40ED2E98

// ---------------------------------------------------------------------------
// 2. Part 0x3b dirty-diff hook (replaces 0x404356FC: ldrb w8, [x27, #0x32d])
//
// All registers w19..w29, x27 (cur state), x9 (prev state), w10 ([x9+0x56])
// are live. x11, x12, x13, x14 are dead scratch registers.
// Restores flags from `cmp w19, w10` before returning to 0x40435700.
// ---------------------------------------------------------------------------
.global focal_vis_diff_hook
focal_vis_diff_hook:
    ldrb    w8, [x27, #0x32d]       // original instruction at 0x404356FC
    movz    x11, #0xf000
    movk    x11, #0x1019, lsl #16
    movk    x11, #0x000a, lsl #32
    movz    x13, #0x0418
    movk    x13, #0x03d7, lsl #16
    movk    x13, #0x000a, lsl #32
    ldr     w14, [x13]              // mode: 0=zoom, 1=always, 2=off
    mov     w12, wzr
    cmp     w14, #2
    b.eq    1f                      // Off -> cur_extra = 0
    cmp     w14, #1
    b.eq    3f                      // Always on -> check fl_tenths != 0
    ldrb    w12, [x11, #0]          // While zooming -> g_zoom_fl_active
    cbz     w12, 1f
    mrs     x13, cntpct_el0
    ldr     x14, [x11, #8]          // g_hide_deadline
    cmp     x13, x14
    cset    w12, lo
    cbz     w12, 1f
3:  ldr     w12, [x27, #0x314]      // fl_tenths != 0?
    cmp     w12, #0
    cset    w12, ne                 // w12 = cur_extra
1:  ldrb    w13, [x11, #1]          // w13 = prev_extra
    strb    w12, [x11, #1]          // g_zoom_fl_prev = cur_extra
    cmp     w12, w13
    b.eq    2f
    b       original_404357C4       // active state toggled -> update part 0x3b
2:  cmp     w19, w10                // restore flags for 0x40435700 b.ne
    b       original_40435700

// ---------------------------------------------------------------------------
// 3. Part 0x3b sub[0] visibility hook (replaces 0x40435894: cbz w20, 0x404358B0)
//
// Reached only when part 0x3b is dirty, [x27+0x32d]==0 (not Hi-Res Zoom),
// and (w28 & 1) != 0 (standard info DISP mode; hides on Clean DISP).
// x8, x9, x10 are dead scratch registers.
// ---------------------------------------------------------------------------
.global focal_vis_show_hook
focal_vis_show_hook:
    cbnz    w20, 1f                 // genuine PZ -> show
    movz    x8, #0x0418
    movk    x8, #0x03d7, lsl #16
    movk    x8, #0x000a, lsl #32
    ldr     w9, [x8]                // mode: 0=zoom, 1=always, 2=off
    cmp     w9, #2
    b.eq    2f                      // Off -> hide
    cmp     w9, #1
    b.eq    3f                      // Always on -> check fl_tenths != 0
    movz    x8, #0xf000
    movk    x8, #0x1019, lsl #16
    movk    x8, #0x000a, lsl #32
    ldrb    w9, [x8, #0]            // g_zoom_fl_active
    cbz     w9, 2f
    mrs     x9, cntpct_el0
    ldr     x10, [x8, #8]           // g_hide_deadline
    cmp     x9, x10
    b.hs    2f
3:  ldr     w9, [x27, #0x314]       // fl_tenths
    FL_FITS w9, w10, w8, 2f
1:  b       original_40435898       // show part 0x3b sub[0]
2:  b       original_404358B0       // hide

// ---------------------------------------------------------------------------
// 4. Part 0x3b render hook (replaces 0x4041CDE0: ldrb w8, [x20, #0x312])
//
// Reached when drawing part 0x3b sub[0] ([x20+0x32d] == 0).
// If w8 != 0, 0x4041CDE8 formats [x20+0x314] as "%d.%dmm" or "%dmm".
// If w8 == 0, 0x4041CF50 falls back to Non-CPU lens [x20+0x58].
// x9, x10 are dead scratch registers.
// ---------------------------------------------------------------------------
.global focal_draw_hook
focal_draw_hook:
    ldrb    w8, [x20, #0x312]       // stock is_pz
    cbnz    w8, 1f
    movz    x9, #0x0418
    movk    x9, #0x03d7, lsl #16
    movk    x9, #0x000a, lsl #32
    ldr     w10, [x9]               // mode: 0=zoom, 1=always, 2=off
    cmp     w10, #2
    b.eq    1f                      // Off -> keep w8 == 0 (stock Non-CPU path)
    cmp     w10, #1
    b.eq    3f                      // Always on -> format fl_tenths if != 0
    movz    x9, #0xf000
    movk    x9, #0x1019, lsl #16
    movk    x9, #0x000a, lsl #32
    ldrb    w10, [x9, #0]           // g_zoom_fl_active
    cbz     w10, 1f
    mrs     x10, cntpct_el0
    ldr     x9, [x9, #8]            // g_hide_deadline
    cmp     x10, x9
    b.hs    1f
3:  ldr     w9, [x20, #0x314]       // fl_tenths
    FL_FITS w9, w10, w8, 4f         // w8 is scratch here, so set it on both ways out
    mov     w8, #1
    b       1f
4:  mov     w8, wzr                 // unsafe or zero: stock Non-CPU path
1:  b       original_4041CDE4

// ---------------------------------------------------------------------------
// 5. Setup Menu & Submenu callbacks (state 0x297 row 8 / stub state 0x1B1)
// ---------------------------------------------------------------------------

// Helper: w0 = clamped mode (0=While zooming, 1=Always on, 2=Off) via settings_get.
focal_get_mode:
    str     x30, [sp, #-16]!
    movz    w0, #FOCAL_SETTING_LO
    movk    w0, #FOCAL_SETTING_HI, lsl #16
    bl      original_403EC398
    cmp     w0, #2
    csel    w0, w0, wzr, ls
    ldr     x30, [sp], #16
    ret

// Setup Menu (state 0x297) refresh wrapper (replaces 0x4BF7A70 + 0x20):
// Calls stock 0x40597E6C, then paints "ZOOM" / "ON" / "OFF" into item 0x391A's
// value child 0x4BA7 using Setup Menu's dedicated text slot 0x45.
.global focal_setup_refresh_hook
focal_setup_refresh_hook:
    stp     x19, x30, [sp, #-32]!
    str     x20, [sp, #16]
    mov     x19, x0
    bl      original_40597E6C
    mov     x0, x19
    movz    w1, #0x391a
    movz    w2, #0x4ba7
    bl      original_4050A6F0
    cbz     x0, 9f
    mov     x20, x0
    bl      original_403F62D8
    mov     x0, x20
    bl      original_403F1A44
    bl      focal_get_mode
    adr     x9, focal_mode_texts
    add     x0, x9, w0, uxtw #3
    mov     w1, #FOCAL_SETUP_SLOT
    mov     w2, #0x46
    bl      original_403F2920
    mov     x0, x20
    mov     w1, #3
    mov     w2, #FOCAL_SETUP_SLOT
    bl      original_403F61EC
9:  ldr     x20, [sp, #16]
    ldp     x19, x30, [sp], #32
    ret

// Submenu (state 0x1B1) entry callback: places cursor & active mark on current mode.
.global focal_sub_entry_hook
focal_sub_entry_hook:
    stp     x19, x30, [sp, #-32]!
    str     x20, [sp, #16]
    mov     x19, x0
    bl      focal_get_mode
    adr     x9, focal_sub_items
    ldrh    w20, [x9, w0, uxtw #1]
    bl      original_403AE0F8       // entry guard (1 = keep cursor)
    cmp     w0, #1
    b.eq    1f
    mov     x0, x19
    mov     w1, w20
    bl      original_403B0048
1:  mov     x0, x19
    mov     w1, w20
    mov     w2, #1
    ldr     x20, [sp, #16]
    ldp     x19, x30, [sp], #32
    b       original_403B00B8

// Submenu (state 0x1B1) OK action: persists selected row (0/1/2) to native Setup
// setting 0x02001D9F via 0x403EC39C, resets runtime zoom window, and wakes HUD.
.global focal_sub_ok_hook
focal_sub_ok_hook:
    ldr     x9, [x0]
    ldrh    w11, [x9, #0x58]
    ldrh    w10, [x9, #0x32]
    add     w10, w10, w11
    cmp     w10, #2
    b.hi    9f
    stp     x19, x30, [sp, #-16]!
    mov     w19, w10
    movz    w0, #FOCAL_SETTING_LO
    movk    w0, #FOCAL_SETTING_HI, lsl #16
    mov     w1, w19
    bl      original_403EC39C       // persist to native NVRAM setting 0x02001D9F
    // Clear active zoom timer window so mode change takes effect cleanly
    movz    x8, #0xf000
    movk    x8, #0x1019, lsl #16
    movk    x8, #0x000a, lsl #32
    strb    wzr, [x8, #0]
    str     xzr, [x8, #8]
    // Wake HUD task so Live View immediately reflects Always on / Off
    bl      original_403DB984
    mov     w1, #0x4
    bl      original_403DBA50
    ldp     x19, x30, [sp], #16
9:  ret

// ---------------------------------------------------------------------------
// Read-only constant tables inside .text (8-byte stride for ASCII labels)
// ---------------------------------------------------------------------------
    .balign 8
focal_mode_texts:
    .asciz  "ZOOM"
    .balign 8
    .asciz  "ON"
    .balign 8
    .asciz  "OFF"
    .balign 8
focal_sub_items:
    .hword  0x3252, 0x3250, 0x3251, 0x0000
