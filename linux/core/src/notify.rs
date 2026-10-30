//! One notification per threshold per usage window, however often it is polled.

use std::collections::{HashMap, VecDeque};

pub const THRESHOLDS: [u8; 4] = [25, 50, 75, 90];
const MAX_KEYS: usize = 256;

#[derive(Debug, Default)]
pub struct ThresholdTracker {
    reached: HashMap<String, u8>,
    order: VecDeque<String>,
}

impl ThresholdTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Returns the threshold to announce, if this reading crossed a new one.
    pub fn observe(&mut self, key: &str, used: f64, resets_at: Option<f64>) -> Option<u8> {
        // A new reset time is a new window, so it starts a fresh record.
        let key = format!("{key}:{}", resets_at.map_or(0.0, |r| r));
        let threshold =
            THRESHOLDS.iter().copied().filter(|t| used.is_finite() && used >= f64::from(*t)).max().unwrap_or(0);
        let previous = self.reached.get(&key).copied();
        if previous.is_none() {
            self.order.push_back(key.clone());
        }
        let recorded = previous.unwrap_or(0);
        self.reached.insert(key, recorded.max(threshold));
        while self.order.len() > MAX_KEYS {
            if let Some(oldest) = self.order.pop_front() {
                self.reached.remove(&oldest);
            }
        }
        (threshold > recorded).then_some(threshold)
    }
}
