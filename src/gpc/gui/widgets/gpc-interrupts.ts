import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';

/**
 * <gpc-interrupts>: interval timers, the interrupt repertoire, and a log
 * of what has been accepted.
 *
 * The machine's own view of an interrupt is three bits in three different
 * places: a pending latch here, a mask bit in the PSW, a PSW pair in the
 * PSA.  This puts them in one row, and lets the ground side load a timer
 * or force an interrupt the way the AGE could.
 *
 * Properties (set via JS):
 *   cpu       -- CPU instance (intStatus, timerValue, timerRemainingUs, intLog)
 *   iop       -- IOP instance, for the External 0 sources (interrupt register A)
 *   harness   -- GUIHarness, for breakOnInterrupt / holdInterrupt state
 *
 * Public methods:
 *   refresh() -- re-read the CPU state and re-render
 *
 * Events (all bubble, composed):
 *   interrupt-raise        detail: { key }
 *   interrupt-clear        detail: { key }
 *   interrupt-mask-toggle  detail: { maskBit }
 *   interrupt-log-clear    detail: {}
 *   break-on-interrupt-changed  detail: { value }
 *   hold-interrupt-changed      detail: { value }
 *   timer-load             detail: { n, value }
 *   system-reset           detail: {}
 */
@customElement('gpc-interrupts')
export class GpcInterrupts extends LitElement {

  cpu: any = null;
  iop: any = null;
  harness: any = null;

  private _showLog = true;

  private _emit(name: string, detail: any = {}): void {
    this.dispatchEvent(new CustomEvent(name, { detail, bubbles: true, composed: true }));
  }

  private _hex(v: number, w: number): string {
    return (v >>> 0).toString(16).padStart(w, '0');
  }

  // 5 000 000 us reads better as 5.000 s; 250 us should stay 250 us.
  private _duration(us: number): string {
    if (us >= 1e6) return `${(us / 1e6).toFixed(3)} s`;
    if (us >= 1e3) return `${(us / 1e3).toFixed(3)} ms`;
    return `${us} us`;
  }

  private _cell(cls: string, text: string, title?: string): HTMLElement {
    const el = document.createElement('span');
    el.className = cls;
    el.textContent = text;
    if (title) el.title = title;
    return el;
  }

  private _check(label: string, checked: boolean, title: string,
                 onChange: (v: boolean) => void): HTMLElement {
    const wrap = document.createElement('label');
    wrap.className = 'brk';
    wrap.title = title;
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.checked = checked;
    box.addEventListener('change', () => onChange(box.checked));
    wrap.appendChild(box);
    wrap.appendChild(document.createTextNode(label));
    return wrap;
  }

  private _button(label: string, title: string, onClick: () => void): HTMLElement {
    const b = document.createElement('button');
    b.textContent = label;
    b.title = title;
    b.addEventListener('click', (e) => { e.stopPropagation(); onClick(); });
    return b;
  }

  // A count typed into a timer field.  Bare digits are hex, matching what
  // the field displays and what an ICR control word carries; a time suffix
  // is taken as a duration, since the count is microseconds and "40ms" is
  // what a reader actually has in mind.
  private _parseCount(text: string): number | null {
    const s = text.trim().toLowerCase();
    const t = s.match(/^([0-9]*\.?[0-9]+)\s*(us|ms|s)$/);
    if (t) {
      const mult = t[2] === 's' ? 1e6 : t[2] === 'ms' ? 1e3 : 1;
      const n = Math.round(parseFloat(t[1]) * mult);
      return n >= 0 && n <= 0xffffffff ? n >>> 0 : null;
    }
    const v = parseInt(s.replace(/^0x/, ''), 16);
    return isNaN(v) ? null : v >>> 0;
  }

  // Interval timers
  //
  // Each row: the 32-bit count, how long until it times out, and a field
  // to load it (the ICR write command's effect).
  private _timerRow(n: number): HTMLElement {
    const row = document.createElement('div');
    row.className = 'row timer';

    const value = this.cpu.timerValue(n);
    const us = this.cpu.timerRemainingUs(n);
    const hiAddr = this.cpu.TIMER_HI(n);

    row.appendChild(this._cell('tname', `TIMER ${n}`,
      `high halfword at PSA 0x${this._hex(hiAddr, 4)}, low halfword in the hardware counter`));

    const input = document.createElement('input');
    input.className = 'tvalue';
    input.value = this._hex(value, 8);
    input.title = 'load the 32-bit count — hex like 9c40, or a time like 40ms / 250us / 1s'
                + ' (the count is microseconds).  Resets the clock interrupt latch.';
    input.addEventListener('keydown', (e: KeyboardEvent) => {
      if (e.key === 'Enter') {
        const v = this._parseCount(input.value);
        if (v != null) this._emit('timer-load', { n, value: v });
        input.blur();
      } else if (e.key === 'Escape') {
        input.value = this._hex(this.cpu.timerValue(n), 8);
        input.blur();
      }
      e.stopPropagation();
    });
    row.appendChild(input);

    row.appendChild(this._cell('tdue', `T-${this._duration(us)}`,
      `${us} us of CPU time until timeout`));
    return row;
  }

  // Interrupt rows
  //
  private _intRow(st: any): HTMLElement {
    const row = document.createElement('div');
    row.className = 'row int';
    if (st.held) row.classList.add('held');
    else if (st.blocked) row.classList.add('blocked');
    else if (st.pending) row.classList.add('pending');

    // Pending lamp: lit when pending, amber when pending but masked off,
    // and a filled ring for the one the machine is holding pre-swap.
    const lamp = document.createElement('span');
    lamp.className = 'lamp';
    lamp.textContent = st.held ? '◉' : (st.pending ? '●' : '○');
    lamp.style.color = st.held ? '#6cf' : (st.blocked ? '#fa0' : (st.pending ? '#e22' : '#444'));
    lamp.title = st.held
      ? 'decided, held in front of the PSW swap — step or run to take it'
      : st.pending
      ? (st.enabled ? 'pending' : `pending but masked (${st.pends ? 'stays pending' : 'will be dropped'})`)
      : 'not pending';
    row.appendChild(lamp);

    row.appendChild(this._cell('key', st.key, `${st.label}  [POO class ${st.cls}]`));

    // Mask bit; click to flip it in the PSW
    const mask = document.createElement('span');
    mask.className = 'mask' + (st.maskBit == null ? ' nomask' : (st.enabled ? ' on' : ' off'));
    if (st.maskBit == null) {
      mask.textContent = 'n/m';
      mask.title = 'not maskable';
    } else {
      mask.textContent = `${st.maskBit}:${st.enabled ? '1' : '0'}`;
      mask.title = `PSW mask bit ${st.maskBit} (${st.enabled ? 'enabled' : 'masked off'}) — click to flip`;
      mask.addEventListener('click', (e) => {
        e.stopPropagation();
        this._emit('interrupt-mask-toggle', { maskBit: st.maskBit });
      });
    }
    row.appendChild(mask);

    // An all-zero new PSW is an unarmed vector: taking this interrupt would
    // send the NIA to 0.  Say so here rather than after the fact.
    const psa = this._cell('psa',
      `\u2192${this._hex(st.new, 4)}`,
      st.hasHandler
        ? `old PSW at 0x${this._hex(st.old, 4)}, new PSW at 0x${this._hex(st.new, 4)}`
        : `no handler: the new PSW at 0x${this._hex(st.new, 4)} is all zeros, so a swap sends NIA to 0`);
    if (!st.hasHandler) psa.classList.add('novector');
    row.appendChild(psa);

    const acts = document.createElement('span');
    acts.className = 'acts';
    acts.appendChild(this._button('raise', `set ${st.key} pending`,
      () => this._emit('interrupt-raise', { key: st.key })));
    if (st.pending) {
      acts.appendChild(this._button('clear', `clear the ${st.key} pending latch`,
        () => this._emit('interrupt-clear', { key: st.key })));
    }
    row.appendChild(acts);
    return row;
  }

  // Log
  //
  private _logRow(e: any): HTMLElement {
    const row = document.createElement('div');
    row.className = 'row log';
    row.appendChild(this._cell('lseq', `${e.seq}`));
    row.appendChild(this._cell('ltime', `${(e.timeNs / 1e6).toFixed(3)}ms`,
      'simulated CPU time at acceptance'));
    row.appendChild(this._cell('lkey', e.key, e.label));
    row.appendChild(this._cell('lnia',
      `${this._hex(e.fromNIA, 5)}→${this._hex(e.toNIA, 5)}`,
      `interrupted at 0x${this._hex(e.fromNIA, 5)}, resumed at 0x${this._hex(e.toNIA, 5)}`));
    if (e.code != null) {
      // Name the code as well as showing it: 0004 (fixed point overflow)
      // and 0007 (store protect violation) are one glance apart.
      const label = this.cpu.intCodeLabel?.(e.key, e.code);
      row.appendChild(this._cell('lcode', `code ${this._hex(e.code, 4)}`, label ?? undefined));
      if (label) row.appendChild(this._cell('lcodename', label));
    }
    return row;
  }

  private _header(text: string, ...controls: HTMLElement[]): HTMLElement {
    const h = document.createElement('div');
    h.className = 'hdr';
    h.appendChild(this._cell('htext', text));
    for (const c of controls) h.appendChild(c);
    return h;
  }

  // The dock creates a pane, wires it and calls refresh() before Lit has
  // rendered, so that first refresh finds no shadow DOM and does nothing.
  // Draw once the template exists -- otherwise a pane added to a running
  // layout stays blank until the next display update.
  firstUpdated(): void {
    this.refresh();
  }

  refresh(): void {
    const container = this.shadowRoot?.getElementById('content');
    if (!container) return;
    if (!this.cpu?.intStatus) { container.innerHTML = ''; return; }

    // Keep the focused input alive across the refreshes a run triggers,
    // or a value can't be typed while the machine is executing.
    const active = this.shadowRoot?.activeElement as HTMLElement | null;
    if (active && active.tagName === 'INPUT') return;

    container.innerHTML = '';

    container.appendChild(this._header('INTERVAL TIMERS',
      this._button('system reset', 'POO 2.5.3.2 system reset: clear pending interrupts, timers to all ones, PSW from PSA 0014',
        () => this._emit('system-reset'))));
    container.appendChild(this._timerRow(1));
    container.appendChild(this._timerRow(2));

    // The two places a run can stop for an interrupt, armed where the
    // interrupt list they act on is: `hold` in front of the PSW swap,
    // `break` at the handler's first instruction.
    container.appendChild(this._header('INTERRUPTS',
      this._check('hold', !!this.harness?.holdInterrupt,
        'stop just before the PSW swap, with the interrupted program still in the'
        + ' registers and the NIA — step or run then performs the swap',
        (v) => this._emit('hold-interrupt-changed', { value: v })),
      this._check('break', !!this.harness?.breakOnInterrupt,
        'stop the run at the first instruction of any interrupt handler',
        (v) => this._emit('break-on-interrupt-changed', { value: v }))));

    for (const st of this.cpu.intStatus()) container.appendChild(this._intRow(st));

    // External 0 is five sources on one level, and only interrupt register
    // A says which -- a read the handler's own PCI would consume.
    const grp1 = this.iop?.group1Sources?.() ?? [];
    if (grp1.length > 0) {
      const row = document.createElement('div');
      row.className = 'row grp1';
      row.appendChild(this._cell('gkey', 'REG A', 'IOP interrupt register A, the External 0 sources'));
      row.appendChild(this._cell('gsrc', grp1.join(', ')));
      container.appendChild(row);
    }

    // What is being held, if anything: the swap has not happened, so the
    // NIA on display is still the interrupted program's.
    const held = this.cpu.heldInterrupt?.();
    if (held) {
      const row = document.createElement('div');
      row.className = 'row heldnote';
      row.appendChild(this._cell('hkey', `HELD ${held.key}`, held.label));
      row.appendChild(this._cell('hnia',
        `at ${this._hex(held.fromNIA, 5)} → ${this._hex(held.toNIA, 5)} on swap`,
        'the PSW swap has not happened yet: step or run to take it'));
      container.appendChild(row);
    }

    const log = this.cpu.intLog ?? [];
    const toggle = this._button(this._showLog ? 'hide' : 'show', 'show or hide the log',
      () => { this._showLog = !this._showLog; this.refresh(); });
    const clear = this._button('clear', 'empty the interrupt log',
      () => this._emit('interrupt-log-clear'));
    container.appendChild(this._header(`ACCEPTED (${this.cpu.intCount ?? 0})`, toggle, clear));
    if (this._showLog) {
      if (log.length === 0) {
        container.appendChild(this._cell('empty', '(none)'));
      } else {
        // Most recent first: that is the one being asked about.
        for (let i = log.length - 1; i >= 0; i--) container.appendChild(this._logRow(log[i]));
      }
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

    .brk { display: inline-flex; align-items: center; gap: 2px; color: #888; }
    .brk input { margin: 0; }

    button {
      padding: 0 4px;
      background-color: #333;
      color: #ccc;
      border: 1px solid #555;
      font-family: inherit;
      font-size: 10px;
      cursor: pointer;
    }
    button:hover { background-color: #444; }

    .row {
      display: flex;
      align-items: center;
      gap: 4px;
      line-height: 15px;
      padding: 0 2px;
      white-space: nowrap;
    }
    .row:hover { background-color: #1a1a1a; }
    .row.pending { background-color: #201010; }
    .row.blocked { background-color: #201800; }
    .row.held    { background-color: #06202c; }

    .row.grp1 { color: #999; }
    .gkey { color: #7af; flex: 0 0 44px; }
    .gsrc { overflow: hidden; text-overflow: ellipsis; }

    .row.heldnote { color: #6cf; }
    .hkey { flex: 0 0 auto; }
    .hnia { color: #9cc; }

    .tname { color: #7af; flex: 0 0 58px; }
    .tvalue {
      background: #000;
      color: #ccc;
      border: 1px solid #444;
      font-family: inherit;
      font-size: 11px;
      width: 72px;
      padding: 0 2px;
    }
    .tvalue:focus { outline: none; border-color: #7af; }
    .tdue { color: #8c8; flex: 1; text-align: right; }

    .lamp { flex: 0 0 8px; }
    .key { color: #7af; flex: 0 0 78px; overflow: hidden; text-overflow: ellipsis; }
    .mask { flex: 0 0 32px; cursor: pointer; }
    .mask.on { color: #6c6; }
    .mask.off { color: #a66; }
    .mask.nomask { color: #555; cursor: default; }
    .psa { color: #888; flex: 0 0 42px; }
    .psa.novector { color: #a66; text-decoration: underline dotted; }
    .acts { display: flex; gap: 3px; margin-left: auto; flex: 0 0 auto; }

    .row.log { color: #999; }
    .lseq { color: #555; flex: 0 0 30px; text-align: right; }
    .ltime { color: #8c8; flex: 0 0 74px; text-align: right; }
    .lkey { color: #7af; flex: 0 0 84px; }
    .lnia { color: #ccc; }
    .lcode { color: #888; }
    .lcodename { color: #a86; overflow: hidden; text-overflow: ellipsis; }

    .empty { color: #555; padding: 0 4px; }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-interrupts': GpcInterrupts;
  }
}
