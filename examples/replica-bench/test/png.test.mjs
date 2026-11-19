import assert from 'node:assert/strict';
import test from 'node:test';
import { inflateSync } from 'node:zlib';
import { crc32, encodePNG, plotResidual } from '../png.mjs';

/** The chunks of a PNG, each checked against its CRC. */
function chunks(png) {
  const found = [];
  for (let at = 8; at < png.length; ) {
    const length = png.readUInt32BE(at);
    const type = png.toString('ascii', at + 4, at + 8);
    const data = png.subarray(at + 8, at + 8 + length);
    assert.equal(png.readUInt32BE(at + 8 + length), crc32(png.subarray(at + 4, at + 8 + length)), `${type} CRC`);
    found.push({ type, data });
    at += 12 + length;
  }
  return found;
}

test('crc32 matches the standard check value', () => {
  assert.equal(crc32(Buffer.from('123456789')), 0xcbf43926);
  assert.equal(crc32(Buffer.from('IEND')), 0xae426082);
});

test('encodePNG writes a valid RGB image', () => {
  const rgb = Buffer.from([255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9]);
  const png = encodePNG(2, 2, rgb);
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const [header, data, end] = chunks(png);
  assert.deepEqual([header.type, data.type, end.type], ['IHDR', 'IDAT', 'IEND']);
  assert.equal(header.data.readUInt32BE(0), 2);
  assert.equal(header.data.readUInt32BE(4), 2);
  assert.deepEqual([header.data[8], header.data[9]], [8, 2]);
  assert.deepEqual([...inflateSync(data.data)], [0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 9, 9, 9]);
});

test('plotResidual draws both series and states the error', () => {
  const target = Array.from({ length: 70000 }, (_, n) => Math.sin(n / 50));
  const candidate = target.map((value) => value + 1e-3);
  const { png, stats } = plotResidual(target, candidate, { width: 300, height: 200 });
  const pixels = inflateSync(chunks(png)[1].data);
  assert.equal(pixels.length, (300 * 3 + 1) * 200);
  assert.ok(Math.abs(stats.maxAbsError - 1e-3) < 1e-9);
  assert.ok(Math.abs(stats.rmsError - 1e-3) < 1e-9);
  // Not a blank image: the series' colours are drawn.
  const coloured = new Set();
  for (let at = 0; at < pixels.length; at += 3) coloured.add(`${pixels[at]},${pixels[at + 1]},${pixels[at + 2]}`);
  assert.ok(coloured.has('34,86,66') && coloured.has('214,110,42') && coloured.has('176,48,72'));
});
