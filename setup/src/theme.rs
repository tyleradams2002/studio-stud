//! Studio Stud setup UI theme and reusable widgets.

use std::path::{Path, PathBuf};

use eframe::egui::{self, Color32, FontFamily, FontId, Id, Margin, RichText, Rounding, Stroke, Vec2};

// --- Palette ---
pub const BG: Color32 = Color32::from_rgb(0x14, 0x16, 0x1B);
pub const SURFACE: Color32 = Color32::from_rgb(0x1E, 0x21, 0x28);
pub const CARD: Color32 = Color32::from_rgb(0x25, 0x2A, 0x33);
pub const HAIRLINE: Color32 = Color32::from_rgb(0x2F, 0x35, 0x40);
pub const BORDER: Color32 = Color32::from_rgb(0x44, 0x4D, 0x5E);
pub const TEXT: Color32 = Color32::from_rgb(0xE6, 0xE9, 0xEF);
pub const MUTED: Color32 = Color32::from_rgb(0x9A, 0xA3, 0xB2);
pub const ACCENT: Color32 = Color32::from_rgb(0x19, 0xC3, 0xB1);
pub const ACCENT_HOVER: Color32 = Color32::from_rgb(0x5B, 0x8D, 0xEF);
pub const SUCCESS: Color32 = Color32::from_rgb(0x3F, 0xB9, 0x50);
pub const DANGER: Color32 = Color32::from_rgb(0xF8, 0x51, 0x49);
pub const WARNING: Color32 = Color32::from_rgb(0xD2, 0x99, 0x22);

pub const XS: f32 = 4.0;
pub const S: f32 = 8.0;
pub const M: f32 = 12.0;
pub const L: f32 = 16.0;

pub const R_CARD: f32 = 10.0;
pub const R_CONTROL: f32 = 8.0;

pub const STEPPER_ANIM_SECS: f32 = 0.12;
pub const CONTENT_ANIM_SECS: f32 = 0.15;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ToastSeverity {
    #[allow(dead_code)]
    Success,
    Warning,
    Danger,
}

pub fn apply_theme(ctx: &egui::Context) {
    let mut style = (*ctx.style()).clone();
    let mut visuals = egui::Visuals::dark();

    visuals.window_fill = BG;
    visuals.panel_fill = BG;
    visuals.extreme_bg_color = SURFACE;
    visuals.faint_bg_color = SURFACE;
    visuals.widgets.noninteractive.bg_fill = CARD;
    visuals.widgets.inactive.bg_fill = CARD;
    visuals.widgets.hovered.bg_fill = Color32::from_rgb(0x2E, 0x34, 0x40);
    visuals.widgets.active.bg_fill = Color32::from_rgb(0x35, 0x3D, 0x4A);
    visuals.widgets.inactive.fg_stroke = Stroke::new(1.0, TEXT);
    visuals.widgets.hovered.fg_stroke = Stroke::new(1.0, TEXT);
    visuals.widgets.active.fg_stroke = Stroke::new(1.0, TEXT);
    visuals.selection.bg_fill = ACCENT.gamma_multiply(0.35);
    visuals.selection.stroke = Stroke::new(1.0, ACCENT);
    visuals.hyperlink_color = ACCENT_HOVER;
    visuals.widgets.noninteractive.rounding = Rounding::same(R_CONTROL);
    visuals.widgets.inactive.rounding = Rounding::same(R_CONTROL);
    visuals.widgets.hovered.rounding = Rounding::same(R_CONTROL);
    visuals.widgets.active.rounding = Rounding::same(R_CONTROL);

    style.visuals = visuals;
    style.spacing.item_spacing = Vec2::new(M, M);
    style.spacing.button_padding = Vec2::new(L, S + 2.0);
    style.spacing.window_margin = Margin::same(L);

    style.text_styles.insert(
        egui::TextStyle::Heading,
        FontId::new(26.0, FontFamily::Proportional),
    );
    style.text_styles.insert(
        egui::TextStyle::Name("h2".into()),
        FontId::new(18.0, FontFamily::Proportional),
    );
    style.text_styles.insert(
        egui::TextStyle::Body,
        FontId::new(14.5, FontFamily::Proportional),
    );
    style.text_styles.insert(
        egui::TextStyle::Small,
        FontId::new(12.5, FontFamily::Proportional),
    );

    ctx.set_style(style);
}

pub fn window_icon() -> egui::IconData {
    let size = 32usize;
    let mut rgba = vec![0u8; size * size * 4];
    let accent = [0x19u8, 0xC3, 0xB1, 255];
    for y in 0..size {
        for x in 0..size {
            let i = (y * size + x) * 4;
            let in_round = {
                let cx = size as f32 / 2.0 - 0.5;
                let cy = size as f32 / 2.0 - 0.5;
                let r = size as f32 * 0.42;
                let dx = x as f32 - cx;
                let dy = y as f32 - cy;
                dx * dx + dy * dy <= r * r
            };
            if in_round {
                rgba[i..i + 4].copy_from_slice(&accent);
            }
        }
    }
    egui::IconData {
        rgba,
        width: size as u32,
        height: size as u32,
    }
}

pub fn logo_mark(ui: &mut egui::Ui, size: f32) {
    let (rect, _) = ui.allocate_exact_size(Vec2::splat(size), egui::Sense::hover());
    let painter = ui.painter();
    painter.rect_filled(rect, Rounding::same(6.0), ACCENT);
    painter.text(
        rect.center(),
        egui::Align2::CENTER_CENTER,
        "S",
        FontId::proportional(size * 0.55),
        BG,
    );
}

pub fn header_band(
    ui: &mut egui::Ui,
    title: &str,
    steps: &[&str],
    active_idx: usize,
    step_anim: f32,
) {
    ui.horizontal(|ui| {
        ui.add_space(S);
        logo_mark(ui, 36.0);
        ui.add_space(M);
        ui.vertical(|ui| {
            ui.label(RichText::new(title).color(TEXT).size(22.0).strong());
            stepper(ui, steps, active_idx, step_anim);
        });
    });
}

fn stepper(ui: &mut egui::Ui, steps: &[&str], active_idx: usize, anim: f32) {
    ui.horizontal(|ui| {
        ui.spacing_mut().item_spacing.x = S;
        for (i, label) in steps.iter().enumerate() {
            if i > 0 {
                let w = 24.0;
                let (rect, _) = ui.allocate_exact_size(Vec2::new(w, 4.0), egui::Sense::hover());
                let fill = if i <= active_idx {
                    ACCENT
                } else {
                    HAIRLINE
                };
                let t = if i == active_idx { anim } else if i < active_idx { 1.0 } else { 0.0 };
                let mid = HAIRLINE.lerp_to_gamma(fill, t);
                ui.painter().rect_filled(rect, 2.0, mid);
            }
            step_dot(ui, *label, i, active_idx);
        }
    });
}

fn step_dot(ui: &mut egui::Ui, label: &str, idx: usize, active: usize) {
    let done = idx < active;
    let current = idx == active;
    if current {
        let pill = egui::Frame::none()
            .fill(ACCENT.gamma_multiply(0.25))
            .stroke(Stroke::new(1.0, ACCENT))
            .rounding(Rounding::same(R_CONTROL))
            .inner_margin(Margin::symmetric(M, S))
            .show(ui, |ui| {
                ui.label(RichText::new(label).color(ACCENT).strong());
            });
        pill.response;
    } else if done {
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = XS;
            let (rect, _) = ui.allocate_exact_size(Vec2::splat(14.0), egui::Sense::hover());
            paint_check(ui.painter(), rect, SUCCESS, 2.0);
            ui.label(RichText::new(label).color(MUTED));
        });
    } else {
        ui.label(RichText::new(label).color(MUTED));
    }
}

/// Paints a checkmark inside `rect` without relying on a font glyph
/// (the bundled font renders `✓` as a missing-glyph box).
fn paint_check(painter: &egui::Painter, rect: egui::Rect, color: Color32, width: f32) {
    let p1 = rect.min + Vec2::new(rect.width() * 0.18, rect.height() * 0.52);
    let p2 = rect.min + Vec2::new(rect.width() * 0.42, rect.height() * 0.74);
    let p3 = rect.min + Vec2::new(rect.width() * 0.82, rect.height() * 0.26);
    painter.line_segment([p1, p2], Stroke::new(width, color));
    painter.line_segment([p2, p3], Stroke::new(width, color));
}

/// A clearly visible custom checkbox row. Returns true when toggled this frame.
pub fn checkbox_row(ui: &mut egui::Ui, checked: &mut bool, label: &str) -> bool {
    let mut toggled = false;
    ui.horizontal(|ui| {
        let (rect, resp) = ui.allocate_exact_size(Vec2::splat(22.0), egui::Sense::click());
        let hovered = resp.hovered();
        let fill = if *checked {
            ACCENT.gamma_multiply(0.20)
        } else if hovered {
            SURFACE
        } else {
            BG
        };
        let border = if *checked || hovered { ACCENT } else { BORDER };
        ui.painter()
            .rect(rect, Rounding::same(6.0), fill, Stroke::new(1.5, border));
        if *checked {
            paint_check(ui.painter(), rect, ACCENT, 2.2);
        }
        if resp.clicked() {
            *checked = !*checked;
            toggled = true;
        }
        ui.add_space(S);
        let lbl = ui.add(
            egui::Label::new(RichText::new(label).color(TEXT).size(14.5))
                .sense(egui::Sense::click()),
        );
        if lbl.clicked() {
            *checked = !*checked;
            toggled = true;
        }
    });
    toggled
}

/// Working card with an animated progress bar (used while installing).
pub fn progress_card(ui: &mut egui::Ui, message: &str, fraction: f32) {
    card(ui, |ui| {
        ui.horizontal(|ui| {
            ui.add(egui::Spinner::new().color(ACCENT));
            ui.add_space(M);
            ui.label(RichText::new(message).color(TEXT).size(16.0));
        });
        ui.add_space(M);
        ui.add(
            egui::ProgressBar::new(fraction)
                .animate(true)
                .desired_height(10.0)
                .fill(ACCENT),
        );
    });
}

pub fn section(ui: &mut egui::Ui, title: &str, subtitle: &str) {
    ui.add_space(S);
    ui.label(
        RichText::new(title)
            .font(FontId::new(18.0, FontFamily::Proportional))
            .color(TEXT)
            .strong(),
    );
    if !subtitle.is_empty() {
        ui.label(RichText::new(subtitle).color(MUTED).size(12.5));
    }
    ui.add_space(M);
}

pub fn card<R>(ui: &mut egui::Ui, add: impl FnOnce(&mut egui::Ui) -> R) -> R {
    egui::Frame::none()
        .fill(CARD)
        .stroke(Stroke::new(1.0, HAIRLINE))
        .rounding(Rounding::same(R_CARD))
        .inner_margin(Margin::same(L))
        .show(ui, add)
        .inner
}

pub fn toast(ui: &mut egui::Ui, severity: ToastSeverity, msg: &str) {
    let (bg, fg, icon) = match severity {
        ToastSeverity::Success => (SUCCESS.gamma_multiply(0.15), SUCCESS, "!"),
        ToastSeverity::Warning => (WARNING.gamma_multiply(0.15), WARNING, "!"),
        ToastSeverity::Danger => (DANGER.gamma_multiply(0.15), DANGER, "!"),
    };
    egui::Frame::none()
        .fill(bg)
        .rounding(Rounding::same(R_CONTROL))
        .inner_margin(Margin::symmetric(M, S))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.label(RichText::new(icon).color(fg).strong());
                ui.label(RichText::new(msg).color(TEXT).size(13.0));
            });
        });
    ui.add_space(S);
}

pub fn path_exists(path: &str) -> bool {
    !path.trim().is_empty() && Path::new(path.trim()).is_dir()
}

/// Fluid path row: the Browse button is pinned right, the text field fills all
/// remaining width so the row never overflows on resize. No status badge.
pub fn path_row(ui: &mut egui::Ui, path: &mut String, browse_label: &str, accept_drop: bool) -> bool {
    if accept_drop && let Some(p) = take_dropped_folder(ui.ctx()) {
        *path = p.display().to_string();
    }

    let drop_highlight = accept_drop && ui.ctx().input(|i| !i.raw.hovered_files.is_empty());
    if drop_highlight {
        ui.painter()
            .rect_stroke(ui.max_rect(), Rounding::same(R_CARD), Stroke::new(2.0, ACCENT));
    }

    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if secondary_button(ui, browse_label).clicked()
                && let Some(p) = rfd::FileDialog::new().pick_folder()
            {
                *path = p.display().to_string();
            }
            ui.add_space(S);
            let w = ui.available_width().max(120.0);
            ui.add_sized(
                [w, 30.0],
                egui::TextEdit::singleline(path).margin(Margin::symmetric(S, S)),
            );
        });
    });

    path_exists(path)
}

/// Middle-truncate a long path so it fits in `max_chars`, keeping head and tail.
pub fn truncate_middle(s: &str, max_chars: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= max_chars {
        return s.to_string();
    }
    if max_chars <= 3 {
        return "...".into();
    }
    let keep = max_chars - 3;
    let head = keep * 6 / 10;
    let tail = keep - head;
    let h: String = chars[..head].iter().collect();
    let t: String = chars[chars.len() - tail..].iter().collect();
    format!("{h}...{t}")
}

pub fn take_dropped_folder(ctx: &egui::Context) -> Option<PathBuf> {
    ctx.input(|i| {
        for f in &i.raw.dropped_files {
            if let Some(path) = &f.path {
                if path.is_dir() {
                    return Some(path.clone());
                }
            }
        }
        None
    })
}

pub fn primary_button(ui: &mut egui::Ui, label: &str) -> egui::Response {
    let btn = egui::Button::new(RichText::new(label).color(BG).strong())
        .fill(ACCENT)
        .rounding(Rounding::same(R_CONTROL))
        .min_size(Vec2::new(100.0, 32.0));
    ui.add(btn)
}

pub fn secondary_button(ui: &mut egui::Ui, label: &str) -> egui::Response {
    let btn = egui::Button::new(RichText::new(label).color(TEXT))
        .fill(SURFACE)
        .stroke(Stroke::new(1.0, HAIRLINE))
        .rounding(Rounding::same(R_CONTROL));
    ui.add(btn)
}

pub fn ghost_button(ui: &mut egui::Ui, label: &str) -> egui::Response {
    ui.add(
        egui::Button::new(RichText::new(label).color(ACCENT_HOVER))
            .fill(Color32::TRANSPARENT)
            .stroke(Stroke::new(0.0, Color32::TRANSPARENT)),
    )
}

/// A clean, left-aligned summary field: muted caption above the value, with a
/// Copy affordance pinned right. The value truncates and shows full text on hover.
pub fn summary_field(ui: &mut egui::Ui, label: &str, value: &str) {
    ui.label(RichText::new(label).color(MUTED).size(12.5));
    ui.add_space(XS);
    ui.horizontal(|ui| {
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            if ghost_button(ui, "Copy").clicked() {
                ui.ctx().copy_text(value.to_string());
            }
            ui.with_layout(egui::Layout::left_to_right(egui::Align::Center), |ui| {
                ui.add(egui::Label::new(RichText::new(value).color(TEXT).size(13.5)).truncate())
                    .on_hover_text(value);
            });
        });
    });
}

pub fn divider(ui: &mut egui::Ui) {
    ui.add_space(M);
    let w = ui.available_width();
    let (rect, _) = ui.allocate_exact_size(Vec2::new(w, 1.0), egui::Sense::hover());
    ui.painter()
        .line_segment([rect.left_top(), rect.right_top()], Stroke::new(1.0, HAIRLINE));
    ui.add_space(M);
}

pub fn content_alpha(ctx: &egui::Context, step_id: &str, step_changed: bool) -> f32 {
    let id = Id::new(("step_alpha", step_id));
    let target = if step_changed { 0.0 } else { 1.0 };
    ctx.animate_value_with_time(id, target, CONTENT_ANIM_SECS)
        .max(0.0)
        .min(1.0)
}

pub fn step_anim(ctx: &egui::Context, step_idx: usize) -> f32 {
    let id = Id::new(("step_anim", step_idx));
    ctx.animate_value_with_time(id, 1.0, STEPPER_ANIM_SECS)
}

pub fn open_folder(path: &Path) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("explorer").arg(path).spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("xdg-open").arg(path).spawn();
    }
}

pub fn success_card(ui: &mut egui::Ui, message: &str) -> egui::InnerResponse<()> {
    egui::Frame::none()
        .fill(SUCCESS.gamma_multiply(0.12))
        .stroke(Stroke::new(1.0, SUCCESS.gamma_multiply(0.5)))
        .rounding(Rounding::same(R_CARD))
        .inner_margin(Margin::same(L))
        .show(ui, |ui| {
            ui.horizontal(|ui| {
                ui.spacing_mut().item_spacing.x = XS + 2.0;
                let (rect, _) = ui.allocate_exact_size(Vec2::splat(18.0), egui::Sense::hover());
                paint_check(ui.painter(), rect, SUCCESS, 2.6);
                ui.label(RichText::new("Success").color(SUCCESS).strong());
            });
            ui.add_space(S);
            ui.label(RichText::new(message).color(TEXT));
        })
}

pub fn error_card(ui: &mut egui::Ui, message: &str) {
    egui::Frame::none()
        .fill(DANGER.gamma_multiply(0.12))
        .stroke(Stroke::new(1.0, DANGER.gamma_multiply(0.5)))
        .rounding(Rounding::same(R_CARD))
        .inner_margin(Margin::same(L))
        .show(ui, |ui| {
            ui.label(RichText::new("Installation failed").color(DANGER).strong());
            ui.add_space(S);
            egui::ScrollArea::vertical()
                .max_height(120.0)
                .show(ui, |ui| {
                    ui.label(RichText::new(message).color(TEXT).size(13.0));
                });
        });
}
