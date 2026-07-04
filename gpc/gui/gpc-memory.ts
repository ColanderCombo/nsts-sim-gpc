import {LitElement, html, css, render} from 'lit';
import {customElement} from 'lit/decorators.js';
import 'cde/toolbar';
import 'com/util';
import {interpretHalfwords} from 'gpc/gui/memformat';

@customElement('gpc-memory')
export class GpcMemory extends LitElement {

  // --- Properties set by host via JS ---
  cpu: any = null;
  sym: any = null;
  selectedSection: string | null = null;
  watchAddresses: Set<number> | null = null;

  // --- Internal state ---
  private _viewStart: number = 0;
  private _wordsPerRow: number = 16;
  private _rowCount: number = 8;
  private _selStart: number | null = null;
  private _selEnd: number | null = null;
  private _tooltipEl: HTMLDivElement | null = null;
  // When true, show main-store protection bits and underline protected words.
  private _showProt: boolean = false;

  private _contentEl: HTMLDivElement | null = null;
  private _resizeObserver: ResizeObserver | null = null;
  // Toolbar is hoisted into the dock tab strip (see getToolbar()).
  private _toolbarEl: HTMLElement | null = null;
  private _rangeText: string = '';

  // --- Lit lifecycle ---

  // Re-observe on every (re)connection: the dock recreates panes when the
  // layout restructures, which disconnects/reconnects this element.
  connectedCallback(): void {
    super.connectedCallback();
    if (!this._resizeObserver) {
      this._resizeObserver = new ResizeObserver(() => { if (this.cpu) this.refresh(); });
    }
    this._resizeObserver.observe(this);
  }

  firstUpdated(): void {
    this._contentEl = this.shadowRoot!.getElementById('content') as HTMLDivElement;
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this._resizeObserver?.disconnect();
  }

  // --- Public methods ---

  refresh(): void {
    const contentEl = this._contentEl;
    if (!contentEl || !this.cpu) return;

    this._hideTooltip();

    // --- Layout calculation ---
    const containerWidth = contentEl.clientWidth || 800;
    const addrWidth = 58;
    const chunkWidth = 16 * 28 + 15 * 7; // 553px per 16-word chunk
    const chunkSeparator = 14;
    const availWidth = containerWidth - addrWidth - 20;
    const numChunks = Math.max(1, Math.min(4, Math.floor((availWidth + chunkSeparator) / (chunkWidth + chunkSeparator))));
    this._wordsPerRow = numChunks * 16;

    const hostHeight = this.clientHeight;
    // Toolbar now lives in the dock tab strip, so the content fills the host.
    const lineHeight = 16;
    const availHeight = hostHeight - 8;
    this._rowCount = Math.max(2, Math.floor(availHeight / lineHeight));

    // --- Build row data ---
    const nia = this.cpu.psw.getNIA();
    const wordCount = this._wordsPerRow * this._rowCount;
    const rows = this._formatMemory(this._viewStart, wordCount, nia);

    // --- Render rows ---
    contentEl.innerHTML = '';
    contentEl.onmousedown = (e: MouseEvent) => {
      if (e.target === contentEl || (e.target as HTMLElement).tagName === 'DIV') {
        this._selStart = null;
        this._selEnd = null;
        this._hideTooltip();
        this.refresh();
      }
    };

    const sel = this._selRange();

    for (const row of rows) {
      const rowDiv = document.createElement('div');
      rowDiv.style.cssText = 'white-space: nowrap; line-height: 16px;';

      // Address prefix
      const addrSpan = document.createElement('span');
      addrSpan.style.color = '#666';
      addrSpan.textContent = row.addrStr + ': ';
      rowDiv.appendChild(addrSpan);

      // Group consecutive words by section for continuous background coloring
      let currentGroup: HTMLSpanElement | null = null;
      let currentSection: string | null = null;

      const flushGroup = () => {
        if (currentGroup) {
          rowDiv.appendChild(currentGroup);
          currentGroup = null;
          currentSection = null;
        }
      };

      for (let idx = 0; idx < row.words.length; idx++) {
        const word = row.words[idx];

        // Check if we need a new group (different section or 16-word boundary)
        const needNewGroup = idx === 0 || word.section !== currentSection || (idx > 0 && idx % 16 === 0);

        if (needNewGroup) {
          flushGroup();
          // Add spacing between groups
          if (idx > 0) {
            let sep: Text;
            if (idx % 16 === 0) {
              // Chunk separator at 16-word boundaries
              sep = document.createTextNode('  ');
            } else {
              // Single space between different sections
              sep = document.createTextNode(' ');
            }
            rowDiv.appendChild(sep);
          }
          // Start new group
          currentGroup = document.createElement('span');
          currentSection = word.section;
          if (word.bgColor && !word.isNIA) {
            currentGroup.style.backgroundColor = word.bgColor;
          }
          // Highlight if selected section
          if (this.selectedSection && word.section === this.selectedSection) {
            currentGroup.style.outline = '1px solid #aa8';
            currentGroup.style.outlineOffset = '-1px';
          }
        } else {
          // Add space between words within the same group (with background color)
          const spacer = document.createTextNode(' ');
          currentGroup!.appendChild(spacer);
        }

        // Create word span
        const wordSpan = document.createElement('span');
        wordSpan.style.color = word.color;
        wordSpan.style.display = 'inline-block';
        wordSpan.style.width = '28px';
        wordSpan.style.textAlign = 'center';
        wordSpan.style.cursor = 'pointer';

        // Highlight: NIA (orange), watched variable (yellow outline), selection (blue)
        const isSelected = sel && word.addr >= sel.lo && word.addr <= sel.hi;
        if (word.isNIA) {
          wordSpan.style.backgroundColor = '#f80';
          wordSpan.style.color = '#000';
        } else if (isSelected) {
          wordSpan.style.backgroundColor = '#248';
          wordSpan.style.color = '#fff';
        } else if (this.watchAddresses && this.watchAddresses.has(word.addr)) {
          wordSpan.style.backgroundColor = '#440';
          wordSpan.style.outline = '1px solid #ff0';
          wordSpan.style.outlineOffset = '-1px';
        }
        // Underline protected halfwords when PROT BITS is on; the underline
        // colour fades from white when the protection bit was just changed.
        if (this._showProt && word.prot) {
          wordSpan.style.textDecoration = 'underline';
          wordSpan.style.textDecorationColor = this.cpu.mainStorage.getProtColor(word.addr, true);
        }
        wordSpan.textContent = word.value;
        wordSpan.title = ''; // suppress inherited title from parent

        // Click to select, shift-click to extend
        const wordAddr = word.addr;
        const isSel = isSelected;
        wordSpan.onmousedown = (e: MouseEvent) => {
          e.preventDefault();
          this._hideTooltip();
          this._selectWord(wordAddr, e.shiftKey);
        };
        wordSpan.onmousemove = (_e: MouseEvent) => {
          if (isSel && !this._tooltipEl) {
            this._showTooltip(wordSpan);
          }
        };
        wordSpan.onmouseleave = (_e: MouseEvent) => {
          this._hideTooltip();
        };

        currentGroup!.appendChild(wordSpan);
      }

      flushGroup();

      // Protection-bits block, to the right of the data (gap of 4 spaces, then
      // one 0/1 per halfword, with a double space after every 16 bits).
      if (this._showProt) {
        const gap = document.createElement('span');
        gap.style.whiteSpace = 'pre'; // preserve the 4-space gap (row is nowrap)
        gap.textContent = '    ';
        rowDiv.appendChild(gap);

        const protBlock = document.createElement('span');
        protBlock.style.whiteSpace = 'pre'; // preserve the double-space group gaps
        for (let k = 0; k < row.words.length; k++) {
          const bit = document.createElement('span');
          bit.textContent = row.words[k].prot ? '1' : '0';
          bit.style.color = this.cpu.mainStorage.getProtColor(row.words[k].addr, row.words[k].prot);
          protBlock.appendChild(bit);
          if ((k + 1) % 16 === 0 && k < row.words.length - 1) {
            protBlock.appendChild(document.createTextNode('  '));
          }
        }
        rowDiv.appendChild(protBlock);
      }

      contentEl.appendChild(rowDiv);
    }

    // Update the range display in the hoisted toolbar
    const endAddr = this._viewStart + (this._wordsPerRow * this._rowCount) - 1;
    this._rangeText = `${this._viewStart.toString(16).padStart(5, '0')}-${endAddr.toString(16).padStart(5, '0')}`;
    if (this._toolbarEl) render(this._toolbarTemplate(), this._toolbarEl, { host: this });
  }

  // --- Memory data formatting (ported from ap101.coffee formatMemory) ---

  private _formatMemory(startAddr: number, count: number, nia: number): Array<{addr: number; addrStr: string; words: Array<any>}> {
    const rows: Array<{addr: number; addrStr: string; words: Array<any>}> = [];
    let addr = startAddr;
    while (addr < startAddr + count) {
      const row = {
        addr: addr,
        addrStr: addr.toString(16).padStart(5, '0'),
        words: [] as Array<any>,
      };
      for (let i = 0; i < this._wordsPerRow; i++) {
        const wordAddr = addr + i;
        if (wordAddr < startAddr + count && wordAddr < 0x80000) {
          const hw = this.cpu.mainStorage.get16(wordAddr, false);
          const color = this.cpu.mainStorage.getAccessColor(wordAddr);
          const section = this.sym ? this.sym.getSectionAt(wordAddr) : null;
          const bgColor = section && this.sym.sectionColors ? this.sym.sectionColors[section] : null;
          const isNIA = wordAddr === nia;
          row.words.push({
            addr: wordAddr,
            value: hw.toString(16).padStart(4, '0'),
            color: color,
            bgColor: bgColor,
            section: section,
            isNIA: isNIA,
            prot: !!this.cpu.mainStorage.getStoreProtect(wordAddr),
          });
        } else {
          row.words.push({ addr: wordAddr, value: '    ', color: '#444', bgColor: null, section: null, isNIA: false, prot: false });
        }
      }
      rows.push(row);
      addr += this._wordsPerRow;
    }
    return rows;
  }

  // --- Selection ---

  private _selectWord(addr: number, extend: boolean): void {
    if (extend && this._selStart != null) {
      this._selEnd = addr;
    } else {
      this._selStart = addr;
      this._selEnd = addr;
    }
    this.refresh();
  }

  private _selRange(): { lo: number; hi: number; count: number } | null {
    if (this._selStart == null || this._selEnd == null) return null;
    const lo = Math.min(this._selStart, this._selEnd);
    const hi = Math.max(this._selStart, this._selEnd);
    return { lo, hi, count: hi - lo + 1 };
  }

  // --- Tooltip ---

  private _interpretSelection(): string[] | null {
    const sel = this._selRange();
    if (!sel || !this.cpu) return null;
    const { lo, hi } = sel;
    const hws: number[] = [];
    for (let a = lo; a <= hi; a++) {
      hws.push(this.cpu.mainStorage.get16(a, false));
    }
    return interpretHalfwords(hws, lo);
  }

  private _showTooltip(wordSpan: HTMLSpanElement): void {
    const lines = this._interpretSelection();
    if (!lines || lines.length === 0) return;

    this._hideTooltip();

    const tip = document.createElement('div');
    tip.id = 'mem-tooltip';
    tip.style.cssText = 'position: fixed; background: #2a2a2a; border: 1px solid #888; padding: 6px 10px; z-index: 10000; font-family: "Consolas for Powerline", Consolas, monospace; font-size: 11px; color: #ddd; white-space: pre; pointer-events: none; line-height: 16px;';
    tip.textContent = lines.join('\n');

    // Position near the hovered word
    const rect = wordSpan.getBoundingClientRect();
    tip.style.left = `${rect.left}px`;
    tip.style.top = `${rect.bottom + 4}px`;

    // Append to shadow DOM so it stays scoped
    this.shadowRoot!.appendChild(tip);

    // Clamp to viewport
    const tipRect = tip.getBoundingClientRect();
    if (tipRect.right > window.innerWidth) {
      tip.style.left = `${window.innerWidth - tipRect.width - 4}px`;
    }
    if (tipRect.bottom > window.innerHeight) {
      tip.style.top = `${rect.top - tipRect.height - 4}px`;
    }

    this._tooltipEl = tip;
  }

  private _hideTooltip(): void {
    if (this._tooltipEl) {
      this._tooltipEl.remove();
      this._tooltipEl = null;
    }
  }

  // --- Navigation ---

  private _scrollUp(): void {
    this._viewStart = Math.max(0, this._viewStart - this._wordsPerRow * 4);
    this.refresh();
  }

  private _scrollDown(): void {
    this._viewStart = Math.min(0x7fff0, this._viewStart + this._wordsPerRow * 4);
    this.refresh();
  }

  private _pageUp(): void {
    this._viewStart = Math.max(0, this._viewStart - this._wordsPerRow * this._rowCount);
    this.refresh();
  }

  private _pageDown(): void {
    this._viewStart = Math.min(0x7fff0, this._viewStart + this._wordsPerRow * this._rowCount);
    this.refresh();
  }

  private _goto(addrStr: string): void {
    const parsed = parseInt(addrStr.trim().replace(/^0x/i, ''), 16);
    if (!Number.isFinite(parsed)) return;
    this._viewStart = Math.max(0, Math.min(0x7fff0, parsed & 0x7fff0));
    this.refresh();
  }

  private _onAddrKeyDown(e: KeyboardEvent): void {
    if (e.key !== 'Enter') return;
    const input = e.target as HTMLInputElement;
    this._goto(input.value);
  }

  private _onWheel(e: WheelEvent): void {
    e.preventDefault();
    if (e.deltaY < 0) {
      this._scrollUp();
    } else if (e.deltaY > 0) {
      this._scrollDown();
    }
  }

  private _toggleProt(): void {
    this._showProt = !this._showProt;
    this.refresh(); // re-renders data (underlines + bits block) and the toolbar
  }

  // --- Template ---

  render() {
    return html`<div id="content" @wheel="${this._onWheel}"></div>`;
  }

  // Toolbar hoisted into the dock tab strip; re-rendered in place on refresh.
  getToolbar(): HTMLElement {
    if (!this._toolbarEl) {
      this._toolbarEl = document.createElement('div');
      this._toolbarEl.style.display = 'contents';
    }
    render(this._toolbarTemplate(), this._toolbarEl, { host: this });
    return this._toolbarEl;
  }

  private _toolbarTemplate() {
    return html`
      <sim-toolbar>
        <button class="sm" @click="${this._pageUp}" title="Page Up">⬆⬆</button>
        <button class="sm" @click="${this._scrollUp}" title="Scroll Up">⬆</button>
        <button class="sm" @click="${this._scrollDown}" title="Scroll Down">⬇</button>
        <button class="sm" @click="${this._pageDown}" title="Page Down">⬇⬇</button>
        <span class="toolbar-label">Go to:</span>
        <input type="text" placeholder="hex addr"
          @keydown="${this._onAddrKeyDown}" title="Enter hex address and press Enter" />
        <button class="sm" style="margin-left: 6px; ${this._showProt ? 'background:#3a5; color:#fff; border-color:#5c7;' : ''}"
          @click="${this._toggleProt}"
          title="Toggle main-store protection bits">PROT BITS</button>
        <span class="toolbar-label" style="margin-left: 8px;">${this._rangeText}</span>
      </sim-toolbar>
    `;
  }

  // --- Styles ---

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      overflow: hidden;
      padding: 4px 8px;
      background-color: #0a0a0a;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      min-height: 0;
      min-width: 0;
      flex: 1;
    }

    #content {
      flex: 1;
      overflow: auto;
      font-size: 11px;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-memory': GpcMemory;
  }
}
