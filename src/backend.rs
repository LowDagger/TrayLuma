//! Display discovery and brightness control.
//!
//! Built-in laptop panels are driven through WMI (`WmiMonitorBrightnessMethods`),
//! external monitors through DDC/CI (VCP code 0x10). Displays that support
//! neither are reported as `soft` and dimmed by an overlay on the UI thread.
//! WMI and DDC/CI calls block for tens of
//! milliseconds per call, so everything runs on one worker thread that sleeps
//! in `recv()` (zero CPU) until the UI sends it a command.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::{mem::size_of, thread};

use windows::core::*;
use windows::Win32::Devices::Display::*;
use windows::Win32::Foundation::*;
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Registry::*;
use windows::Win32::System::Threading::{GetCurrentProcess, SetProcessWorkingSetSize};

use windows::Win32::System::Wmi::*;
use windows::Win32::UI::WindowsAndMessaging::{PostMessageW, EDD_GET_DEVICE_INTERFACE_NAME};

const VCP_BRIGHTNESS: u8 = 0x10;

pub enum Cmd {
    /// Re-enumerate displays and post their current brightness to the UI.
    Refresh,
    /// Set display `.0` to `.1` percent.
    Set(usize, u32),
    /// Change every display by this many percent (keyboard shortcuts),
    /// enumerating first if needed, then post the new levels to the UI.
    Nudge(i32),
    /// Drop every handle and COM object and trim the working set.
    Release,
}

pub struct Row {
    pub name: Vec<u16>,
    pub value: u32,
    /// GDI device name (`\\.\DISPLAY2`) of a display without hardware
    /// brightness control; the UI dims it with an overlay instead.
    pub soft: Option<String>,
}

/// Starts the worker. Results of `Refresh` and `Nudge` are posted to `hwnd`
/// as `msg` with a `Box<Vec<Row>>` in `lParam` and the applied nudge (0 for a
/// refresh) in `wParam`; software-dimmed rows still need that nudge applied.
pub fn spawn(hwnd: HWND, msg: u32) -> Sender<Cmd> {
    let (tx, rx) = channel();
    let hwnd = hwnd.0 as isize; // HWND is not Send
    thread::Builder::new()
        .stack_size(256 * 1024)
        .spawn(move || run(rx, HWND(hwnd as _), msg))
        .expect("worker thread");
    tx
}

fn run(rx: Receiver<Cmd>, hwnd: HWND, msg: u32) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        let _ = CoInitializeSecurity(
            None,
            -1,
            None,
            None,
            RPC_C_AUTHN_LEVEL_DEFAULT,
            RPC_C_IMP_LEVEL_IMPERSONATE,
            None,
            EOAC_NONE,
            None,
        );
    }
    let mut b = Backend::default();
    // Latest requested value per display; slider drags produce far more
    // requests than DDC/CI can apply, so only the newest one is sent.
    // Held-down shortcuts are merged into one nudge the same way.
    let mut pending: Vec<(usize, u32)> = Vec::new();
    let mut nudge = 0i32;
    let post = |rows: Vec<Row>, delta: i32| unsafe {
        let rows = Box::into_raw(Box::new(rows));
        if PostMessageW(hwnd, msg, WPARAM(delta as isize as usize), LPARAM(rows as isize)).is_err() {
            drop(Box::from_raw(rows));
        }
    };
    let settle = |b: &mut Backend, pending: &mut Vec<(usize, u32)>, nudge: &mut i32| {
        b.flush(pending);
        if *nudge != 0 {
            post(b.nudge(*nudge), *nudge);
            *nudge = 0;
        }
    };
    while let Ok(cmd) = rx.recv() {
        let mut next = Some(cmd);
        while let Some(cmd) = next.take() {
            match cmd {
                Cmd::Set(i, v) => match pending.iter_mut().find(|p| p.0 == i) {
                    Some(p) => p.1 = v,
                    None => pending.push((i, v)),
                },
                Cmd::Nudge(d) => nudge += d,
                Cmd::Refresh => {
                    settle(&mut b, &mut pending, &mut nudge);
                    b.refresh();
                    post(b.rows(), 0);
                }
                Cmd::Release => {
                    settle(&mut b, &mut pending, &mut nudge);
                    b.release();
                    unsafe {
                        CoFreeUnusedLibraries();
                        let _ = SetProcessWorkingSetSize(GetCurrentProcess(), usize::MAX, usize::MAX);
                    }
                }
            }
            next = rx.try_recv().ok();
        }
        settle(&mut b, &mut pending, &mut nudge);
    }
}

enum Ctl {
    Wmi,
    /// `key` identifies the physical monitor in `Backend::known`.
    Ddc { h: HANDLE, max: u32, key: String },
    Soft(String),
}

struct Mon {
    ctl: Ctl,
    name: String,
    value: u32,
}

/// A monitor that has answered DDC/CI before, with its last known levels.
/// Kept across `release()` so that one missed reply (monitors often ignore a
/// read right after a write) can't turn it into a software-dimmed display.
struct Known {
    key: String,
    max: u32,
    value: u32,
}

#[derive(Default)]
struct Backend {
    mons: Vec<Mon>,
    wmi: Option<Wmi>,
    known: Vec<Known>,
}

impl Backend {
    fn release(&mut self) {
        for m in self.mons.drain(..) {
            if let Ctl::Ddc { h, .. } = m.ctl {
                unsafe {
                    let _ = DestroyPhysicalMonitor(h);
                }
            }
        }
        self.wmi = None;
    }

    fn set(&mut self, i: usize, v: u32) {
        let Some(m) = self.mons.get_mut(i) else { return };
        m.value = v;
        match &m.ctl {
            Ctl::Wmi => {
                if let Some(w) = &self.wmi {
                    w.set(v);
                }
            }
            Ctl::Ddc { h, max, key } => {
                let raw = (v * max + 50) / 100;
                if retry(|| unsafe { SetVCPFeature(*h, VCP_BRIGHTNESS, raw) != 0 }) {
                    if let Some(k) = self.known.iter_mut().find(|k| &k.key == key) {
                        k.value = v;
                    }
                }
            }
            Ctl::Soft(_) => {} // handled by the UI thread
        }
    }

    fn flush(&mut self, pending: &mut Vec<(usize, u32)>) {
        for (i, v) in pending.drain(..) {
            self.set(i, v);
        }
    }

    /// Moves every hardware-controlled display by `delta` percent.
    fn nudge(&mut self, delta: i32) -> Vec<Row> {
        if self.mons.is_empty() {
            self.refresh();
        }
        for i in 0..self.mons.len() {
            let m = &self.mons[i];
            if !matches!(m.ctl, Ctl::Soft(_)) {
                let v = (m.value as i32 + delta).clamp(0, 100) as u32;
                if v != m.value {
                    self.set(i, v);
                }
            }
        }
        self.rows()
    }

    fn rows(&self) -> Vec<Row> {
        if demo() {
            return demo_rows();
        }
        self.mons
            .iter()
            .map(|m| {
                let soft = match &m.ctl {
                    Ctl::Soft(dev) => Some(dev.clone()),
                    _ => None,
                };
                let name = if soft.is_some() { format!("{} · software dimming", m.name) } else { m.name.clone() };
                Row { name: name.encode_utf16().collect(), value: m.value, soft }
            })
            .collect()
    }

    fn refresh(&mut self) {
        self.release();
        if demo() {
            return;
        }
        let targets = display_targets();
        let mut hmons = hmonitors();
        hmons.sort_by_key(|m| m.2.left);
        // BRIGHTNESS_TRAY_SOFTWARE=1: skip DDC/CI and WMI, dim everything with overlays.
        let force_soft = std::env::var_os("BRIGHTNESS_TRAY_SOFTWARE").is_some();

        let mut internal = Vec::new();
        let mut external = Vec::new();
        for (hm, dev, _) in hmons {
            let t = targets.iter().find(|t| t.gdi == dev);
            if t.is_some_and(|t| t.internal) {
                internal.push(dev);
                continue;
            }
            // Cloned targets share a GDI source; their order does not identify
            // the physical DDC handles, so don't reuse the first target's name.
            let name = t
                .filter(|_| targets.iter().filter(|t| t.gdi == dev).count() == 1)
                .and_then(|t| monitor_name(&t.name))
                .or_else(|| gdi_monitor_name(&dev));
            let fallback = format!("Display {}", external.len() + 1);
            if force_soft || !ddc_monitors(hm, &dev, name.as_deref(), &fallback, &mut external, &mut self.known) {
                external.push(Mon { ctl: Ctl::Soft(dev), name: name.unwrap_or(fallback), value: 100 });
            }
        }
        if !internal.is_empty() {
            let wmi = if force_soft { None } else { Wmi::connect().and_then(|w| w.get().map(|v| (w, v))) };
            match wmi {
                Some((w, value)) => {
                    self.mons.push(Mon { ctl: Ctl::Wmi, name: "Built-in display".into(), value });
                    self.wmi = Some(w);
                }
                None => {
                    for dev in internal {
                        self.mons.push(Mon { ctl: Ctl::Soft(dev), name: "Built-in display".into(), value: 100 });
                    }
                }
            }
        }
        self.mons.extend(external);
    }
}

fn demo() -> bool {
    std::env::var_os("BRIGHTNESS_TRAY_DEMO").is_some()
}

/// Fake displays for screenshots (`BRIGHTNESS_TRAY_DEMO=1`); nothing is changed.
fn demo_rows() -> Vec<Row> {
    [("Built-in display", 70), ("DELL U2723QE", 45), ("LG TV · software dimming", 85)]
        .into_iter()
        .map(|(n, v)| Row { name: n.encode_utf16().collect(), value: v, soft: None })
        .collect()
}

/// Adds every DDC/CI-capable physical monitor behind `hm`; false if none.
/// A monitor that answered before but misses this read keeps DDC/CI control
/// with its last known levels instead of falling back to software dimming.
fn ddc_monitors(hm: HMONITOR, dev: &str, name: Option<&str>, fallback: &str, out: &mut Vec<Mon>, known: &mut Vec<Known>) -> bool {
    let before = out.len();
    unsafe {
        let mut n = 0u32;
        if GetNumberOfPhysicalMonitorsFromHMONITOR(hm, &mut n).is_err() || n == 0 {
            return false;
        }
        let mut pms = vec![PHYSICAL_MONITOR::default(); n as usize];
        if GetPhysicalMonitorsFromHMONITOR(hm, &mut pms).is_err() {
            return false;
        }
        for (k, pm) in pms.iter().enumerate() {
            let h = pm.hPhysicalMonitor;
            let key = format!("{dev}#{k}");
            let (mut cur, mut max) = (0u32, 0u32);
            let read = retry(|| GetVCPFeatureAndVCPFeatureReply(h, VCP_BRIGHTNESS, None, &mut cur, Some(&mut max)) != 0);
            let levels = if read && max > 0 {
                let value = ((cur * 100 + max / 2) / max).min(100);
                match known.iter_mut().find(|c| c.key == key) {
                    Some(c) => (c.max, c.value) = (max, value),
                    None => known.push(Known { key: key.clone(), max, value }),
                }
                Some((max, value))
            } else {
                known.iter().find(|c| c.key == key).map(|c| (c.max, c.value))
            };
            let Some((max, value)) = levels else {
                let _ = DestroyPhysicalMonitor(h);
                continue;
            };
            // PHYSICAL_MONITOR is packed; copy before borrowing the UTF-16 array.
            let description = pm.szPhysicalMonitorDescription;
            let physical = monitor_name(&wide_str(&description));
            let name = if n > 1 { physical.as_deref().or(name) } else { name.or(physical.as_deref()) };
            let name = name.unwrap_or(fallback);
            let name = if n > 1 { format!("{name} ({})", k + 1) } else { name.to_string() };
            out.push(Mon { ctl: Ctl::Ddc { h, max, key }, name, value });
        }
    }
    out.len() > before
}

/// DDC/CI calls fail transiently, especially right after a write; try a few
/// times with a short pause (only costs anything when a call fails).
fn retry(mut f: impl FnMut() -> bool) -> bool {
    for attempt in 0..4 {
        if attempt > 0 {
            thread::sleep(std::time::Duration::from_millis(40));
        }
        if f() {
            return true;
        }
    }
    false
}

fn wide_str(buf: &[u16]) -> String {
    let n = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..n])
}

/// Generic driver labels are not model names; keep searching when we see one.
fn monitor_name(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty()
        || ["Generic PnP Monitor", "Generic Non-PnP Monitor", "Generic Monitor", "Default Monitor", "Monitor"]
            .iter()
            .any(|generic| name.eq_ignore_ascii_case(generic))
        || name.chars().any(char::is_control)
    {
        None
    } else {
        Some(name.to_string())
    }
}

/// Convert a CCD monitor interface or GDI instance ID to its read-only EDID key.
fn edid_registry_path(device: &str) -> Option<String> {
    let instance = if let Some(interface) = device.strip_prefix(r"\\?\") {
        let mut parts = interface.split('#');
        let (kind, model, instance, guid) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        if parts.next().is_some() || !guid.starts_with('{') || !guid.ends_with('}') {
            return None;
        }
        format!(r"{kind}\{model}\{instance}")
    } else {
        device.to_string()
    };
    let parts: Vec<_> = instance.split('\\').collect();
    if parts.len() != 3 || !parts[0].eq_ignore_ascii_case("DISPLAY")
        || parts.iter().any(|p| p.is_empty() || !p.bytes().all(|b| b.is_ascii_alphanumeric() || b"&_-".contains(&b)))
    {
        return None;
    }
    Some(format!(r"SYSTEM\CurrentControlSet\Enum\{instance}\Device Parameters"))
}

/// EDID base block's 0xFC descriptor contains the manufacturer's model name.
fn edid_model(edid: &[u8]) -> Option<String> {
    let base = edid.get(..128)?;
    if base[..8] != [0, 255, 255, 255, 255, 255, 255, 0]
        || base.iter().fold(0u8, |sum, &b| sum.wrapping_add(b)) != 0
    {
        return None;
    }
    for offset in [54, 72, 90, 108] {
        let descriptor = &base[offset..offset + 18];
        if descriptor[..5] != [0, 0, 0, 0xfc, 0] {
            continue;
        }
        let text = &descriptor[5..];
        let end = text.iter().position(|&b| b == 0 || b == b'\n').unwrap_or(text.len());
        let text = &text[..end];
        if text.iter().all(|b| (0x20..=0x7e).contains(b)) {
            if let Some(name) = monitor_name(std::str::from_utf8(text).ok()?) {
                return Some(name);
            }
        }
    }
    None
}

fn edid_name(device: &str) -> Option<String> {
    let path: Vec<u16> = edid_registry_path(device)?.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut key = HKEY::default();
        if RegOpenKeyExW(HKEY_LOCAL_MACHINE, PCWSTR(path.as_ptr()), 0, KEY_QUERY_VALUE, &mut key).is_err() {
            return None;
        }
        let name = (|| {
            let mut kind = REG_VALUE_TYPE::default();
            let mut len = 0;
            RegQueryValueExW(key, w!("EDID"), None, Some(&mut kind), None, Some(&mut len)).ok().ok()?;
            // At most 256 EDID blocks, including extension blocks. Query the
            // complete value: a 128-byte buffer fails for EDIDs with extensions.
            if kind != REG_BINARY || !(128..=32768).contains(&len) {
                return None;
            }
            let mut data = vec![0u8; len as usize];
            RegQueryValueExW(key, w!("EDID"), None, Some(&mut kind), Some(data.as_mut_ptr()), Some(&mut len)).ok().ok()?;
            if kind != REG_BINARY {
                return None;
            }
            edid_model(data.get(..len as usize)?)
        })();
        let _ = RegCloseKey(key);
        name
    }
}

/// GDI can still identify a monitor when display configuration is unavailable.
fn gdi_monitor_name(dev: &str) -> Option<String> {
    let dev: Vec<u16> = dev.encode_utf16().chain(Some(0)).collect();
    let mut name = None;
    let mut active = 0;
    for index in 0..64 {
        let mut monitor = DISPLAY_DEVICEW { cb: size_of::<DISPLAY_DEVICEW>() as u32, ..Default::default() };
        if !unsafe { EnumDisplayDevicesW(PCWSTR(dev.as_ptr()), index, &mut monitor, EDD_GET_DEVICE_INTERFACE_NAME) }.as_bool() {
            break;
        }
        if monitor.StateFlags & DISPLAY_DEVICE_ACTIVE != 0 {
            active += 1;
            if active > 1 {
                return None; // No reliable association for a cloned GDI source.
            }
            name = edid_name(&wide_str(&monitor.DeviceID)).or_else(|| monitor_name(&wide_str(&monitor.DeviceString)));
        }
    }
    name
}

/// Active monitors as (handle, GDI device name, bounds).
pub fn hmonitors() -> Vec<(HMONITOR, String, RECT)> {
    unsafe extern "system" fn cb(hm: HMONITOR, _: HDC, _: *mut RECT, lp: LPARAM) -> BOOL {
        let v = &mut *(lp.0 as *mut Vec<(HMONITOR, String, RECT)>);
        let mut mi = MONITORINFOEXW::default();
        mi.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
        if GetMonitorInfoW(hm, &mut mi as *mut _ as *mut MONITORINFO).as_bool() {
            v.push((hm, wide_str(&mi.szDevice), mi.monitorInfo.rcMonitor));
        }
        TRUE
    }
    let mut v = Vec::new();
    unsafe {
        let _ = EnumDisplayMonitors(None, None, Some(cb), LPARAM(&mut v as *mut _ as isize));
    }
    v
}

struct Target {
    gdi: String,
    name: String,
    internal: bool,
}

/// Maps GDI device names (\\.\DISPLAY1) to friendly monitor names and
/// whether the panel is built in.
fn display_targets() -> Vec<Target> {
    let mut out = Vec::new();
    unsafe {
        // Hot-plugging can invalidate the sizes between these two API calls.
        // Retry with fresh buffers, but never spin indefinitely on a bad driver.
        for _ in 0..3 {
            let (mut np, mut nm) = (0u32, 0u32);
            if GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, &mut np, &mut nm).is_err() {
                return out;
            }
            let mut paths = vec![DISPLAYCONFIG_PATH_INFO::default(); np as usize];
            let mut modes = vec![DISPLAYCONFIG_MODE_INFO::default(); nm as usize];
            let status = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, &mut np, paths.as_mut_ptr(), &mut nm, modes.as_mut_ptr(), None);
            if status == ERROR_INSUFFICIENT_BUFFER {
                continue;
            }
            if status.is_err() {
                return out;
            }
            for p in paths.iter().take(np as usize) {
                let mut src = DISPLAYCONFIG_SOURCE_DEVICE_NAME::default();
                src.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME;
                src.header.size = size_of::<DISPLAYCONFIG_SOURCE_DEVICE_NAME>() as u32;
                src.header.adapterId = p.sourceInfo.adapterId;
                src.header.id = p.sourceInfo.id;
                if DisplayConfigGetDeviceInfo(&mut src.header) != 0 {
                    continue;
                }
                let mut tgt = DISPLAYCONFIG_TARGET_DEVICE_NAME::default();
                tgt.header.r#type = DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME;
                tgt.header.size = size_of::<DISPLAYCONFIG_TARGET_DEVICE_NAME>() as u32;
                tgt.header.adapterId = p.targetInfo.adapterId;
                tgt.header.id = p.targetInfo.id;
                let name = if DisplayConfigGetDeviceInfo(&mut tgt.header) == 0 {
                    monitor_name(&wide_str(&tgt.monitorFriendlyDeviceName))
                        .or_else(|| edid_name(&wide_str(&tgt.monitorDevicePath)))
                        .unwrap_or_default()
                } else {
                    String::new()
                };
                // Connection technology is available even when the name query fails.
                let tech = p.targetInfo.outputTechnology;
                let internal = tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_INTERNAL
                    || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_DISPLAYPORT_EMBEDDED
                    || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_UDI_EMBEDDED
                    || tech == DISPLAYCONFIG_OUTPUT_TECHNOLOGY_LVDS;
                out.push(Target { gdi: wide_str(&src.viewGdiDeviceName), name, internal });
            }
            break;
        }
    }
    out
}

/// Connection to `ROOT\WMI` for the built-in panel.
struct Wmi {
    svc: IWbemServices,
    path: BSTR,
    params: IWbemClassObject,
}

impl Wmi {
    fn connect() -> Option<Self> {
        unsafe {
            let loc: IWbemLocator = CoCreateInstance(&WbemLocator, None, CLSCTX_INPROC_SERVER).ok()?;
            let empty = BSTR::new();
            let svc = loc
                .ConnectServer(&BSTR::from("ROOT\\WMI"), &empty, &empty, &empty, 0, &empty, None)
                .ok()?;
            CoSetProxyBlanket(
                &svc,
                10, // RPC_C_AUTHN_WINNT
                0,  // RPC_C_AUTHZ_NONE
                PCWSTR::null(),
                RPC_C_AUTHN_LEVEL_CALL,
                RPC_C_IMP_LEVEL_IMPERSONATE,
                None,
                EOAC_NONE,
            )
            .ok()?;

            let inst = first(&svc, "SELECT __PATH FROM WmiMonitorBrightnessMethods WHERE Active=TRUE")?;
            let mut v = VARIANT::default();
            inst.Get(w!("__PATH"), 0, &mut v, None, None).ok()?;
            let path = BSTR::try_from(&v).ok()?;

            let mut class = None;
            svc.GetObject(
                &BSTR::from("WmiMonitorBrightnessMethods"),
                WBEM_GENERIC_FLAG_TYPE(0),
                None,
                Some(&mut class),
                None,
            )
            .ok()?;
            let mut sig = None;
            class?.GetMethod(w!("WmiSetBrightness"), 0, &mut sig, std::ptr::null_mut()).ok()?;
            let params = sig?.SpawnInstance(0).ok()?;
            params.Put(w!("Timeout"), 0, &VARIANT::from(1i32), 0).ok()?;
            Some(Self { svc, path, params })
        }
    }

    fn get(&self) -> Option<u32> {
        unsafe {
            let o = first(&self.svc, "SELECT CurrentBrightness FROM WmiMonitorBrightness WHERE Active=TRUE")?;
            let mut v = VARIANT::default();
            o.Get(w!("CurrentBrightness"), 0, &mut v, None, None).ok()?;
            u32::try_from(&v).ok().map(|b| b.min(100))
        }
    }

    fn set(&self, pct: u32) {
        unsafe {
            if self.params.Put(w!("Brightness"), 0, &VARIANT::from(pct.min(100) as u8), 0).is_ok() {
                let _ = self.svc.ExecMethod(
                    &self.path,
                    &BSTR::from("WmiSetBrightness"),
                    WBEM_GENERIC_FLAG_TYPE(0),
                    None,
                    &self.params,
                    None,
                    None,
                );
            }
        }
    }
}

fn first(svc: &IWbemServices, wql: &str) -> Option<IWbemClassObject> {
    unsafe {
        let e = svc
            .ExecQuery(
                &BSTR::from("WQL"),
                &BSTR::from(wql),
                WBEM_FLAG_FORWARD_ONLY | WBEM_FLAG_RETURN_IMMEDIATELY,
                None,
            )
            .ok()?;
        let mut objs = [None];
        let mut n = 0u32;
        e.Next(WBEM_INFINITE, &mut objs, &mut n).ok().ok()?;
        objs[0].take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn checksum(edid: &mut [u8; 128]) {
        edid[127] = 0u8.wrapping_sub(edid[..127].iter().fold(0u8, |sum, &b| sum.wrapping_add(b)));
    }

    fn model_block(slot: usize, text: &[u8]) -> [u8; 128] {
        let mut edid = [0u8; 128];
        edid[..8].copy_from_slice(&[0, 255, 255, 255, 255, 255, 255, 0]);
        let offset = 54 + slot * 18;
        edid[offset + 3] = 0xfc;
        edid[offset + 5..offset + 5 + text.len()].copy_from_slice(text);
        checksum(&mut edid);
        edid
    }

    #[test]
    fn edid_reads_all_descriptor_slots_and_terminators() {
        for slot in 0..4 {
            for text in [b"DELL U2723QE\n ".as_slice(), b"DELL U2723QE\0 ", b"DELL U2723QE  "] {
                assert_eq!(edid_model(&model_block(slot, text)).as_deref(), Some("DELL U2723QE"));
            }
        }
        let mut extended = model_block(0, b"LG TV\n").to_vec();
        extended.extend_from_slice(&[0; 128]);
        assert_eq!(edid_model(&extended).as_deref(), Some("LG TV"));
    }

    #[test]
    fn edid_rejects_bad_blocks_and_names() {
        let valid = model_block(0, b"DELL\n");
        for len in 0..128 {
            assert!(edid_model(&valid[..len]).is_none());
        }
        let mut bad = valid;
        bad[10] ^= 1;
        assert!(edid_model(&bad).is_none());
        bad = valid;
        bad[0] = 1;
        checksum(&mut bad);
        assert!(edid_model(&bad).is_none());
        for text in [b" \n".as_slice(), b"bad\x80name", b"bad\tname"] {
            assert!(edid_model(&model_block(0, text)).is_none());
        }
        bad = valid;
        bad[57] = 0xff; // Serial-number descriptors are not model names.
        checksum(&mut bad);
        assert!(edid_model(&bad).is_none());
    }

    #[test]
    fn generic_labels_are_not_models() {
        for name in ["", "  ", "Generic PnP Monitor", "generic non-pnp monitor", "Monitor", "bad\0name"] {
            assert!(monitor_name(name).is_none());
        }
        assert_eq!(monitor_name("  DELL U2723QE  ").as_deref(), Some("DELL U2723QE"));
    }

    #[test]
    fn registry_paths_are_scoped_to_monitor_instances() {
        let expected = Some(r"SYSTEM\CurrentControlSet\Enum\DISPLAY\DEL1234\5&abc&0&UID1\Device Parameters".to_string());
        assert_eq!(edid_registry_path(r"\\?\DISPLAY#DEL1234#5&abc&0&UID1#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}"), expected);
        assert_eq!(edid_registry_path(r"DISPLAY\DEL1234\5&abc&0&UID1"), expected);
        for path in ["", r"PCI\DEL1234\instance", r"DISPLAY\..\instance", r"DISPLAY\model\instance\extra",
            r"\\?\DISPLAY#model#instance", r"\\?\DISPLAY#model##{guid}", r"\\?\DISPLAY#model#instance#{guid}#extra"] {
            assert!(edid_registry_path(path).is_none(), "accepted {path}");
        }
    }
}
