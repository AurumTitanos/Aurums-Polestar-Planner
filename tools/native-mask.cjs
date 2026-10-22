'use strict';
// Local adaptation by AurumTitanos, 2026. GPL-3.0-only. No artwork included.
const NATIVE_MASK = {
  build: '1.60.1.70425',
  assignmentSha256: '79267e8be8034e47daab14350411b3acc0b1f64e86efc9d821a217497254ca0a',
  continent: 1414, zone: 1438,
  continentRect: [-0.18589326491949285, 0.6340912982438116, 0.06767681692474252, 0.8877435933533173],
  zoneRect: [0.10939219123882231, 0.22284625178787312, 0.10005571560090802, 0.21349797345343963],
};

function tgaAlpha(bytes) {
  if (bytes[1] !== 0 || bytes[2] !== 2 || bytes[16] !== 32) throw new Error('Expected an uncompressed 32-bit source TGA mask');
  const width = bytes.readUInt16LE(12), height = bytes.readUInt16LE(14);
  const offset = 18 + bytes[0], top = (bytes[17] & 32) !== 0, right = (bytes[17] & 16) !== 0;
  if (bytes.length < offset + width * height * 4) throw new Error('Truncated TGA mask');
  const alpha = new Uint8Array(width * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
    const sx = right ? width - 1 - x : x, sy = top ? y : height - 1 - y;
    alpha[y * width + x] = bytes[offset + (sy * width + sx) * 4 + 3];
  }
  return { width, height, alpha };
}

function nativeDetailMask(continent, island) {
  const c = NATIVE_MASK.continentRect, z = NATIVE_MASK.zoneRect;
  const bytes = Buffer.alloc(18 + continent.width * continent.height * 4);
  bytes[2] = 2; bytes.writeUInt16LE(continent.width, 12); bytes.writeUInt16LE(continent.height, 14);
  bytes[16] = 32; bytes[17] = 40; // top-left origin, eight alpha bits
  const sample = (u, v) => {
    if (u < 0 || u > 1 || v < 0 || v > 1) return 0;
    const fx = u * island.width - 0.5, fy = v * island.height - 0.5;
    const x = Math.floor(fx), y = Math.floor(fy), dx = fx - x, dy = fy - y;
    const at = (a, b) => island.alpha[Math.max(0, Math.min(island.height - 1, b)) * island.width + Math.max(0, Math.min(island.width - 1, a))];
    return Math.round((at(x, y) * (1 - dx) + at(x + 1, y) * dx) * (1 - dy) +
      (at(x, y + 1) * (1 - dx) + at(x + 1, y + 1) * dx) * dy);
  };
  for (let y = 0; y < continent.height; y++) for (let x = 0; x < continent.width; x++) {
    const u = c[0] + (x + 0.5) / continent.width * (c[1] - c[0]);
    const v = c[2] + (y + 0.5) / continent.height * (c[3] - c[2]);
    const a = Math.max(continent.alpha[y * continent.width + x], sample((u - z[0]) / (z[1] - z[0]), (v - z[2]) / (z[3] - z[2])));
    const p = 18 + (y * continent.width + x) * 4;
    bytes[p] = bytes[p + 1] = bytes[p + 2] = 255; bytes[p + 3] = a;
  }
  return bytes;
}

module.exports={NATIVE_MASK,tgaAlpha,nativeDetailMask};
