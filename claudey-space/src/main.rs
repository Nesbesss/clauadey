#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use eframe::egui;
use egui::{
    pos2, vec2, Align2, Color32, CornerRadius, FontId, Rect, Stroke, StrokeKind, UiBuilder,
};
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
    icon: Option<String>,
}

fn parse_args() -> Args {
    let mut a = Args {
        cwd: std::env::var("HOME").unwrap_or_else(|_| ".".into()),
        count: 2,
        cmd: "claude".into(),
        title: "Claudey".into(),
        icon: None,
    };
    let v: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < v.len() {
        match v[i].as_str() {
            "--cwd" if i + 1 < v.len() => { a.cwd = v[i + 1].clone(); i += 1; }
            "--count" if i + 1 < v.len() => { a.count = v[i + 1].parse().unwrap_or(2); i += 1; }
            "--cmd" if i + 1 < v.len() => { a.cmd = v[i + 1].clone(); i += 1; }
            "--title" if i + 1 < v.len() => { a.title = v[i + 1].clone(); i += 1; }
            "--icon" if i + 1 < v.len() => { a.icon = Some(v[i + 1].clone()); i += 1; }
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

fn load_icon(path: &str) -> Option<egui::IconData> {
    let img = image::open(path).ok()?.to_rgba8();
    let (w, h) = img.dimensions();
    Some(egui::IconData { rgba: img.into_raw(), width: w, height: h })
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

        // Transparent visuals; we paint our own translucent cards.
        let mut visuals = egui::Visuals::dark();
        visuals.panel_fill = Color32::TRANSPARENT;
        visuals.window_fill = Color32::TRANSPARENT;
        visuals.extreme_bg_color = Color32::from_rgb(0x0b, 0x0c, 0x0e);
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
    fn clear_color(&self, _v: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0] // transparent window
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        ui.ctx().request_repaint();

        while let Ok((_, ev)) = self.rx.try_recv() {
            if let PtyEvent::Exit = ev {
                self.live = self.live.saturating_sub(1);
                if self.live == 0 {
                    ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
                    return;
                }
            }
        }

        // Warp-like translucent palette.
        let pane_bg = Color32::from_rgba_unmultiplied(14, 15, 18, 214); // ~0.84
        let header_text = Color32::from_rgb(0x9a, 0x9f, 0xa8);
        let border = Color32::from_rgba_unmultiplied(255, 255, 255, 22);
        let sep = Color32::from_rgba_unmultiplied(255, 255, 255, 16);
        let accent = Color32::from_rgb(0xd9, 0x77, 0x57);

        let theme = self.theme.clone();
        let active = self.active;
        let cols = self.cols;
        let rows = self.rows;
        let folder = self.folder.clone();
        let n = self.backends.len();
        let backends = &mut self.backends;
        let mut clicked: Option<usize> = None;

        let painter = ui.painter().clone();
        let area = ui.max_rect();
        let pad = 12.0;
        let gap = 12.0;
        let header_h = 30.0;
        let inner = area.shrink(pad);
        let cw = (inner.width() - gap * (cols as f32 - 1.0)) / cols as f32;
        let ch = (inner.height() - gap * (rows as f32 - 1.0)) / rows as f32;
        let radius = CornerRadius::same(13);

        for i in 0..n {
            let r = i / cols;
            let c = i % cols;
            let x = inner.left() + c as f32 * (cw + gap);
            let y = inner.top() + r as f32 * (ch + gap);
            let cell = Rect::from_min_size(pos2(x, y), vec2(cw, ch));
            let is_active = i == active;

            // Card background.
            painter.rect_filled(cell, radius, pane_bg);

            // Header: accent dot + folder name + hairline separator.
            let hy = cell.top() + header_h / 2.0;
            painter.circle_filled(pos2(cell.left() + pad + 3.0, hy), 3.5, accent);
            painter.text(
                pos2(cell.left() + pad + 14.0, hy),
                Align2::LEFT_CENTER,
                &folder,
                FontId::monospace(11.0),
                header_text,
            );
            let sepy = cell.top() + header_h;
            painter.line_segment(
                [pos2(cell.left() + 1.0, sepy), pos2(cell.right() - 1.0, sepy)],
                Stroke::new(1.0, sep),
            );

            // Terminal in the remaining area.
            let term_rect = Rect::from_min_max(
                pos2(cell.left() + 12.0, sepy + 8.0),
                pos2(cell.right() - 12.0, cell.bottom() - 10.0),
            );
            let resp = ui
                .allocate_new_ui(UiBuilder::new().max_rect(term_rect), |ui| {
                    let term = TerminalView::new(ui, &mut backends[i])
                        .set_focus(is_active)
                        .set_theme(theme.clone())
                        .set_font(TerminalFont::new(FontSettings {
                            font_type: FontId::monospace(13.0),
                        }))
                        .set_size(term_rect.size());
                    ui.add(term)
                })
                .inner;
            if resp.clicked() {
                clicked = Some(i);
            }

            // Border / active ring on top.
            let stroke = if is_active {
                Stroke::new(1.5, accent)
            } else {
                Stroke::new(1.0, border)
            };
            painter.rect_stroke(cell, radius, stroke, StrokeKind::Inside);
        }

        if let Some(i) = clicked {
            self.active = i;
        }
    }
}

fn main() -> eframe::Result {
    env_logger::init();
    let args = parse_args();
    let app_name = args.title.clone();

    let mut viewport = egui::ViewportBuilder::default()
        .with_inner_size([1160.0, 760.0])
        .with_min_inner_size([560.0, 380.0])
        .with_title(&app_name)
        .with_transparent(true);
    if let Some(p) = &args.icon {
        if let Some(icon) = load_icon(p) {
            viewport = viewport.with_icon(std::sync::Arc::new(icon));
        }
    }

    let native_options = eframe::NativeOptions {
        viewport,
        ..Default::default()
    };
    eframe::run_native(
        &app_name,
        native_options,
        Box::new(move |cc| Ok(Box::new(App::new(cc, &args)))),
    )
}
