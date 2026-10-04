// Convert the original AMD GI-1.2 uint32 sample tables into lossless byte storage.
// Source commit 914b91596cd119eda85fbc1d3c7ee6ac391b1452; MIT, THIRD_PARTY_NOTICES.md.
// node tools/import_blue_noise.mjs target/gi12-reference/blue_noise_sampler_samples.h
import fs from 'node:fs';
import crypto from 'node:crypto';
const source = fs.readFileSync(process.argv[2], 'utf8');
const names = ['Sobol256x256', 'RankingTiles', 'ScramblingTiles'];
const sizes = [256 * 256, 128 * 128 * 8, 128 * 128 * 8];
const tables = names.map((name, index) => {
  const match = source.match(new RegExp(`uint32_t\\s+${name}\\[[^\\]]+\\]\\s*=\\s*\\{([^}]+)\\}`));
  if (!match) throw new Error(`Missing ${name}`);
  const values = match[1].split(',').map(value => Number(value.trim()));
  if (values.length !== sizes[index] || values.some(value => !Number.isInteger(value) || value < 0 || value > 255)) {
    throw new Error(`Invalid ${name}: ${values.length} values`);
  }
  return Buffer.from(values);
});
const data = Buffer.concat(tables);
fs.mkdirSync('src/data', { recursive: true });
fs.writeFileSync('src/data/gi12-blue-noise.bin', data);
console.log(JSON.stringify({ bytes: data.length, sha256: crypto.createHash('sha256').update(data).digest('hex') }));
