#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use eframe::egui;
use egui::{Color32, CornerRadius, FontId, Frame, Margin, RichText, Stroke, Vec2};
use egui_term::{
    BackendSettings, ColorPalette, FontSettings, PtyEvent, TerminalBackend, TerminalFont,
    TerminalTheme, TerminalView,
};
use std::path::PathBuf;
use std::sync::mpsc::Receiver;

struct Args {
    cwd: String,
    count: usize,
    cmd: String,
    title: String,
}

fn parse_args() -> Args {
    let mut a = Args {
        cwd: std::env::var("HOME").unwrap_or_else(|_| ".".into()),
        count: 2,
        cmd: "claude".into(),
        title: "Claudey".into(),
    };
    let v: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < v.len() {
        match v[i].as_str() {
            "--cwd" if i + 1 < v.len() => { a.cwd = v[i + 1].clone(); i += 1; }
            "--count" if i + 1 < v.len() => { a.count = v[i + 1].parse().unwrap_or(2); i += 1; }
            "--cmd" if i + 1 < v.len() => { a.cmd = v[i + 1].clone(); i += 1; }
            "--title" if i + 1 < v.len() => { a.title = v[i + 1].clone(); i += 1; }
            _ => {}
        }
        i += 1;
    }
    a
}

// Warp default-dark ANSI palette.
fn warp_palette() -> ColorPalette {
    ColorPalette {
        foreground: "#f1f1f1".into(),
        background: "#0b0c0e".into(),
        black: "#616161".into(),
        red: "#ff8272".into(),
        green: "#b4fa72".into(),
        yellow: "#fefdc2".into(),
        blue: "#a5d5fe".into(),
        magenta: "#ff8ffd".into(),
        cyan: "#d0d1fe".into(),
        white: "#f1f1f1".into(),
        bright_black: "#8e8e8e".into(),
        bright_red: "#ffc4bd".into(),
        bright_green: "#d6fcb9".into(),
        bright_yellow: "#fefdd5".into(),
        bright_blue: "#c1e3fe".into(),
        bright_magenta: "#ffb1fe".into(),
        bright_cyan: "#e5e6fe".into(),
        bright_white: "#feffff".into(),
        bright_foreground: None,
        dim_foreground: "#828482".into(),
        dim_black: "#0f0f0f".into(),
        dim_red: "#712b2b".into(),
        dim_green: "#5f6f3a".into(),
        dim_yellow: "#a17e4d".into(),
        dim_blue: "#456877".into(),
        dim_magenta: "#704d68".into(),
        dim_cyan: "#4d7770".into(),
        dim_white: "#8e8e8e".into(),
    }
}

struct App {
    backends: Vec<TerminalBackend>,
    folder: String,
    rx: Receiver<(u64, PtyEvent)>,
    live: usize,
    active: usize,
    theme: TerminalTheme,
    cols: usize,
    rows: usize,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>, args: &Args) -> Self {
        let (tx, rx) = std::sync::mpsc::channel();
        let folder = PathBuf::from(&args.cwd)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| "claude".into());

        let full = format!("{}; exec /bin/zsh -l", args.cmd);
        let count = args.count.max(1);
        let mut backends = Vec::new();
        for id in 0..count {
            let b = TerminalBackend::new(
                id as u64,
                cc.egui_ctx.clone(),
                tx.clone(),
                BackendSettings {
                    shell: "/bin/zsh".into(),
                    args: vec!["-l".into(), "-c".into(), full.clone()],
                    working_directory: Some(PathBuf::from(&args.cwd)),
                },
            )
            .expect("failed to start terminal backend");
            backends.push(b);
        }

        let cols = (count as f32).sqrt().ceil() as usize;
        let rows = (count + cols - 1) / cols;

        // Premium near-black chrome.
        let mut visuals = egui::Visuals::dark();
        let bg = Color32::from_rgb(0x08, 0x09, 0x0b);
        visuals.panel_fill = bg;
        visuals.window_fill = bg;
        visuals.extreme_bg_color = bg;
        cc.egui_ctx.set_visuals(visuals);

        Self {
            backends,
            folder,
            rx,
            live: count,
            active: 0,
            theme: TerminalTheme::new(Box::new(warp_palette())),
            cols,
            rows,
        }
    }
}

impl eframe::App for App {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        // Keep terminals live (cursor blink + prompt output render promptly).
        ui.ctx().request_repaint();

        // Drain PTY events; close window when every pane has exited.
        while let Ok((_, ev)) = self.rx.try_recv() {
            if let PtyEvent::Exit = ev {
                self.live = self.live.saturating_sub(1);
                if self.live == 0 {
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                    return;
                }
            }
        }

        let pane_bg = Color32::from_rgb(0x0b, 0x0c, 0x0e);
        let header_bg = Color32::from_rgb(0x10, 0x11, 0x14);
        let border = Color32::from_rgba_unmultiplied(255, 255, 255, 18);
        let accent = Color32::from_rgb(0xd9, 0x77, 0x57);
        let muted = Color32::from_rgb(0x8a, 0x8f, 0x98);
        let window_bg = Color32::from_rgb(0x08, 0x09, 0x0b);

        // Paint the window background (no CentralPanel in this eframe variant).
        ui.painter().rect_filled(ui.max_rect(), CornerRadius::ZERO, window_bg);

        let theme = self.theme.clone();
        let active = self.active;
        let cols = self.cols;
        let rows = self.rows;
        let folder = self.folder.clone();
        let n = self.backends.len();
        let backends = &mut self.backends;
        let mut clicked: Option<usize> = None;

        let gap = 10.0;
        let avail = ui.available_size();
        let cw = ((avail.x - gap * (cols as f32 - 1.0)) / cols as f32).max(80.0);
        let ch = ((avail.y - gap * (rows as f32 - 1.0)) / rows as f32).max(60.0);
        ui.spacing_mut().item_spacing = Vec2::splat(gap);

        let mut idx = 0usize;
        ui.vertical(|ui| {
            for _r in 0..rows {
                ui.horizontal(|ui| {
                    for _c in 0..cols {
                        if idx >= n {
                            break;
                        }
                        let i = idx;
                        idx += 1;
                        let is_active = i == active;
                        let stroke = if is_active {
                            Stroke::new(1.5, accent)
                        } else {
                            Stroke::new(1.0, border)
                        };
                        ui.allocate_ui(Vec2::new(cw, ch), |ui| {
                            Frame::default()
                                .fill(pane_bg)
                                .corner_radius(CornerRadius::same(12))
                                .stroke(stroke)
                                .inner_margin(Margin::same(0))
                                .show(ui, |ui| {
                                    ui.set_min_size(Vec2::new(cw, ch));
                                    // Header strip: accent dot + folder.
                                    Frame::default()
                                        .fill(header_bg)
                                        .inner_margin(Margin::symmetric(12, 6))
                                        .show(ui, |ui| {
                                            ui.set_width(ui.available_width());
                                            ui.horizontal(|ui| {
                                                let (r, _) = ui.allocate_exact_size(
                                                    Vec2::new(7.0, 7.0),
                                                    egui::Sense::hover(),
                                                );
                                                ui.painter().circle_filled(r.center(), 3.5, accent);
                                                ui.label(
                                                    RichText::new(&folder)
                                                        .color(muted)
                                                        .monospace()
                                                        .size(11.0),
                                                );
                                            });
                                        });
                                    // Terminal fills the rest of the card (explicit
                                    // size — available_size() can collapse to zero).
                                    let term_size =
                                        Vec2::new((cw - 2.0).max(40.0), (ch - 32.0).max(40.0));
                                    let term = TerminalView::new(ui, &mut backends[i])
                                        .set_focus(is_active)
                                        .set_theme(theme.clone())
                                        .set_font(TerminalFont::new(FontSettings {
                                            font_type: FontId::monospace(13.0),
                                        }))
                                        .set_size(term_size);
                                    if ui.add(term).clicked() {
                                        clicked = Some(i);
                                    }
                                });
                        });
                    }
                });
            }
        });

        if let Some(i) = clicked {
            self.active = i;
        }
    }
}

fn main() -> eframe::Result {
    env_logger::init();
    let args = parse_args();
    let app_name = args.title.clone();
    let native_options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_inner_size([1160.0, 760.0])
            .with_min_inner_size([560.0, 380.0])
            .with_title(&app_name),
        ..Default::default()
    };
    eframe::run_native(
        &app_name,
        native_options,
        Box::new(move |cc| Ok(Box::new(App::new(cc, &args)))),
    )
}
