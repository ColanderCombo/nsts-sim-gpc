/**
 * memformat.ts — Shared utilities for formatting memory values as typed strings.
 *
 * Used by gpc-watch (symbol watch panel) and gpc-memory (selection tooltip).
 */

import {FloatIBM} from 'gpc/floatIBM';
import {EBCDIC_TO_ASCII} from 'gpc/ebcdic';

/**
 * Read `count` halfwords from memory starting at `addr`.
 */
export function readHalfwords(mainStorage: any, addr: number, count: number): number[] {
  const hws: number[] = [];
  for (let i = 0; i < count; i++) {
    hws.push(mainStorage.get16(addr + i, false));
  }
  return hws;
}

/**
 * Format a typed memory value as a display string.
 *
 * @param type    - 'hw', 'fw', 'int16', 'int32', 'float', 'dfloat', 'ebcdic', 'ascii'
 * @param hws     - array of halfwords
 * @param size    - number of halfwords (for ebcdic/ascii)
 */
export function formatTypedValue(type: string, hws: number[], size: number = hws.length): string {
  switch (type) {
    case 'hw': {
      return hws[0].toString(16).padStart(4, '0').toUpperCase();
    }
    case 'fw': {
      const h1 = hws[0].toString(16).padStart(4, '0').toUpperCase();
      const h2 = (hws[1] || 0).toString(16).padStart(4, '0').toUpperCase();
      return `${h1} ${h2}`;
    }
    case 'int16': {
      const val = (hws[0] & 0x8000) ? hws[0] - 0x10000 : hws[0];
      return val.toString();
    }
    case 'int32': {
      const val = (hws[0] << 16) | (hws[1] || 0);
      return val.toString();
    }
    case 'float': {
      const val32 = ((hws[0] << 16) | (hws[1] || 0)) >>> 0;
      const f = FloatIBM.From32(val32);
      return f.toFloat().toPrecision(7);
    }
    case 'dfloat': {
      const hi32 = ((hws[0] << 16) | (hws[1] || 0)) >>> 0;
      const lo32 = (((hws[2] || 0) << 16) | (hws[3] || 0)) >>> 0;
      const f = FloatIBM.From64(hi32, lo32);
      return f.toFloat().toPrecision(16);
    }
    case 'ebcdic': {
      const chars: string[] = [];
      for (let j = 0; j < size; j++) {
        const hw = hws[j] || 0;
        chars.push((EBCDIC_TO_ASCII as any)[(hw >>> 8) & 0xFF] || '.');
        chars.push((EBCDIC_TO_ASCII as any)[hw & 0xFF] || '.');
      }
      return `"${chars.join('')}"`;
    }
    case 'ascii': {
      const chars: string[] = [];
      for (let j = 0; j < size; j++) {
        const hw = hws[j] || 0;
        const hi = (hw >>> 8) & 0xFF;
        const lo = hw & 0xFF;
        chars.push(hi >= 0x20 && hi < 0x7F ? String.fromCharCode(hi) : '.');
        chars.push(lo >= 0x20 && lo < 0x7F ? String.fromCharCode(lo) : '.');
      }
      return `"${chars.join('')}"`;
    }
    default:
      return hws[0].toString(16).padStart(4, '0').toUpperCase();
  }
}

/**
 * Generate interpretation lines for a range of halfwords (for tooltips).
 * Returns an array of label: value strings.
 */
export function interpretHalfwords(hws: number[], startAddr: number): string[] {
  const lines: string[] = [];
  const count = hws.length;
  const endAddr = startAddr + count - 1;

  // Address
  if (count === 1) {
    lines.push(`@${startAddr.toString(16).padStart(5, '0')}`);
  } else {
    lines.push(`@${startAddr.toString(16).padStart(5, '0')}-${endAddr.toString(16).padStart(5, '0')}`);
  }

  // Hex
  lines.push(`hex: ${hws.map(h => h.toString(16).padStart(4, '0')).join(' ')}`);

  // 16-bit integer
  if (count === 1) {
    const unsigned = hws[0];
    const signed = (unsigned & 0x8000) ? unsigned - 0x10000 : unsigned;
    lines.push(`i= ${signed}  (u= ${unsigned})`);
  }

  // 32-bit integer
  if (count === 2) {
    const val32 = ((hws[0] << 16) | hws[1]) >>> 0;
    const signed32 = val32 | 0;
    lines.push(`i32= ${signed32}  (u32= ${val32})`);
  }

  // IBM float short
  if (count === 2) {
    const val32 = ((hws[0] << 16) | hws[1]) >>> 0;
    const f = FloatIBM.From32(val32);
    lines.push(`f= ${f.toFloat().toPrecision(7)}`);
  }

  // IBM float long
  if (count === 4) {
    const hi32 = ((hws[0] << 16) | hws[1]) >>> 0;
    const lo32 = ((hws[2] << 16) | hws[3]) >>> 0;
    const f = FloatIBM.From64(hi32, lo32);
    lines.push(`d= ${f.toFloat().toPrecision(16)}`);
  }

  // ASCII string
  const bytes: number[] = [];
  for (const hw of hws) {
    bytes.push((hw >> 8) & 0xFF);
    bytes.push(hw & 0xFF);
  }
  const chars = bytes.map(b => (b >= 0x20 && b < 0x7F) ? String.fromCharCode(b) : '.');
  lines.push(`s= "${chars.join('')}"`);

  return lines;
}
