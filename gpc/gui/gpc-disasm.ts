import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'cde/toolbar';

// Ensure String.rpad prototype is available (Instruction.toStr depends on it)
require('com/util');

import Instruction from 'gpc/cpu_instr';

function rpad(s: string, ch: string, len: number): string {
  return s.length < len ? s + ch.repeat(len - s.length) : s;
}

interface DisasmLine {
  isHeader: boolean;
  addr?: number;
  isNIA?: boolean;
  addrCol?: string;
  csectName?: string;
  csectOffset?: string;
  sectionColor?: string | null;
  hw1Col?: string;
  hw2Col?: string;
  eaCol?: string;
  labelCol?: string;
  mnCol?: string;
  argCol?: string;
  commentCol?: string;
}

interface DisasmFields {
  len: number;
  mnemonic: string;
  args: string;
  hasEA: boolean;
  d?: any;
  v?: any;
}

@customElement('gpc-disasm')
export class GpcDisasm extends LitElement {

  // --- Properties set by host via JS ---
  cpu: any = null;
  sym: any = null;
  halUCP: any = null;
  breakpoints: Map<number, {enabled: boolean}> = new Map();

  // --- Internal state ---
  private _viewAddr: number | null = null;
  private _followNIA: boolean = true;
  private _contentEl: HTMLDivElement | null = null;
  private _addrInput: HTMLInputElement | null = null;

  // --- Lit lifecycle ---

  private _resizeObserver: ResizeObserver | null = null;

  firstUpdated(): void {
    this._contentEl = this.shadowRoot!.getElementById('content') as HTMLDivElement;
    this._addrInput = this.shadowRoot!.getElementById('addr-input') as HTMLInputElement;
    // Re-render when container is resized (split-pane drag, window resize)
    this._resizeObserver = new ResizeObserver(() => {
      if (this.cpu) this.refresh();
    });
    this._resizeObserver.observe(this);
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this._resizeObserver?.disconnect();
  }

  // --- Public methods ---

  refresh(): void {
    if (!this._contentEl || !this.cpu) return;
    const startAddr = this._currentStart();
    const count = this._getLineCount();
    const lines = this._disassembleAt(startAddr, count);
    this._renderLines(this._contentEl, lines);
    // Update range display
    const lastLine = lines.filter(l => !l.isHeader);
    const endAddr = lastLine.length > 0 ? lastLine[lastLine.length - 1].addr : startAddr;
    const rangeEl = this.shadowRoot?.getElementById('disasm-range');
    if (rangeEl) {
      rangeEl.textContent = `${startAddr.toString(16).padStart(5, '0')}-${endAddr.toString(16).padStart(5, '0')}`;
    }
  }

  frameNIA(): void {
    if (!this.cpu) return;
    this._viewAddr = null;
    this._followNIA = true;
    this.refresh();
  }

  // --- Disassembly logic (ported from ap101.coffee) ---

  private _disasmFields(hw1: number, hw2: number): DisasmFields {
    const [d, v] = Instruction.decode(hw1, hw2);
    if (!d) {
      return { len: 1, mnemonic: 'DW', args: `X'${hw1.toString(16).padStart(4, '0')}'`, hasEA: false };
    }
    const len: number = d.len ?? d.origLen ?? 1;
    const full: string = Instruction.toStr(hw1, hw2);
    const mnemonic = full.substring(0, 5).trim();
    const args = full.substring(5);
    const hasEA = v.d != null || (v.I != null && (d.type === 'RI' || d.type === 'SI'));
    return { len, mnemonic, args, hasEA, d, v };
  }

  private _calcDisplayEA(desc: any, v: any, currentAddr: number): number | null {
    if (!desc) return null;
    if (desc.type === 'RR') return null;
    if (desc.opType === 4) return null; // OPTYPE_SHFT
    if (v.d == null || v.b == null) return null;

    if (v.b === 3) {
      let ea = v.d & 0xFFFF;

      if (v.i != null && v.i === 0) {
        const nia = currentAddr + (desc.len || 1);
        if (v.ii === 0 && v.ia === 0) {
          ea = (nia + v.d) & 0xFFFF;
        } else if (v.ii === 1 && v.ia === 0) {
          ea = (nia - v.d) & 0xFFFF;
        } else {
          ea = v.d & 0xFFFF;
        }
      }
      return ea & 0x7FFFF;
    }

    return null;
  }

  // Snap an address to an instruction boundary by disassembling forward
  // from the containing CSECT start. If no CSECT, returns addr unchanged.
  private _alignAddr(addr: number): number {
    if (!this.cpu || !this.sym) return addr;
    const sect = this.sym.getSectionAt(addr);
    let scanStart = 0;
    if (sect) {
      for (const s of this.sym.sectionsByAddr) {
        if (s.name === sect) { scanStart = s.address; break; }
      }
    } else {
      // No section info — scan from nearest 256-word boundary
      scanStart = Math.max(0, addr - 256);
    }
    let cur = scanStart;
    while (cur < addr && cur < 0x80000) {
      const hw1 = this.cpu.mainStorage.get16(cur, false);
      const hw2 = this.cpu.mainStorage.get16(cur + 1, false);
      const fields = this._disasmFields(hw1, hw2);
      const next = cur + fields.len;
      if (next > addr) return cur; // addr is mid-instruction, snap back
      cur = next;
    }
    return cur;
  }

  private _disassembleAt(startAddr: number, count: number): DisasmLine[] {
    const nia = this.cpu.psw.getNIA();
    const lines: DisasmLine[] = [];
    lines.push({ isHeader: true });
    let curAddr = startAddr;

    for (let i = 0; i < count; i++) {
      if (curAddr >= 0x80000) break;

      const hw1 = this.cpu.mainStorage.get16(curAddr, false);
      const hw2 = this.cpu.mainStorage.get16(curAddr + 1, false);
      const fields = this._disasmFields(hw1, hw2);
      const len = fields.len;

      // Address column
      let addrCol: string;
      if (len > 1) {
        addrCol = `${curAddr.toString(16).padStart(6, '0')}-${(curAddr + len - 1).toString(16).padStart(6, '0')}`;
      } else {
        addrCol = rpad(curAddr.toString(16).padStart(6, '0'), ' ', 13);
      }

      // Section name and offset
      const sect = this.sym ? this.sym.getSectionAt(curAddr) : null;
      const sectionColor = sect && this.sym.sectionColors ? this.sym.sectionColors[sect] : null;
      const csectCol = rpad(this.sym ? this.sym.formatCSect(curAddr) : '', ' ', 13);
      const plusIdx = csectCol.indexOf('+');
      const csectName = plusIdx >= 0 ? csectCol.substring(0, plusIdx) : csectCol;
      const csectOffset = plusIdx >= 0 ? csectCol.substring(plusIdx) : '';

      // Hex columns
      const hw1Col = hw1.toString(16).padStart(4, '0');
      const hw2Col = len > 1 ? hw2.toString(16).padStart(4, '0') : '    ';

      // Effective address
      const ea = this._calcDisplayEA(fields.d, fields.v, curAddr);
      const eaCol = ea != null ? ea.toString(16).padStart(6, '0') : '      ';

      // Label
      const label = this.sym ? this.sym.getLabelAt(curAddr) : null;
      const labelCol = label ? rpad(label.substring(0, 8), ' ', 8) : '        ';

      // Mnemonic + args
      const mnCol = rpad(fields.mnemonic, ' ', 5);
      const argCol = fields.args;

      // Comment - prefer EA label, fall back to relocation target
      let commentCol = '';
      if (ea != null && this.sym) {
        const eaLabel = this.sym.getLabelAt(ea);
        if (eaLabel) commentCol = eaLabel;
      }
      if (!commentCol && this.sym) {
        const relocSym = this.sym.getRelocAt(curAddr, len);
        if (relocSym) commentCol = relocSym;
      }
      if (this.halUCP && this.halUCP.active && this.halUCP.trapAddrs) {
        const t = this.halUCP.trapAddrs;
        if (curAddr === t.outrap || curAddr === t.intrap || curAddr === t.cntrap) {
          commentCol = commentCol ? `${commentCol} ; <-- IO TRAP` : '<-- IO TRAP';
        }
      }

      lines.push({
        isHeader: false,
        addr: curAddr,
        isNIA: curAddr === nia,
        addrCol, csectName, csectOffset, sectionColor,
        hw1Col, hw2Col, eaCol, labelCol, mnCol, argCol, commentCol,
      });
      curAddr += len;
    }
    return lines;
  }

  // --- Rendering ---

  private _renderLines(container: HTMLDivElement, lines: DisasmLine[]): void {
    container.innerHTML = '';

    for (const line of lines) {
      const div = document.createElement('div');
      div.style.cssText = 'white-space: pre; line-height: inherit; position: relative;';

      if (line.isHeader) {
        const gutter = document.createElement('span');
        gutter.style.cssText = 'display: inline-block; width: 14px; text-align: center;';
        gutter.textContent = ' ';
        div.appendChild(gutter);

        const arrow = document.createElement('span');
        arrow.style.cssText = 'display: inline-block; width: 18px;';
        arrow.textContent = ' ';
        div.appendChild(arrow);

        const hdr = document.createElement('span');
        hdr.style.color = '#666';
        hdr.textContent = 'ADDRESS        CSECT+OFFS   HW1  HW2   EA      LABEL    MNEM  OPERANDS';
        div.appendChild(hdr);
        container.appendChild(div);
        continue;
      }

      const addr = line.addr!;
      const bp = this.breakpoints.get(addr);

      if (line.isNIA) {
        div.style.backgroundColor = 'rgba(255, 136, 0, 0.15)';
        div.style.outline = '1px solid rgba(255, 136, 0, 0.4)';
        div.style.outlineOffset = '-1px';
      }

      // Gutter: breakpoint circle
      const gutter = document.createElement('span');
      gutter.style.cssText = 'display: inline-block; width: 14px; text-align: center; cursor: pointer; font-size: 10px; line-height: inherit;';
      if (bp) {
        gutter.textContent = '\u25CF'; // filled circle
        gutter.style.color = bp.enabled ? '#e22' : '#666';
      } else {
        gutter.textContent = ' ';
      }
      gutter.addEventListener('click', (e: MouseEvent) => {
        e.stopPropagation();
        this.dispatchEvent(new CustomEvent('breakpoint-toggle', {
          detail: { addr },
          bubbles: true,
          composed: true,
        }));
      });
      gutter.addEventListener('contextmenu', (e: MouseEvent) => {
        e.preventDefault();
        e.stopPropagation();
        this.dispatchEvent(new CustomEvent('breakpoint-menu', {
          detail: { addr, x: e.clientX, y: e.clientY },
          bubbles: true,
          composed: true,
        }));
      });
      div.appendChild(gutter);

      // NIA arrow
      const arrowSpan = document.createElement('span');
      arrowSpan.style.cssText = 'display: inline-block; width: 18px; text-align: center;';
      if (line.isNIA) {
        arrowSpan.textContent = ' > ';
        arrowSpan.style.color = '#f80';
        arrowSpan.style.fontWeight = 'bold';
      } else {
        arrowSpan.textContent = '   ';
      }
      div.appendChild(arrowSpan);

      // Address
      const addrSpan = document.createElement('span');
      addrSpan.style.color = '#888';
      addrSpan.textContent = line.addrCol! + '  ';
      div.appendChild(addrSpan);

      // CSECT name
      const csectNameSpan = document.createElement('span');
      if (line.sectionColor) {
        csectNameSpan.style.color = line.sectionColor.replace('40%, 20%', '60%, 60%');
      } else {
        csectNameSpan.style.color = '#888';
      }
      csectNameSpan.textContent = line.csectName!;
      div.appendChild(csectNameSpan);

      // CSECT offset
      const csectOffSpan = document.createElement('span');
      csectOffSpan.style.color = '#777';
      const padLen = 13 - line.csectName!.length - line.csectOffset!.length;
      csectOffSpan.textContent = line.csectOffset! + ' '.repeat(Math.max(0, padLen)) + ' ';
      div.appendChild(csectOffSpan);

      // HW1 HW2
      const hexSpan = document.createElement('span');
      hexSpan.style.color = '#999';
      hexSpan.textContent = `${line.hw1Col} ${line.hw2Col}  `;
      div.appendChild(hexSpan);

      // EA
      const eaSpan = document.createElement('span');
      eaSpan.style.color = line.eaCol!.trim() ? '#6aa' : '#444';
      eaSpan.textContent = line.eaCol! + '  ';
      div.appendChild(eaSpan);

      // Label
      const labelSpan = document.createElement('span');
      labelSpan.style.color = '#7af';
      labelSpan.textContent = line.labelCol! + ' ';
      div.appendChild(labelSpan);

      // Mnemonic
      const mnSpan = document.createElement('span');
      mnSpan.style.color = line.isNIA ? '#4f4' : '#0d0';
      mnSpan.style.fontWeight = line.isNIA ? 'bold' : 'normal';
      mnSpan.textContent = line.mnCol! + ' ';
      div.appendChild(mnSpan);

      // Operands
      const argSpan = document.createElement('span');
      argSpan.style.cssText = `color: ${line.isNIA ? '#eee' : '#ccc'}; display: inline-block; min-width: 18ch;`;
      argSpan.textContent = line.argCol!;
      div.appendChild(argSpan);

      // Comment
      if (line.commentCol) {
        const commentSpan = document.createElement('span');
        commentSpan.style.color = '#686';
        commentSpan.textContent = '; ' + line.commentCol;
        div.appendChild(commentSpan);
      }

      container.appendChild(div);
    }
  }

  // --- Navigation ---

  private _getLineCount(): number {
    // Use host element height minus toolbar to compute available space
    const hostHeight = this.clientHeight;
    if (hostHeight <= 0) return 20;
    const toolbar = this.shadowRoot?.getElementById('toolbar');
    const toolbarHeight = toolbar?.offsetHeight || 20;
    const lineHeight = 17; // matches #content line-height: 16.8px
    const availHeight = hostHeight - toolbarHeight - 8; // 8px padding
    const count = Math.floor(availHeight / lineHeight);
    return Math.max(5, count - 1); // -1 for header line
  }

  private _currentStart(): number {
    if (this._viewAddr != null && !this._followNIA) {
      return this._viewAddr;
    }
    if (!this.cpu) return 0;
    const nia = this.cpu.psw.getNIA();
    const lineCount = this._getLineCount();
    return this._alignAddr(Math.max(0, nia - Math.floor(lineCount / 4)));
  }

  private _scrollUp(lines: number = 1): void {
    this._viewAddr = this._alignAddr(Math.max(0, this._currentStart() - lines));
    this._followNIA = false;
    this.refresh();
  }

  private _scrollDown(lines: number = 1): void {
    this._viewAddr = this._alignAddr(Math.min(0x7FFFF, this._currentStart() + lines));
    this._followNIA = false;
    this.refresh();
  }

  private _pageUp(): void {
    const count = this._getLineCount();
    this._viewAddr = this._alignAddr(Math.max(0, this._currentStart() - count));
    this._followNIA = false;
    this.refresh();
  }

  private _pageDown(): void {
    const count = this._getLineCount();
    this._viewAddr = this._alignAddr(Math.min(0x7FFFF, this._currentStart() + count));
    this._followNIA = false;
    this.refresh();
  }

  private _goto(addrStr: string): void {
    const parsed = parseInt(addrStr.trim().replace(/^0x/i, ''), 16);
    if (!Number.isFinite(parsed)) return;
    this._viewAddr = this._alignAddr(Math.max(0, Math.min(0x7FFFF, parsed)));
    this._followNIA = false;
    this.refresh();
  }

  private _onFrameNIA(): void {
    this.frameNIA();
  }

  private _onWheel(e: WheelEvent): void {
    e.preventDefault();
    if (e.deltaY < 0) {
      this._scrollUp(3);
    } else if (e.deltaY > 0) {
      this._scrollDown(3);
    }
  }

  private _onAddrKeyDown(e: KeyboardEvent): void {
    if (e.key !== 'Enter') return;
    const input = e.target as HTMLInputElement;
    this._goto(input.value);
  }

  // --- Template ---

  render() {
    return html`
      <sim-toolbar label="DISASSEMBLY">
        <button class="sm" @click="${this._pageUp}" title="Page Up">⬆⬆</button>
        <button class="sm" @click="${() => this._scrollUp(1)}" title="Scroll Up">⬆</button>
        <button class="sm" @click="${() => this._scrollDown(1)}" title="Scroll Down">⬇</button>
        <button class="sm" @click="${this._pageDown}" title="Page Down">⬇⬇</button>
        <span class="toolbar-label">Go to:</span>
        <input id="addr-input" type="text" placeholder="hex addr"
          @keydown="${this._onAddrKeyDown}" />
        <button class="sm" style="color: #f80; font-size: 12px;" @click="${this._onFrameNIA}" title="Frame NIA">◎</button>
        <span id="disasm-range" class="toolbar-label" slot="status"></span>
      </sim-toolbar>
      <div id="content" @wheel="${this._onWheel}"></div>
    `;
  }

  // --- Styles ---

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      overflow: hidden;
      padding: 4px 8px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 12px;
      color: #ddd;
      min-height: 0;
      min-width: 0;
      flex: 1;
    }

    #content {
      flex: 1;
      overflow: hidden;
      margin: 0;
      font-size: 12px;
      line-height: 16.8px;
      white-space: pre;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-disasm': GpcDisasm;
  }
}
