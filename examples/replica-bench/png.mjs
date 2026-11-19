// A tiny PNG writer and the residual plot plot_residual returns. MCP tool results carry images as PNG, and the
// bench adds no dependencies, so this draws into an RGB buffer and encodes it with node:zlib: a demanding app's agents read
// plots of target against candidate, and the bench proves an image result reaches every engine.
import { deflateSync } from 'node:zlib';

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

export function crc32(bytes) {
  let c = 0xffffffff;
  for (const byte of bytes) c = crcTable[(c ^ byte) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'ascii');
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

/** Encodes 8-bit RGB pixels (width × height × 3 bytes, rows top to bottom) as a PNG. */
export function encodePNG(width, height, rgb) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8; // bit depth
  header[9] = 2; // colour type: RGB
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) {
    rows[y * (width * 3 + 1)] = 0; // filter: none
    rgb.copy(rows, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', header),
    chunk('IDAT', deflateSync(rows)),
    chunk('IEND', Buffer.alloc(0))
  ]);
}

export const colours = { target: [34, 86, 66], candidate: [214, 110, 42], residual: [176, 48, 72] };

/**
 * Two panels: the target's and the candidate's outputs over the input (top), and their difference on its own scale
 * (bottom). Returns the PNG and the numbers the tool's text states, since an image alone can't be quoted.
 */
export function plotResidual(target, candidate, { width = 720, height = 420 } = {}) {
  const rgb = Buffer.alloc(width * height * 3, 255);
  const set = (x, y, [r, g, b]) => {
    if (x < 0 || y < 0 || x >= width || y >= height) return;
    const at = (y * width + x) * 3;
    rgb[at] = r; rgb[at + 1] = g; rgb[at + 2] = b;
  };
  const line = (x0, y0, x1, y1, colour) => {
    // Bresenham, so the plot needs no anti-aliasing to read.
    let dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, error = dx + dy;
    for (;;) {
      set(x0, y0, colour);
      if (x0 === x1 && y0 === y1) return;
      const twice = 2 * error;
      if (twice >= dy) { error += dy; x0 += sx; }
      if (twice <= dx) { error += dx; y0 += sy; }
    }
  };
  const residual = target.map((value, n) => (candidate[n] ?? 0) - value);
  const panel = (series, top, bottom) => {
    let low = 0, high = 0;
    for (const { values } of series) {
      for (const value of values) if (Number.isFinite(value)) { low = Math.min(low, value); high = Math.max(high, value); }
    }
    if (high - low < 1e-300) { low -= 1; high += 1; }
    const span = high - low;
    const y = (value) => Math.round(bottom - (Number.isFinite(value) ? (value - low) / span : 0) * (bottom - top));
    for (let x = 0; x < width; x++) { set(x, top - 1, [210, 214, 208]); set(x, bottom + 1, [210, 214, 208]); set(x, y(0), [228, 230, 226]); }
    for (const { values, colour } of series) {
      let previous = null;
      for (let x = 0; x < width; x++) {
        // Each column shows its samples' extremes, so a spike between pixels still shows.
        const from = Math.floor(x * values.length / width), to = Math.max(from + 1, Math.floor((x + 1) * values.length / width));
        const slice = values.slice(from, to).filter(Number.isFinite);
        if (!slice.length) continue;
        const a = y(Math.min(...slice)), b = y(Math.max(...slice));
        if (previous !== null) line(x - 1, previous, x, a, colour);
        line(x, a, x, b, colour);
        previous = b;
      }
    }
    return { low, high };
  };
  const split = Math.round(height * 0.62);
  const outputs = panel([{ values: target, colour: colours.target }, { values: candidate, colour: colours.candidate }], 8, split - 10);
  const difference = panel([{ values: residual, colour: colours.residual }], split + 10, height - 9);
  const finite = residual.filter(Number.isFinite);
  const maxAbs = finite.length === residual.length ? finite.reduce((most, v) => Math.max(most, Math.abs(v)), 0) : Infinity;
  const rms = (values) => Math.sqrt(values.reduce((sum, v) => sum + v * v, 0) / Math.max(values.length, 1));
  return {
    png: encodePNG(width, height, rgb),
    stats: { samples: target.length, maxAbsError: maxAbs, rmsError: rms(finite), rmsTarget: rms(target), outputRange: outputs, residualRange: difference }
  };
}
