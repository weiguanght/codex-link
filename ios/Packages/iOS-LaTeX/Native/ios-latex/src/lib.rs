use std::cell::RefCell;
use std::ffi::{c_char, CString};
use std::ptr;

use ratex_layout::{layout, to_display_list, validate_layout, LayoutOptions};
use ratex_types::{
    color::Color,
    display_item::{DisplayItem, DisplayList},
    math_style::MathStyle,
    path_command::PathCommand,
};

const MAX_INPUT_BYTES: usize = 256 * 1024;

thread_local! {
    static LAST_ERROR: RefCell<Option<CString>> = const { RefCell::new(None) };
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct IOSLaTeXColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[repr(C)]
pub struct IOSLaTeXResult {
    pub data: *const u8,
    pub length: usize,
}

fn layout_list(latex: &str, style: i32, color: IOSLaTeXColor) -> Result<DisplayList, String> {
    let style = match style {
        0 => MathStyle::Text,
        1 => MathStyle::Display,
        -1 => {
            let s = latex.trim();
            if (s.starts_with(r"\(") && s.ends_with(r"\)"))
                || (!s.starts_with("$$") && s.len() >= 2 && s.starts_with('$') && s.ends_with('$'))
            {
                MathStyle::Text
            } else {
                MathStyle::Display
            }
        }
        _ => return Err("Invalid layout style".into()),
    };
    if [color.r, color.g, color.b, color.a]
        .iter()
        .any(|channel| !(0.0..=1.0).contains(channel))
    {
        return Err("Color components must be finite values in [0, 1]".into());
    }
    let color = Color::new(color.r, color.g, color.b, color.a);
    let parsed = ratex_parser::parse(latex).map_err(|error| error.to_string())?;
    let options = LayoutOptions::default().with_style(style).with_color(color);
    let laid_out = layout(&parsed, &options);
    validate_layout(&laid_out)?;
    Ok(to_display_list(&laid_out))
}

/// # Safety
/// For nonempty input, utf8 must point to length initialized bytes for this call.
#[no_mangle]
pub unsafe extern "C" fn ios_latex_layout(
    utf8: *const u8,
    length: usize,
    style: i32,
    color: IOSLaTeXColor,
) -> IOSLaTeXResult {
    LAST_ERROR.with(|error| error.replace(None));
    let result = if length > MAX_INPUT_BYTES {
        Err(format!("Formula exceeds {MAX_INPUT_BYTES} UTF-8 bytes"))
    } else if length == 0 {
        layout_list("", style, color)
    } else if utf8.is_null() {
        Err("Missing UTF-8 input".into())
    } else {
        let bytes = unsafe { std::slice::from_raw_parts(utf8, length) };
        std::str::from_utf8(bytes)
            .map_err(|error| error.to_string())
            .and_then(|latex| layout_list(latex, style, color))
    };
    match result {
        Ok(list) => {
            let buffer = encode(&list).into_boxed_slice();
            let length = buffer.len();
            IOSLaTeXResult {
                data: Box::into_raw(buffer).cast::<u8>(),
                length,
            }
        }
        Err(message) => {
            let message = CString::new(message.replace('\0', "�")).ok();
            LAST_ERROR.with(|error| error.replace(message));
            IOSLaTeXResult {
                data: ptr::null(),
                length: 0,
            }
        }
    }
}

/// # Safety
/// Result must come from ios_latex_layout and be freed at most once.
#[no_mangle]
pub unsafe extern "C" fn ios_latex_free(result: IOSLaTeXResult) {
    if !result.data.is_null() {
        let slice = ptr::slice_from_raw_parts_mut(result.data.cast_mut(), result.length);
        unsafe { drop(Box::from_raw(slice)) };
    }
}

#[no_mangle]
pub extern "C" fn ios_latex_last_error() -> *const c_char {
    LAST_ERROR.with(|error| {
        error
            .borrow()
            .as_ref()
            .map_or(ptr::null(), |message| message.as_ptr())
    })
}

#[no_mangle]
pub extern "C" fn ios_latex_has_chemistry() -> u32 {
    u32::from(cfg!(feature = "mhchem"))
}

// Versioned little-endian encoding. Layout units keep the full f64 precision.
// Positions and colors are written in each draw operation's rendering order.
struct Writer(Vec<u8>);

impl Writer {
    fn byte(&mut self, value: u8) {
        self.0.push(value);
    }
    fn integer(&mut self, value: u32) {
        self.0.extend(value.to_le_bytes());
    }

    fn numbers(&mut self, values: &[f64]) {
        for &value in values {
            self.0
                .extend(if value.is_finite() { value } else { 0.0 }.to_le_bytes());
        }
    }

    fn color(&mut self, color: Color) {
        for component in [color.r, color.g, color.b, color.a] {
            self.0.extend(component.to_le_bytes());
        }
    }

    fn path(&mut self, command: &PathCommand) {
        match *command {
            PathCommand::MoveTo { x, y } => {
                self.byte(0);
                self.numbers(&[x, y]);
            }
            PathCommand::LineTo { x, y } => {
                self.byte(1);
                self.numbers(&[x, y]);
            }
            PathCommand::CubicTo {
                x1,
                y1,
                x2,
                y2,
                x,
                y,
            } => {
                self.byte(2);
                self.numbers(&[x1, y1, x2, y2, x, y]);
            }
            PathCommand::QuadTo { x1, y1, x, y } => {
                self.byte(3);
                self.numbers(&[x1, y1, x, y]);
            }
            PathCommand::Close => self.byte(4),
        }
    }
}

fn encode(list: &DisplayList) -> Vec<u8> {
    let mut writer = Writer(Vec::with_capacity(32 + 64 * list.items.len()));
    writer.0.extend(b"NMT\x01");
    writer.numbers(&[list.width, list.height, list.depth]);
    writer.integer(list.items.len() as u32);
    for item in &list.items {
        match item {
            DisplayItem::GlyphPath {
                x,
                y,
                scale,
                font,
                char_code,
                color,
            } => {
                writer.byte(0);
                writer.numbers(&[*x, *y, *scale]);
                writer.color(*color);
                writer.integer(*char_code);
                writer.byte(font.len() as u8);
                writer.0.extend(font.as_bytes());
            }
            DisplayItem::Line {
                x,
                y,
                width,
                thickness,
                color,
                dashed,
            } => {
                writer.byte(1);
                writer.numbers(&[*x, *y, *width, *thickness]);
                writer.color(*color);
                writer.byte(u8::from(*dashed));
            }
            DisplayItem::Rect {
                x,
                y,
                width,
                height,
                color,
            } => {
                writer.byte(2);
                writer.numbers(&[*x, *y, *width, *height]);
                writer.color(*color);
            }
            DisplayItem::Path {
                x,
                y,
                commands,
                fill,
                color,
            } => {
                writer.byte(3);
                writer.numbers(&[*x, *y]);
                writer.color(*color);
                writer.byte(u8::from(*fill));
                writer.integer(commands.len() as u32);
                for command in commands {
                    writer.path(command);
                }
            }
        }
    }
    writer.0
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::hint::black_box;
    use std::time::Instant;

    #[test]
    fn benchmark_transport() {
        let source = [
            r"\mathbf x=\mathbf x_0+\boldsymbol{\delta}",
            r"U(\mathbf x_0+\boldsymbol{\delta})\approx U(\mathbf x_0)+\frac12\boldsymbol{\delta}^{T}H\boldsymbol{\delta}",
            r"Q(\boldsymbol{\delta})=\boldsymbol{\delta}^{T}H\boldsymbol{\delta}",
            r"\mathbf X(t)=\mathbf X_0(t)+\boldsymbol{\xi}(t)",
            r"\dot{\boldsymbol{\xi}}=D\mathbf f(\mathbf X_0(t))\boldsymbol{\xi}",
            r"\dot{\boldsymbol{\xi}}=J\boldsymbol{\xi}",
        ];
        let lists: Vec<_> = source
            .iter()
            .map(|source| {
                layout_list(
                    source,
                    -1,
                    IOSLaTeXColor {
                        r: 0.0,
                        g: 0.0,
                        b: 0.0,
                        a: 1.0,
                    },
                )
                .unwrap()
            })
            .collect();
        let count = 30_000;
        let run = |serialize: &dyn Fn(&DisplayList) -> usize| {
            let mut size = 0;
            let start = Instant::now();
            for i in 0..count {
                size += black_box(serialize(black_box(&lists[i % lists.len()])));
            }
            (
                start.elapsed().as_secs_f64() * 1e6 / count as f64,
                size as f64 / count as f64,
            )
        };
        let json = run(&|list| serde_json::to_vec(list).unwrap().len());
        let binary = run(&|list| encode(list).len());
        println!("Serialize prepared list, µs and bytes per formula: JSON {:.2}, {:.0}; binary {:.2}, {:.0}",
                 json.0, json.1, binary.0, binary.1);
        assert!(binary.1 < json.1);
    }
}
