/** Parses a client-supplied decimal id into a BigInt, returning undefined rather
 * than throwing when it isn't one.
 *
 * `BigInt("abc")` throws a SyntaxError. Several routes fed a raw path param or
 * query string straight into it, so `/notifications/abc/read` (and friends)
 * surfaced as a 500 INTERNAL — an unhandled crash — where the honest answer is
 * "that isn't a valid id". Callers use the undefined to decide between 400 and
 * simply ignoring the value. */
export function parseBigIntId(value: string | undefined | null): bigint | undefined {
  if (value === undefined || value === null) return undefined;
  // Deliberately strict: digits only, no sign, no whitespace, no 0x/0b, no
  // exponent. BigInt() itself accepts "0x10", " 12 " and "-1", none of which
  // are ids this system ever issues.
  if (!/^\d{1,19}$/.test(value)) return undefined;
  try {
    return BigInt(value);
  } catch {
    return undefined;
  }
}
