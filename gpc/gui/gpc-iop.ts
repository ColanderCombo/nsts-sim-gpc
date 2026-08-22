import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';

/**
 * <gpc-iop>: the IOP and its 25 processors.
 *
 * The IOP is one MSC and 24 BCEs running the same shape of state 25 times
 * over, so a Registers-pane layout per processor would be 25 panes.  Here
 * each processor is one line, its status bits and its local store
 * registers, and unfolding it adds three: the disassembly at its PC, the
 * words its MIA has put on the bus, and the words that have come back.
 *
 * Properties (set via JS):
 *   iop -- IOP instance (procStates, procDisasm, group1Sources, ls, dmaQueue)
 *
 * Public methods:
 *   refresh() -- re-read the IOP and re-render
 */
@customElement('gpc-iop')
export class GpcIop extends LitElement {

  iop: any = null;

  // Which processors are unfolded, and whether the idle ones are listed at
  // all.  Both survive the refreshes a run triggers.
  private _open = new Set<number>();
  private _activeOnly = false;
  private _disasmRows = 4;
  private _showRegs = true;

  private _hex(v: number, w: number): string {
    return (v >>> 0).toString(16).padStart(w, '0');
  }

  private _cell(cls: string, text: string, title?: string): HTMLElement {
    const el = document.createElement('span');
    el.className = cls;
    el.textContent = text;
    if (title) el.title = title;
    return el;
  }

  // A status bit as a lamp: lit when set, dim when clear.
  private _lamp(label: string, on: boolean, title: string, color = '#6c6'): HTMLElement {
    const el = this._cell('lamp', label, title);
    el.style.color = on ? color : '#444';
    return el;
  }

  private _check(label: string, checked: boolean, title: string,
                 onChange: (v: boolean) => void): HTMLElement {
    const wrap = document.createElement('label');
    wrap.className = 'chk';
    wrap.title = title;
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = checked;
    box.addEventListener('change', () => onChange(box.checked));
    wrap.appendChild(box);
    wrap.appendChild(document.createTextNode(label));
    return wrap;
  }

  // A header that folds the section under it.  The triangle is part of the
  // header rather than a separate control so the whole strip is the target.
  private _foldHeader(text: string, open: boolean, toggle: () => void,
                      ...controls: HTMLElement[]): HTMLElement {
    const h = this._header(`${open ? '▾' : '▸'} ${text}`, ...controls);
    h.classList.add('foldable');
    h.addEventListener('click', (e) => {
      if ((e.target as HTMLElement).tagName === 'INPUT') return;
      toggle();
    });
    return h;
  }

  private _header(text: string, ...controls: HTMLElement[]): HTMLElement {
    const h = document.createElement('div');
    h.className = 'hdr';
    h.appendChild(this._cell('htext', text));
    for (const c of controls) h.appendChild(c);
    return h;
  }

  // The IOP itself, above the processor list
  //
  private _iopRows(container: HTMLElement): void {
    const iop = this.iop;

    const row1 = document.createElement('div');
    row1.className = 'row iopstate';
    // Which processor the time-sliced local store is pointing at right now.
    row1.appendChild(this._cell('ilabel', 'SLICE'));
    row1.appendChild(this._cell('ival', `${iop.ls?.slice ?? 0}`,
      'time slice within the 33-slice round: slice 0, 4, 8 ... belong to the MSC'));
    row1.appendChild(this._cell('ilabel', 'PAGE'));
    row1.appendChild(this._cell('ival',
      iop.ls?.curPage === 0 ? 'MSC' : `BCE ${iop.ls?.curPage}`,
      'local store page the IOP is executing from'));
    row1.appendChild(this._cell('ilabel', 'DMA'));
    row1.appendChild(this._cell('ival', `${iop.dmaQueue?.length ?? 0}`,
      'DMA requests queued against main storage'));
    row1.appendChild(this._cell('ilabel', 'BURST'));
    row1.appendChild(this._cell('ival', iop.dmaBurst ? 'on' : 'off',
      'DMA burst mode (PCO C104 0000 / C004 0000)'));
    container.appendChild(row1);

    // The GO/NO-GO timer, and what External 0 is holding.
    const row2 = document.createElement('div');
    row2.className = 'row iopstate';
    row2.appendChild(this._cell('ilabel', 'WDOG'));
    const wd = this._cell('ival', this._hex(iop.wdCount ?? 0, 3),
      'GO/NO-GO timer count, 0.768 ms a tick, counting up to a full count');
    if (iop.wdTimeout) wd.style.color = '#e22';
    else if (!iop.wdRunning) wd.style.color = '#666';
    row2.appendChild(wd);
    row2.appendChild(this._cell('ival',
      iop.wdTimeout ? 'TIMED OUT' : iop.wdRunning ? 'running' : 'stopped',
      'the timer does not run until a LOAD GO/NO-GO TIMER PCO starts it'));
    const sources: string[] = iop.group1Sources?.() ?? [];
    if (sources.length > 0) {
      row2.appendChild(this._cell('ilabel', 'REG A'));
      row2.appendChild(this._cell('isrc', sources.join(', '),
        'interrupt register A — the External 0 sources, cleared when the handler reads it'));
    }
    container.appendChild(row2);
  }

  // The IOP's own registers, raw
  //
  private _globalRegRows(container: HTMLElement): void {
    const regs = this.iop.globalRegs?.() ?? [];
    for (const r of regs) {
      const row = document.createElement('div');
      row.className = 'row greg';
      row.appendChild(this._cell('gname', r.name, r.note));
      row.appendChild(this._cell('gvalue', this._hex(r.value, 8)));
      row.appendChild(this._cell('gnote', r.note));
      container.appendChild(row);
    }
  }

  // One processor's line
  //
  private _procRow(st: any): HTMLElement {
    const row = document.createElement('div');
    row.className = 'row proc';
    if (st.current) row.classList.add('current');
    if (!st.enabled) row.classList.add('halted');

    const open = this._open.has(st.num);
    const fold = this._cell('fold', open ? '▾' : '▸',
      'show this processor\'s disassembly and bus traffic');
    row.appendChild(fold);

    const name = this._cell('pname', st.name,
      st.kind === 'MSC' ? 'Master Sequence Controller' : `Bus Control Element ${st.num}`);
    row.appendChild(name);

    // STAT5, STAT4, STAT1 and the indicator, then the MIA enables.
    row.appendChild(this._lamp('EN', st.enabled, 'STAT5: enabled, or halted'));
    row.appendChild(this._lamp('BSY', st.busy, 'STAT4: busy, or waiting', '#fa0'));
    row.appendChild(this._lamp('GO', st.go, 'STAT1: GO, or NO-GO (error)'));
    row.appendChild(this._lamp('IND', st.indicator, 'BCE indicator bit', '#6cf'));
    if (st.kind === 'BCE') {
      row.appendChild(this._lamp('TX', st.xmitEna, 'MIA transmitter enabled', '#6cf'));
      row.appendChild(this._lamp('RX', st.recvEna, 'MIA receiver enabled', '#6cf'));
    }

    // Then the local store registers this kind of processor has.
    for (const r of st.regs) {
      const cell = document.createElement('span');
      cell.className = 'reg';
      const lbl = this._cell('rlabel', r.name);
      const val = this._cell('rvalue', this._hex(r.value, 5));
      cell.appendChild(lbl);
      cell.appendChild(val);
      row.appendChild(cell);
    }

    row.addEventListener('click', () => {
      if (this._open.has(st.num)) this._open.delete(st.num);
      else this._open.add(st.num);
      this.refresh();
    });
    return row;
  }

  // The three rows an unfolded processor adds
  //
  private _disasmRow(st: any): HTMLElement {
    const box = document.createElement('div');
    box.className = 'detail disasm';
    const rows = this.iop.procDisasm?.(st.num, this._disasmRows) ?? [];
    if (rows.length === 0) {
      box.appendChild(this._cell('empty', '(no disassembly)'));
      return box;
    }
    for (const d of rows) {
      const line = document.createElement('div');
      line.className = 'dline';
      if (d.addr === st.pc) line.classList.add('atpc');
      line.appendChild(this._cell('daddr', this._hex(d.addr, 4)));
      line.appendChild(this._cell('dhw',
        d.len > 1 ? `${this._hex(d.hw1, 4)} ${this._hex(d.hw2, 4)}` : `${this._hex(d.hw1, 4)}     `));
      line.appendChild(this._cell('dtext', d.text));
      box.appendChild(line);
    }
    return box;
  }

  // A traffic ring, newest last.  Command words are flagged, since a
  // command and a data word look alike once they are hex.
  private _ringRow(label: string, ring: any[], title: string, extra = ''): HTMLElement {
    const box = document.createElement('div');
    box.className = 'detail ring';
    box.appendChild(this._cell('rname', label, title));
    if (!ring || ring.length === 0) {
      box.appendChild(this._cell('empty', '(none)'));
      return box;
    }
    const shown = ring.slice(-16);
    box.appendChild(this._cell('rcount', `${ring[ring.length - 1].seq}`,
      'words across this MIA so far'));
    for (const w of shown) {
      const cell = this._cell('word', (w.cmd ? '*' : '') + this._hex(w.value, 4),
        `${w.cmd ? 'command' : 'data'} at ${(w.timeNs / 1e6).toFixed(3)} ms`);
      if (w.cmd) cell.classList.add('cmd');
      box.appendChild(cell);
    }
    if (extra) box.appendChild(this._cell('rextra', extra));
    return box;
  }

  firstUpdated(): void {
    this.refresh();
  }

  refresh(): void {
    const container = this.shadowRoot?.getElementById('content');
    if (!container) return;
    if (!this.iop?.procStates) { container.innerHTML = ''; return; }

    container.innerHTML = '';
    container.appendChild(this._header('IOP'));
    this._iopRows(container);

    container.appendChild(this._foldHeader('REGISTERS', this._showRegs,
      () => { this._showRegs = !this._showRegs; this.refresh(); }));
    if (this._showRegs) this._globalRegRows(container);

    const states = this.iop.procStates().filter((s: any) => s);
    const active = (s: any) => s.enabled || s.busy || s.tx.length > 0 || s.rx.length > 0;
    const shown = this._activeOnly ? states.filter(active) : states;

    container.appendChild(this._header(
      `PROCESSORS (${states.filter(active).length} of ${states.length} active)`,
      this._check('active only', this._activeOnly,
        'list only processors that are enabled, busy, or have bus traffic',
        (v) => { this._activeOnly = v; this.refresh(); })));

    if (shown.length === 0) {
      container.appendChild(this._cell('empty', '(none active)'));
      return;
    }
    for (const st of shown) {
      container.appendChild(this._procRow(st));
      if (!this._open.has(st.num)) continue;
      container.appendChild(this._disasmRow(st));
      // Only the BCEs have a MIA; the MSC reaches the buses through them,
      // so there is no traffic of its own to show.
      if (st.kind !== 'BCE') continue;
      container.appendChild(this._ringRow('TX', st.tx, 'words this MIA has put on its bus'));
      container.appendChild(this._ringRow('RX', st.rx, 'words that have arrived from its bus',
        st.rxPending > 0 ? `${st.rxPending} unread` : ''));
    }
  }

  render() {
    return html`<div id="content"></div>`;
  }

  static styles = css`
    :host {
      display: block;
      overflow: auto;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      font-size: 11px;
      color: #ccc;
    }

    .hdr {
      display: flex;
      align-items: center;
      gap: 6px;
      color: #888;
      font-size: 10px;
      margin-top: 4px;
      padding: 1px 2px;
      border-bottom: 1px solid #333;
      position: sticky;
      top: 0;
      background: #111;
    }
    .htext { flex: 1; }

    .chk { display: inline-flex; align-items: center; gap: 2px; color: #888; }
    .chk input { margin: 0; }

    .row {
      display: flex;
      align-items: center;
      gap: 4px;
      line-height: 15px;
      padding: 0 2px;
      white-space: nowrap;
    }
    .row.proc { cursor: pointer; }
    .row.proc:hover { background-color: #1a1a1a; }
    .row.proc.current { background-color: #10201a; }
    .row.proc.halted .pname { color: #667; }

    .fold { flex: 0 0 8px; color: #888; }
    .pname { color: #7af; flex: 0 0 46px; }
    .lamp { flex: 0 0 auto; font-size: 10px; }

    .reg { display: inline-flex; gap: 2px; margin-left: 4px; }
    .rlabel { color: #666; }
    .rvalue { color: #ccc; }

    .hdr.foldable { cursor: pointer; }
    .hdr.foldable:hover { color: #ccc; }

    .row.greg { line-height: 14px; }
    .gname { color: #7af; flex: 0 0 58px; }
    .gvalue { color: #ccc; flex: 0 0 70px; }
    .gnote { color: #666; overflow: hidden; text-overflow: ellipsis; }

    .ilabel { color: #666; }
    .ival { color: #ccc; margin-right: 6px; }
    .isrc { color: #6cf; }
    .row.iopstate { color: #999; }

    .detail {
      display: flex;
      align-items: baseline;
      gap: 4px;
      padding: 0 2px 0 18px;
      white-space: nowrap;
      line-height: 14px;
    }
    .detail.disasm { display: block; }

    .dline { display: flex; gap: 6px; line-height: 14px; }
    .dline.atpc { background-color: #202810; }
    .daddr { color: #8c8; }
    .dhw { color: #666; }
    .dtext { color: #ccc; }

    .rname { color: #7af; flex: 0 0 18px; }
    .rcount { color: #555; flex: 0 0 auto; margin-right: 2px; }
    .word { color: #ccc; }
    .word.cmd { color: #fa0; }
    .rextra { color: #a66; }

    .empty { color: #555; padding: 0 4px; }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-iop': GpcIop;
  }
}
