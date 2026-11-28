// WH-411 and WH-424: what a `device_name` in a sign-in body becomes, shared by the three sign-in handler tests. Each pair is
// [sent, expected]; undefined = the RPC gets no p_device_name key, and the sign-in still goes on. The invisible characters are written as
// escapes so that each case can be read.
const emoji = '\u{1F600}';

export const deviceNameCases = [
  // Plain names are kept, other scripts and their combining marks included.
  ['Samsung SM-A156E (7F3A)', 'Samsung SM-A156E (7F3A)'],
  ['મારો ફોન (7F3A)', 'મારો ફોન (7F3A)'],
  ['  Spaced Phone  ', 'Spaced Phone'],
  // Cut to 80 code points, never inside a character, and trimmed again after the cut.
  ['x'.repeat(80), 'x'.repeat(80)],
  ['x'.repeat(81), 'x'.repeat(80)],
  ['y'.repeat(250), 'y'.repeat(80)],
  [`${'a'.repeat(79)}${emoji}b`, `${'a'.repeat(79)}${emoji}`],
  [`${'a'.repeat(80)}${emoji}`, 'a'.repeat(80)],
  [emoji.repeat(81), emoji.repeat(80)],
  [`${'a'.repeat(79)} bcd`, 'a'.repeat(79)],
  // Removed characters do not count towards the 80.
  [`${'​'.repeat(100)}${'n'.repeat(80)}`, 'n'.repeat(80)],
  // Control characters (C0, DEL, C1), line and paragraph separators.
  ['Sam\nsung\r\tPhone', 'SamsungPhone'],
  ['\u0001No\u007Fki\u0085a\u009F', 'Nokia'],
  ['Mo to  G54', 'Moto G54'],
  // Bidi marks, overrides and isolates; zero-width characters; byte order mark; soft hyphen; tag characters.
  ['‮SM-A156E‬', 'SM-A156E'],
  ['‎‏؜Pixel ⁦7a⁩', 'Pixel 7a'],
  ['Pi​x‌e⁠l﻿ ­7', 'Pixel 7'],
  ['A\u{E0041}\u{E007F}B', 'AB'],
  ['\u{1F468}‍\u{1F469}', '\u{1F468}\u{1F469}'],
  // Other spaces become a plain space.
  ['Redmi Note　12 Pro', 'Redmi Note 12 Pro'],
  [' Padded ', 'Padded'],
  // Lone surrogates, which the database would refuse.
  ['A\uD800B\uDC00C', 'ABC'],
  // Nothing is left, or there is no name: no key.
  ['​‍﻿', undefined],
  ['‮', undefined],
  ['\n\t\u0085', undefined],
  [' 　', undefined],
  ['\uD83D', undefined],
  [undefined, undefined], ['', undefined], ['   ', undefined], [7, undefined], [null, undefined], [{ name: 'Samsung' }, undefined], [['Samsung'], undefined],
];
