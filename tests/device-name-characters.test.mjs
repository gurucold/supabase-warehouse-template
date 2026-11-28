import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { clientDeviceName } from '../functions/_shared/client-info.ts';

// WH-424: a phone name is cleaned twice, by the edge functions (clientDeviceName) and by the database
// (warehouse_security.clean_device_name, topic "held item device name"). Both must remove and replace the same characters, or a name sent
// straight to an RPC could keep what a sign-in would drop. The SQL half runs only in migrations.sh; here its two character classes are read
// from the migration and compared with the real edge function on every code point.
const migrations = new URL('../migrations/', import.meta.url);
const files = readdirSync(migrations).filter(name => name.endsWith('_held_item_device_name.sql'));
const sql = readFileSync(new URL(files[0], migrations), 'utf8');
const body = sql.match(/CREATE FUNCTION warehouse_security\.clean_device_name\(p_name text\)[^]*?AS \$\$([^]*?)\$\$;/)[1];
// A PostgreSQL bracket expression of \UXXXXXXXX code points and ranges as a JavaScript expression.
const asRegExp = text => new RegExp(text.replace(/\\U([0-9A-F]{8})/g, '\\u{$1}'), 'u');
const classes = [...body.matchAll(/'(\[(?:\\U[0-9A-F]{8}|-)+\])'/g)].map(match => match[1]);

test('WH-424: the edge function removes and replaces the same characters as clean_device_name, over every code point', () => {
  assert.equal(files.length, 1);
  assert.equal(classes.length, 2, 'the removed class and the space class were read from the migration');
  const [removed, spaces] = classes.map(asRegExp);
  const different = [];
  // U+0000 and the surrogates cannot reach the database; the edge cases are in tests/device-name-cases.mjs.
  for (let point = 1; point <= 0x10ffff; point += 1) {
    if (point >= 0xd800 && point <= 0xdfff) continue;
    const character = String.fromCodePoint(point);
    const expected = removed.test(character) ? 'ab' : spaces.test(character) ? 'a b' : `a${character}b`;
    if (clientDeviceName({ device_name: `a${character}b` }) !== expected) different.push(`U+${point.toString(16).toUpperCase().padStart(4, '0')}`);
  }
  assert.deepEqual(different, []);
});

test('WH-424: both halves remove the characters the card names', () => {
  const [removed, spaces] = classes.map(asRegExp);
  for (const point of [0x0a, 0x0d, 0x7f, 0x85, 0xad, 0x200b, 0x200d, 0x200e, 0x2028, 0x202e, 0x2066, 0xfeff]) {
    const character = String.fromCodePoint(point);
    assert.ok(removed.test(character), `the database removes U+${point.toString(16)}`);
    assert.equal(clientDeviceName({ device_name: `a${character}b` }), 'ab', `the edge removes U+${point.toString(16)}`);
  }
  assert.ok(spaces.test(' ') && !removed.test(' ') && !spaces.test('a'));
});

test('WH-424: the database cleans the name in all three places that store one', () => {
  const session = readFileSync(new URL(readdirSync(migrations).find(name => name.endsWith('_session_device_name.sql')), migrations), 'utf8');
  assert.match(sql, /v_device := warehouse_security\.clean_device_name\(p_device_name\);/, 'hold_items');
  assert.match(session, /v_device text := warehouse_security\.clean_device_name\(p_device_name\);/, 'issue_session');
  assert.match(session, /v_name text := warehouse_security\.clean_device_name\(p_device_name\);/, 'set_session_device_name');
});
